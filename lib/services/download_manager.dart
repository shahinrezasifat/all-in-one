import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_task.dart';
import '../models/extract_result.dart';
import '../models/movie_model.dart';
import '../models/movie_source_language.dart';
import 'download_size_probe.dart';
import 'extractor_service.dart';
import 'gallery_media_service.dart';
import 'image_cache_service.dart';
import 'inner_tube_service.dart';
import 'media_mux_service.dart';
import 'settings_service.dart';
import 'provider_engine/provider_engine_service.dart';
import 'provider_engine/provider_models.dart';
import 'virtual_folder_service.dart';

import 'package:ytdlp_flutter/ytdlp_flutter.dart';

import 'yt_dlp_service.dart';

class DownloadManager extends ChangeNotifier {
  static final DownloadManager instance = DownloadManager._();

  /// Completes once the download directory and persisted task list are loaded.
  /// Every task mutation awaits it so a slow first read cannot wipe a task the
  /// user just started.
  late final Future<void> _ready = _initStorage();
  DownloadManager._();

  Future<void> get ready => _ready;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36';

  final List<DownloadTask> _tasks = [];
  String _downloadDirectory = '';

  // Track active HTTP clients for immediate abort on pause or cancel
  final Map<String, List<http.Client>> _activeClients = {};
  final Map<String, Future<void>> _runningDownloads = {};
  static const _background = MethodChannel('snaptube_pure/background');
  Future<void> _foregroundUpdate = Future.value();

  Future<void> _setDownloadForeground(bool enabled) {
    if (kIsWeb || !Platform.isAndroid) return Future.value();
    return _foregroundUpdate = _foregroundUpdate.then((_) async {
      try {
        await _background.invokeMethod<void>('downloads', enabled);
      } on Exception catch (error) {
        debugPrint('Could not update the download foreground service: $error');
      }
    });
  }

  /// How many times the engine reconnects before giving up. Mobile networks
  /// drop sockets all the time — a single hiccup must never be shown to the
  /// user as a permanent "network connection error".
  static const int maxDownloadAttempts = 6;

  /// A connection that delivers less than this inside a full minute is a
  /// throttled or expired stream, not a usable download.
  static const int _minBytesPerMinute = 64 * 1024;

  /// No data at all for this long means the socket is dead and must be
  /// replaced instead of hanging the task forever.
  static const Duration _chunkIdleTimeout = Duration(seconds: 40);

  /// How long the engine waits for a server to answer before reconnecting.
  static const Duration _responseTimeout = Duration(seconds: 20);

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  List<DownloadTask> get activeTasks => _tasks
      .where(
        (t) =>
            t.status != DownloadStatus.completed &&
            t.status != DownloadStatus.cancelled,
      )
      .toList();
  List<DownloadTask> get completedTasks =>
      _tasks.where((t) => t.status == DownloadStatus.completed).toList();
  List<DownloadTask> get videoTasks =>
      completedTasks.where((t) => t.category == 'video').toList();
  List<DownloadTask> get audioTasks =>
      completedTasks.where((t) => t.category == 'audio').toList();
  List<DownloadTask> get movieTasks =>
      completedTasks.where((t) => t.category == 'movie').toList();
  List<DownloadTask> get imageTasks =>
      completedTasks.where((t) => t.isImageTask).toList();

  /// Every completed video file belonging to the same downloaded series as
  /// [task]. Used by the cinema player to build the episode picker even for
  /// downloads made before season metadata was stored on the task.
  List<DownloadTask> downloadedSiblings(DownloadTask task) {
    final candidates = _tasks
        .where(
          (t) =>
              t.status == DownloadStatus.completed &&
              t.isVideoTask &&
              (t.savePath ?? '').isNotEmpty,
        )
        .toList();

    final seriesTitle = task.series?.title ?? '';
    if (seriesTitle.isNotEmpty) {
      final byTitle = candidates
          .where((t) => t.series?.title == seriesTitle)
          .toList();
      if (byTitle.isNotEmpty) return byTitle;
    }
    final seriesId = task.series?.id;
    if (seriesId != null && seriesId.isNotEmpty) {
      final byId = candidates.where((t) => t.series?.id == seriesId).toList();
      if (byId.isNotEmpty) return byId;
    }
    return candidates.where((t) => t.id == task.id).toList();
  }

  /// Groups all completed tasks into a clean Website -> Channel -> `List<DownloadTask>` hierarchy.
  Map<String, Map<String, List<DownloadTask>>> get organizedWebsiteFolders =>
      organizeWebsiteFolders(completedTasks);

  Map<String, Map<String, List<DownloadTask>>> organizeWebsiteFolders(
    Iterable<DownloadTask> tasks,
  ) {
    final map = <String, Map<String, List<DownloadTask>>>{};
    for (final task in tasks) {
      final path = task.series == null
          ? const <String>[]
          : (task.savePath ?? '').split(RegExp(r'[/\\]'));
      final website = path.length >= 3
          ? path[path.length - 3]
          : cleanWebsiteName(null, task.originalUrl);
      final channel = path.length >= 3
          ? path[path.length - 2]
          : cleanChannelName(task.author);
      map.putIfAbsent(website, () => <String, List<DownloadTask>>{});
      map[website]!.putIfAbsent(channel, () => <DownloadTask>[]);
      map[website]![channel]!.add(task);
    }
    return map;
  }

  String _defaultStoragePath() {
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      final home =
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      if (home.isNotEmpty) {
        return '$home/Downloads/SnapTube';
      }
      return '${Directory.systemTemp.path}/SnapTube';
    } else if (Platform.isAndroid) {
      return '/storage/emulated/0/Download/SnapTube';
    }
    return '${Directory.systemTemp.path}/SnapTube';
  }

  String get downloadDirectory {
    if (_downloadDirectory.isNotEmpty) {
      return _downloadDirectory;
    }
    return _defaultStoragePath();
  }

  bool get isPublicStorage =>
      Platform.isAndroid &&
      downloadDirectory.startsWith('/storage/emulated/0/Download');

  Future<void> _initStorage() async {
    _downloadDirectory = _defaultStoragePath();
    try {
      final dir = Directory(_downloadDirectory);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      Directory('$_downloadDirectory/Videos').createSync(recursive: true);
      Directory('$_downloadDirectory/Music').createSync(recursive: true);
      Directory('$_downloadDirectory/Movies').createSync(recursive: true);
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();

      String? savedPath = prefs.getString('custom_download_path');
      if (savedPath != null &&
          savedPath.isNotEmpty &&
          Directory(savedPath).existsSync()) {
        _downloadDirectory = savedPath;
      } else {
        if (Platform.isAndroid) {
          const publicPath = '/storage/emulated/0/Download/SnapTube';
          try {
            final publicDir = Directory(publicPath);
            if (!publicDir.existsSync()) {
              publicDir.createSync(recursive: true);
            }
            _downloadDirectory = publicPath;
          } catch (_) {
            final extDir =
                await getExternalStorageDirectory() ??
                await getApplicationDocumentsDirectory();
            _downloadDirectory = '${extDir.path}/SnapTube';
          }
        }
      }
      try {
        final dir = Directory(_downloadDirectory);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        Directory('$_downloadDirectory/Videos').createSync(recursive: true);
        Directory('$_downloadDirectory/Music').createSync(recursive: true);
        Directory('$_downloadDirectory/Movies').createSync(recursive: true);
      } catch (e) {
        debugPrint('Error creating download directories: $e');
      }

      // Load saved tasks
      final tasksJson = prefs.getString('saved_download_tasks');
      if (tasksJson != null) {
        final List<dynamic> list = json.decode(tasksJson);
        _tasks.clear();
        for (final item in list) {
          final task = DownloadTask.fromJson(item);
          if (task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued) {
            task.status = DownloadStatus.paused;
          }
          _tasks.add(task);
        }
      }
    } catch (e) {
      debugPrint('Error init storage: $e');
    }
    notifyListeners();
  }

  Future<void> _persistTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _tasks.map((t) => t.toJson()).toList();
      await prefs.setString('saved_download_tasks', json.encode(list));
    } catch (_) {}
  }

  /// Rewrites persisted task paths after the download root changes, so a
  /// storage migration never leaves completed downloads pointing at the old
  /// folder. Exposed as a tear-off for [StorageService.migrateLegacyFolder].
  Future<void> Function(String oldRoot, String newRoot) get relocateTasks =>
      (oldRoot, newRoot) async {
        for (final task in _tasks) {
          final path = task.savePath;
          if (path != null && path.startsWith(oldRoot)) {
            task.savePath = newRoot + path.substring(oldRoot.length);
          }
        }
        await _persistTasks();
        notifyListeners();
      };

  Future<void> setDownloadDirectory(String path) async {
    await ready;
    _downloadDirectory = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_download_path', path);
    notifyListeners();
  }

  Future<bool> upgradeToPublicStorage() async {
    if (!Platform.isAndroid) return false;
    try {
      const publicPath = '/storage/emulated/0/Download/SnapTube';
      final dir = Directory(publicPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      Directory('$publicPath/Videos').createSync(recursive: true);
      Directory('$publicPath/Music').createSync(recursive: true);
      Directory('$publicPath/Movies').createSync(recursive: true);

      _downloadDirectory = publicPath;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('custom_download_path', publicPath);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Could not upgrade to public storage: $e');
      return false;
    }
  }

  /// Resolves the clean, user-friendly website name (e.g. YouTube, Pornhub, Facebook, etc.)
  static String cleanWebsiteName(String? platform, String? url) {
    if (platform != null &&
        platform.isNotEmpty &&
        platform != 'Web Video' &&
        platform != 'Unknown') {
      return _sanitizeFolderName(platform);
    }
    if (url != null && url.isNotEmpty) {
      try {
        final uri = Uri.parse(url);
        final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
        if (host.contains('youtube') || host.contains('youtu.be'))
          return 'YouTube';
        if (host.contains('tiktok')) return 'TikTok';
        if (host.contains('facebook') || host.contains('fb.watch'))
          return 'Facebook';
        if (host.contains('instagram')) return 'Instagram';
        if (host.contains('soundcloud')) return 'SoundCloud';
        if (host.contains('pornhub')) return 'Pornhub';
        if (host.contains('xvideos')) return 'XVideos';
        if (host.contains('xnxx')) return 'XNXX';
        if (host.contains('vimeo')) return 'Vimeo';
        if (host.contains('twitter') || host.contains('x.com'))
          return 'Twitter';
        if (host.contains('reddit')) return 'Reddit';
        if (host.contains('dailymotion')) return 'Dailymotion';

        final parts = host.split('.');
        if (parts.isNotEmpty) {
          final base = parts.length >= 2 ? parts[parts.length - 2] : parts[0];
          final cleanBase = base.replaceAll(
            RegExp(r'-(cdn|video|media|static|stream)$'),
            '',
          );
          if (cleanBase.isNotEmpty) {
            return cleanBase[0].toUpperCase() + cleanBase.substring(1);
          }
        }
      } catch (_) {}
    }
    return 'Web Video';
  }

  /// Resolves the channel / author / artist name.
  /// If unknown or empty, resolves to 'Unknown' under the website folder.
  static String cleanChannelName(String? author) {
    var clean = (author ?? '').trim();
    if (clean.isEmpty ||
        clean.toLowerCase() == 'unknown' ||
        clean.toLowerCase() == 'general' ||
        clean == 'YouTube Video' ||
        clean == 'YouTube Channel' ||
        clean == 'Web Video') {
      return 'Unknown';
    }
    clean = _sanitizeFolderName(clean);
    return clean.isEmpty ? 'Unknown' : clean;
  }

  static String _sanitizeFolderName(String name) {
    final clean = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return clean.length > 50 ? clean.substring(0, 50).trim() : clean;
  }

  /// Resolves the exact destination folder: `<baseDirectory>/<Website>/<Channel>`
  /// Creates the folder on disk automatically.
  String destinationFolder({
    String? platform,
    String? url,
    String? author,
    String? customBaseDirectory,
  }) {
    final base = (customBaseDirectory != null && customBaseDirectory.isNotEmpty)
        ? customBaseDirectory
        : downloadDirectory;
    final website = cleanWebsiteName(platform, url);
    final channel = cleanChannelName(author);
    final folder = '$base/$website/$channel';
    try {
      final d = Directory(folder);
      if (!d.existsSync()) d.createSync(recursive: true);
    } catch (_) {}
    return folder;
  }

  @visibleForTesting
  void addCompletedTaskForTesting(DownloadTask task) {
    _tasks.insert(0, task);
    notifyListeners();
  }

  /// Registers an image that was already saved to disk.
  Future<DownloadTask> addCompletedImageTask({
    required String title,
    required String author,
    required String platform,
    required String originalUrl,
    required String filePath,
    required String thumbnailUrl,
  }) async {
    await ready;
    final file = File(filePath);
    final size = file.existsSync() ? file.lengthSync() : 0;
    final ext = filePath.split('.').last;
    final task = DownloadTask(
      id: 'img_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      author: cleanChannelName(author),
      thumbnailUrl: thumbnailUrl.isNotEmpty ? thumbnailUrl : filePath,
      formatLabel: 'Cover Thumbnail (${ext.toUpperCase()})',
      ext: ext,
      isAudio: false,
      category: 'image',
      originalUrl: originalUrl,
      streamUrl: originalUrl,
      savePath: filePath,
      totalBytes: size,
      downloadedBytes: size,
      status: DownloadStatus.completed,
      completedAt: DateTime.now(),
      threadsCount: 1,
    );
    _tasks.insert(0, task);
    _persistTasks();
    notifyListeners();
    return task;
  }

  Future<DownloadTask> startThumbnailDownload({
    required String title,
    required String author,
    required String platform,
    required String originalUrl,
    required String thumbnailUrl,
  }) async {
    await ready;
    final folder = destinationFolder(
      platform: platform,
      url: originalUrl,
      author: author,
    );
    final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final fileTitle = cleaned.isEmpty ? 'cover' : cleaned;
    final stem = '$folder/${fileTitle}_thumb';
    final urlPath = Uri.tryParse(thumbnailUrl)?.path.toLowerCase() ?? '';
    final ext =
        RegExp(r'\.(jpe?g|png|webp|avif|gif)$').firstMatch(urlPath)?.group(1) ??
        'jpg';
    var target = '$stem.$ext';
    for (
      var copy = 2;
      File(target).existsSync() ||
          _tasks.any((task) => task.savePath == target);
      copy++
    ) {
      target = '$stem ($copy).$ext';
    }
    final task = DownloadTask(
      id: 'img_${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      author: cleanChannelName(author),
      thumbnailUrl: thumbnailUrl,
      formatLabel: 'Cover Thumbnail',
      ext: ext,
      isAudio: false,
      category: 'image',
      originalUrl: thumbnailUrl,
      streamUrl: thumbnailUrl,
      savePath: target,
      status: DownloadStatus.downloading,
      threadsCount: 1,
    );
    _tasks.insert(0, task);
    _persistTasks();
    notifyListeners();
    _downloadRealMedia(task);
    return task;
  }

  Future<DownloadTask> startDownload({
    required ExtractResult video,
    required MediaFormat format,
    String? audioTrackId,
    String? audioTrackName,
  }) async {
    await ready;
    final isAudio = format.type == MediaType.audio;
    final folder = destinationFolder(
      platform: video.platform,
      url: video.originalUrl,
      author: video.author,
    );
    final sanitizedTitle = video.title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final filename = '${sanitizedTitle}_${format.id}.${format.ext}';
    final targetPath = '$folder/$filename';

    final task = DownloadTask(
      id: '${video.id}_${DateTime.now().millisecondsSinceEpoch}',
      title: video.title,
      author: video.author,
      thumbnailUrl: video.thumbnailUrl,
      formatLabel: format.label,
      ext: format.ext,
      isAudio: isAudio,
      category: isAudio ? 'audio' : 'video',
      originalUrl: video.originalUrl,
      channelUrl: video.channelUrl,
      streamUrl: format.url,
      preferredFormatId: format.id,
      needsAudioMerge: format.needsAudioMerge,
      audioStreamUrl: format.companionAudioUrl,
      audioExt: format.companionAudioExt,
      audioTrackId: audioTrackId,
      audioTrackName: audioTrackName,
      savePath: targetPath,
      totalBytes: format.fileSize ?? 0,
      totalBytesIsEstimate: (format.fileSize ?? 0) > 0,
      status: DownloadStatus.downloading,
      threadsCount: 1,
    );

    _tasks.insert(0, task);
    _persistTasks();
    notifyListeners();

    _downloadRealMedia(task, preferredFormatId: format.id);
    return task;
  }

  Future<DownloadTask> startDirectDownload({
    required String url,
    required String title,
    required String author,
    required String thumbnailUrl,
    required bool isAudio,
    String? quality,
  }) async {
    await ready;
    final folder = destinationFolder(url: url, author: author);
    final sanitizedTitle = title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final ext = isAudio ? 'mp3' : 'mp4';
    final qLabel = quality ?? (isAudio ? '320 kbps MP3' : '1080p HD MP4');
    final filename = '${sanitizedTitle}_${isAudio ? "audio" : "video"}.$ext';
    final targetPath = '$folder/$filename';

    final task = DownloadTask(
      id: 'direct_${DateTime.now().millisecondsSinceEpoch}_${title.hashCode.abs()}',
      title: title,
      author: author,
      thumbnailUrl: thumbnailUrl,
      formatLabel: qLabel,
      ext: ext,
      isAudio: isAudio,
      category: isAudio ? 'audio' : 'video',
      originalUrl: url,
      streamUrl: url,
      savePath: targetPath,
      totalBytes: 0,
      status: DownloadStatus.downloading,
      threadsCount: 1,
    );

    _tasks.insert(0, task);
    _persistTasks();
    notifyListeners();

    _downloadRealMedia(task);
    return task;
  }

  Future<DownloadTask> startMovieDownload({
    required MovieItem movie,
    required MovieSource source,
    String? customTitle,
    int? seasonNumber,
  }) async {
    await ready;
    ImageCacheService.instance.prefetch([movie.posterUrl]);
    final folder = '$downloadDirectory/Movies';
    final task = _makeMovieTask(
      movie,
      source,
      customTitle ?? movie.title,
      folder,
      series: movie.isSeries ? movie.copyWith(sources: const []) : null,
      seasonName: seasonNumber == null ? null : 'Season $seasonNumber',
    );
    _tasks.insert(0, task);
    _persistTasks();
    notifyListeners();
    unawaited(_downloadRealMedia(task));
    return task;
  }

  Future<void> startSeasonDownload({
    required MovieItem series,
    required String seasonName,
    required String language,
    required String resolution,
    required List<({ProviderEpisode episode, MovieSource source})> episodes,
  }) async {
    await ready;
    await SettingsService.instance.ready;
    if (episodes.isEmpty) return;
    ImageCacheService.instance.prefetch([series.posterUrl]);
    final seriesName = _safeDownloadName(series.title, fallback: 'Series');
    final season = _safeDownloadName(seasonName, fallback: 'Season 1');
    final folder = '$downloadDirectory/$seriesName/$season';
    await Directory(folder).create(recursive: true);
    // Keep the season/episode catalogue on the stored task so the player's
    // episode picker works without having to re-query the provider.
    final details = series.copyWith(sources: const []);
    for (final entry in episodes) {
      final episode = entry.episode;
      final number = episode.number.toString().padLeft(2, '0');
      final name = episode.title.trim();
      final group = episode.group?.trim() ?? '';
      final title = [
        'Episode $number',
        if (name.isNotEmpty &&
            name != 'Episode' &&
            name != 'Episode ${episode.number}')
          name,
        if (group.isNotEmpty) group,
      ].join(' - ');
      final task = _makeMovieTask(
        series,
        entry.source,
        title,
        folder,
        status: DownloadStatus.queued,
        series: details,
        seasonName: episode.season == null
            ? seasonName
            : 'Season ${episode.season}',
        episodeUrl: episode.url,
        language: language,
        resolution: resolution,
      );
      _tasks.insert(0, task);
    }
    await _persistTasks();
    _startQueuedDownloads();
  }

  String _safeDownloadName(String value, {required String fallback}) {
    final clean = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim()
        .replaceFirst(RegExp(r'\.+$'), '');
    return clean.isEmpty ? fallback : clean;
  }

  DownloadTask _makeMovieTask(
    MovieItem movie,
    MovieSource source,
    String title,
    String folder, {
    DownloadStatus status = DownloadStatus.downloading,
    MovieItem? series,
    String? seasonName,
    String? episodeUrl,
    String? language,
    String? resolution,
  }) {
    final sanitizedTitle = _safeDownloadName(title, fallback: 'Video');
    final formatToUse = source.format.isNotEmpty ? source.format : 'mp4';
    final quality = source.resolution.replaceAll(
      RegExp(r'[\s\\/:*?"<>|]'),
      '_',
    );
    final stem = '$folder/${sanitizedTitle}_$quality';
    var targetPath = '$stem.$formatToUse';
    for (
      var copy = 2;
      File(targetPath).existsSync() ||
          _tasks.any((task) => task.savePath == targetPath);
      copy++
    ) {
      targetPath = '$stem ($copy).$formatToUse';
    }

    int bytes = 0;
    final sizeStr = source.fileSize.toUpperCase();
    if (sizeStr.contains('GB')) {
      final val = double.tryParse(sizeStr.replaceAll(RegExp(r'[^0-9.]'), ''));
      if (val != null) bytes = (val * 1024 * 1024 * 1024).toInt();
    } else if (sizeStr.contains('MB')) {
      final val = double.tryParse(sizeStr.replaceAll(RegExp(r'[^0-9.]'), ''));
      if (val != null) bytes = (val * 1024 * 1024).toInt();
    }

    final task = DownloadTask(
      id: 'movie_${movie.id}_${DateTime.now().microsecondsSinceEpoch}_${targetPath.hashCode}',
      title: '$title (${source.resolution})',
      author: '${movie.repoName} • ${source.serverName}',
      thumbnailUrl: movie.posterUrl,
      formatLabel: '${source.resolution} • ${source.fileSize}',
      ext: formatToUse,
      isAudio: false,
      category: 'movie',
      originalUrl: source.downloadUrl.isNotEmpty
          ? source.downloadUrl
          : source.streamUrl,
      streamUrl: _isUnusableUrl(source.downloadUrl)
          ? source.streamUrl
          : source.downloadUrl,
      headers: source.headers,
      isHls: source.format.toLowerCase() == 'm3u8',
      hlsVariantResolution: source.hlsVariantResolution,
      savePath: targetPath,
      totalBytes: bytes,
      totalBytesIsEstimate: bytes > 0,
      status: status,
      series: series,
      seriesSeason: seasonName,
      seriesEpisodeUrl: episodeUrl,
      seriesLanguage: language,
      seriesResolution: resolution,
      threadsCount: 1,
    );

    return task;
  }

  // The request identity for a googlevideo URL is derived from the URL itself
  // (its `c=` parameter names the minting client) so rotation stays
  // consistent — see InnerTubeService.userAgentForUrl.

  static bool isGoogleVideoUrl(String url) =>
      url.contains('googlevideo.com') || url.contains('youtube.com');

  /// True when a signed googlevideo link is expired — or so close to expiry
  /// that it may die mid-transfer. URLs carry the moment they stop working in
  /// their `expire=` query parameter (Unix seconds). A task restored from disk
  /// (or a picker entry left open for hours) holds a spent signature, and
  /// requesting it answers HTTP 403 no matter which client minted it — so a
  /// fresh link must be minted BEFORE the first byte is asked for.
  static bool _googleLinkExpiring(
    String? url, {
    Duration margin = const Duration(minutes: 10),
  }) {
    if (url == null || !isGoogleVideoUrl(url)) return false;
    try {
      final expire = int.tryParse(
        Uri.parse(url).queryParameters['expire'] ?? '',
      );
      if (expire == null || expire <= 0) return false;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(expire * 1000);
      return DateTime.now().add(margin).isAfter(expiresAt);
    } catch (_) {
      return false;
    }
  }

  /// Short, log-friendly description of WHICH identity signed a googlevideo
  /// URL (client, bound IP, expiry). 403 investigations used to be blind
  /// because the log never showed what the CDN had rejected.
  static String _googlevideoIdentity(String url) {
    try {
      final q = Uri.parse(url).queryParameters;
      final parts = <String>[
        if ((q['c'] ?? '').isNotEmpty) 'c=${q['c']}',
        if ((q['ip'] ?? '').isNotEmpty) 'ip=${q['ip']}',
        if ((q['expire'] ?? '').isNotEmpty) 'expire=${q['expire']}',
      ];
      return parts.isEmpty ? 'no identity params' : parts.join(', ');
    } catch (_) {
      return 'unparseable url';
    }
  }

  static Map<String, String> downloadHeadersFor(String url, {String? range}) {
    final isGoogleVideo = isGoogleVideoUrl(url);
    final headers = <String, String>{};
    if (isGoogleVideo) {
      // The URL was minted by one specific InnerTube client, and googlevideo
      // binds the signed URL to that client's identity — any other UA (or a
      // web Referer/Origin) gets rejected with HTTP 403. Read the identity
      // off the URL so it always matches, even after client rotation.
      headers['User-Agent'] = InnerTubeService.userAgentForUrl(url);
    } else {
      headers['User-Agent'] = defaultUserAgent;
      try {
        final uri = Uri.parse(url);
        if (uri.host.isNotEmpty) {
          headers['Referer'] = '${uri.scheme}://${uri.host}/';
        }
      } catch (_) {}
    }
    if (range != null && range.isNotEmpty) {
      headers['Range'] = range;
    }
    return headers;
  }

  /// Headers for a media request. For ordinary websites the media is often
  /// hotlink-protected and only served to a request that carries the page URL
  /// as its Referer, so prefer the original page over the bare origin.
  Map<String, String> _mediaHeadersFor(
    DownloadTask task,
    String url, {
    String? range,
  }) {
    final headers = downloadHeadersFor(url, range: range);
    final original = task.originalUrl;
    // Only use the original URL as Referer when it is actually a different
    // document (the page that embedded the media). For direct downloads the
    // original URL *is* the media URL, where the bare origin is correct.
    if (!isGoogleVideoUrl(url) &&
        original != url &&
        (original.startsWith('http://') || original.startsWith('https://'))) {
      headers['Referer'] = original;
    }
    // Provider-supplied headers (Cookie / token / custom UA from the movie
    // extension) WIN over the generic identity — movie servers reject range
    // requests without them. Never applied to googlevideo URLs, where the
    // minting-client identity must stay exact.
    if (task.headers.isNotEmpty && !isGoogleVideoUrl(url)) {
      headers.addAll(task.headers);
      if (range != null && range.isNotEmpty) headers['Range'] = range;
    }
    return headers;
  }

  /// Mints brand-new, freshly signed stream URLs for the task.
  ///
  /// googlevideo signs URLs with a very short life (and the android client
  /// forbids re-fetching a spent stream), so every reconnect must ask the
  /// extractor for a new pair of links — this is what turns a bogus "network
  /// connection error" into a download that simply continues.
  ///
  /// The resolution the user picked ([DownloadTask.preferredFormatId] /
  /// [DownloadTask.formatLabel]) is always honoured, so a retry can never
  /// silently downgrade 4K/2K/1080p to a smaller stream.
  Future<LiveStreamSource?> _resolveSource(
    DownloadTask task,
    String? preferredFormatId,
  ) async {
    if (task.series != null) {
      return await _refreshSeriesEpisode(task)
          ? LiveStreamSource(videoUrl: task.streamUrl!, videoExt: task.ext)
          : null;
    }
    try {
      if (task.originalUrl.isNotEmpty) {
        if (task.needsAudioMerge) {
          final pair = await ExtractorService.instance
              .resolveLiveVideoWithAudio(
                task.originalUrl,
                preferredFormatId: preferredFormatId,
                preferredLabel: task.formatLabel,
                audioTrackId: task.audioTrackId,
              );
          if (pair != null && pair.videoUrl.isNotEmpty) return pair;
        }
        final url = await ExtractorService.instance.resolveLiveStreamUrl(
          task.originalUrl,
          isAudio: task.isAudio,
          preferredFormatId: preferredFormatId,
          preferredLabel: task.formatLabel,
          audioTrackId: task.audioTrackId,
        );
        if (url != null && url.isNotEmpty) {
          return LiveStreamSource(videoUrl: url, videoExt: task.ext);
        }
      }

      if (task.category == 'audio') {
        final url = await ExtractorService.instance
            .resolveLiveAudioStreamForTrack(task.title, task.author);
        if (url == null || url.isEmpty) return null;
        return LiveStreamSource(videoUrl: url, videoExt: task.ext);
      }
      if (task.category == 'movie') {
        final cleanTitle = task.title
            .replaceAll(RegExp(r'\([^)]*\)'), '')
            .trim();
        final url = await ExtractorService.instance.resolveLiveMovieStream(
          cleanTitle.isNotEmpty ? cleanTitle : task.title,
          resolution: task.formatLabel,
          preferMuxedForPlayback: true,
        );
        if (url == null || url.isEmpty) return null;
        return LiveStreamSource(videoUrl: url, videoExt: task.ext);
      }
    } catch (e) {
      debugPrint('Fresh stream re-resolve failed for ${task.title}: $e');
    }
    return null;
  }

  Future<bool> _refreshSeriesEpisode(DownloadTask task) async {
    final series = task.series;
    final episodeUrl = task.seriesEpisodeUrl;
    if (series == null || episodeUrl == null) return false;
    try {
      final sources = await ProviderEngineService.instance
          .episodeDownloadFormats(
            series,
            ProviderEpisode(
              id: episodeUrl,
              number: 0,
              url: episodeUrl,
              title: '',
            ),
          );
      if (task.status != DownloadStatus.downloading) return false;
      final matches = sources.where(
        (source) =>
            movieSourceLanguageKeys(source).contains(task.seriesLanguage) &&
            (task.seriesResolution == 'Auto' ||
                episodeDownloadResolution(source) == task.seriesResolution) &&
            (source.format.toLowerCase() == 'm3u8') == task.isHls &&
            source.hlsVariantResolution == task.hlsVariantResolution,
      );
      final source =
          matches
              .where((source) => task.author.endsWith(source.serverName))
              .firstOrNull ??
          (task.downloadedBytes == 0 ? matches.firstOrNull : null);
      if (source == null) return false;
      task.streamUrl = source.downloadUrl;
      task.headers = source.headers;
      return true;
    } on Exception {
      return false;
    }
  }

  /// A stored stream URL that is empty or a demo/preview clip must be replaced
  /// by a real, full-length source before any bytes are requested.
  static bool _isUnusableUrl(String? url) =>
      url == null ||
      url.trim().isEmpty ||
      url.contains('commondatastorage.googleapis.com') ||
      url.contains('itunes.apple.com') ||
      url.contains('/preview/');

  /// True when the file on disk already holds every byte of the video/audio
  /// payload, so a retry only has to redo the merge step.
  bool _savedFileIsComplete(DownloadTask task) {
    final path = task.savePath;
    if (path == null || path.isEmpty) return false;
    if (!task.payloadVerified ||
        task.totalBytes <= 0 ||
        task.downloadedBytes != task.totalBytes) {
      return false;
    }
    try {
      final file = File(path);
      return file.existsSync() && file.lengthSync() == task.downloadedBytes;
    } catch (_) {
      return false;
    }
  }

  static String _shortError(String message) {
    final clean = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= 80) return clean;
    return '${clean.substring(0, 77)}…';
  }

  // ---------------------------------------------------------------------------
  // Resilient download engine
  // ---------------------------------------------------------------------------

  void _startQueuedDownloads() {
    final available =
        SettingsService.instance.maxConcurrent.clamp(1, 5) -
        _runningDownloads.length;
    if (available > 0) {
      final next = _tasks.reversed
          .where((task) => task.status == DownloadStatus.queued)
          .take(available)
          .toList();
      for (final task in next) {
        task.status = DownloadStatus.downloading;
        unawaited(_downloadRealMedia(task));
      }
      if (next.isNotEmpty) unawaited(_persistTasks());
    }
    notifyListeners();
  }

  Future<void> _downloadRealMedia(
    DownloadTask task, {
    String? preferredFormatId,
  }) async {
    if (_runningDownloads.containsKey(task.id)) return;
    if (_runningDownloads.isEmpty) _setDownloadForeground(true);
    final run = _foregroundUpdate.then(
      (_) => _performDownload(task, preferredFormatId: preferredFormatId),
    );
    _runningDownloads[task.id] = run;
    try {
      await run;
    } finally {
      _runningDownloads.remove(task.id);
      _startQueuedDownloads();
      if (_runningDownloads.isEmpty) unawaited(_setDownloadForeground(false));
    }
  }

  Future<void> _performDownload(
    DownloadTask task, {
    String? preferredFormatId,
  }) async {
    await ready;
    if (task.status != DownloadStatus.downloading) return;

    // A retry started from the downloads screen must keep the resolution the
    // user originally picked — this used to be dropped, which silently
    // downgraded 4K/2K/1080p downloads to a low-quality stream.
    final formatId = preferredFormatId ?? task.preferredFormatId;
    if (formatId != null) task.preferredFormatId = formatId;

    final nativeFormat = formatId?.startsWith('ytdlp_') ?? false;
    final isYouTube = YtDlpService.isYouTubeUrl(task.originalUrl);
    final usePage =
        YtDlpService.instance.supported &&
        (nativeFormat || (isYouTube && (task.audioTrackId ?? '').isEmpty));
    var nativeOnly = usePage && (nativeFormat || Platform.isAndroid);
    Object? lastError;
    for (var attempt = 1; usePage && attempt <= 3; attempt++) {
      if (task.status != DownloadStatus.downloading) return;
      try {
        await _downloadWithYtDlp(task);
        return;
      } catch (error) {
        if (task.status != DownloadStatus.downloading) return;
        lastError = error;
        debugPrint('Native download failed: $error');
        if (!_isRetryable(error) || attempt == 3) break;
        task.statusNote = 'Reconnecting to continue the download…';
        notifyListeners();
        await Future.delayed(Duration(seconds: attempt));
      }
    }

    if (isYouTube && nativeOnly && task.status == DownloadStatus.downloading) {
      task.statusNote =
          'Trying another source for the selected YouTube format…';
      notifyListeners();
      ExtractResult? alternatives;
      try {
        alternatives = await ExtractorService.instance
            .extract(task.originalUrl)
            .timeout(const Duration(seconds: 35));
      } on Exception catch (error) {
        debugPrint('YouTube fallback could not resolve a source: $error');
      }
      if (task.status != DownloadStatus.downloading) return;
      final height = ExtractorService.heightHint(formatId, task.formatLabel);
      final pool = task.isAudio
          ? alternatives?.audioFormats
          : alternatives?.videoFormats;
      final alternative = pool
          ?.where(
            (format) =>
                !_isUnusableUrl(format.url) &&
                (task.isAudio ||
                    height == null ||
                    ExtractorService.heightHint(format.id, format.label) ==
                        height) &&
                (!format.needsAudioMerge ||
                    !_isUnusableUrl(format.companionAudioUrl)),
          )
          .firstOrNull;
      if (alternative != null) {
        task.streamUrl = alternative.url;
        task.needsAudioMerge = alternative.needsAudioMerge;
        task.audioStreamUrl = alternative.companionAudioUrl;
        task.audioExt = alternative.companionAudioExt;
        task.totalBytes = alternative.fileSize ?? 0;
        task.totalBytesIsEstimate = task.totalBytes > 0;
        nativeOnly = false;
      }
    }

    for (
      int attempt = 1;
      !nativeOnly && attempt <= maxDownloadAttempts;
      attempt++
    ) {
      if (task.status != DownloadStatus.downloading) return;

      if (attempt > 1) {
        // The bytes already on disk always stand — say exactly that instead
        // of flashing a scary, broken-looking "Reconnecting" to the user.
        final resumePct = task.totalBytes > 0
            ? (task.downloadedBytes * 100 / task.totalBytes)
                  .clamp(0, 100)
                  .toInt()
            : 0;
        task.statusNote = 'Getting a fresh link — continuing from $resumePct%';
        task.speedBytesPerSec = 0;
        for (final s in task.segments) {
          s.speedBytesPerSec = 0;
        }
        notifyListeners();
        await Future.delayed(Duration(seconds: (attempt - 1).clamp(1, 5)));
        if (task.status != DownloadStatus.downloading) return;
      }

      try {
        await _runDownloadPass(task, preferredFormatId: formatId);
        return; // completed, or the user paused/cancelled mid-pass
      } catch (e) {
        // Pausing or cancelling closes the live socket, which surfaces as an
        // exception — that must never be reported as a failure.
        if (task.status != DownloadStatus.downloading) return;
        lastError = e;
        debugPrint(
          'Download attempt $attempt/$maxDownloadAttempts failed for ${task.title}: $e',
        );
        // A googlevideo 403 that survives a full pass means the CDN dislikes
        // the minting client for THIS network — retrying the same client just
        // mints the same rejected identity. Rotate so the next pass signs the
        // URLs from a different InnerTube client.
        if (e.toString().contains('403') &&
            isGoogleVideoUrl(task.streamUrl ?? task.originalUrl)) {
          InnerTubeService.instance.rotateClient();
        }
        final rejectedLink = RegExp(r'\b(401|403|404|410)\b')
            .hasMatch(e.toString());
        if (task.series != null &&
            rejectedLink &&
            attempt < maxDownloadAttempts) {
          if (await _refreshSeriesEpisode(task)) continue;
        }
        if (!_isRetryable(e)) break;
      }
    }

    if (task.status != DownloadStatus.downloading) return;
    task.status = DownloadStatus.failed;
    task.errorMessage = _describeFailure(lastError);
    task.statusNote = null;
    task.speedBytesPerSec = 0;
    for (final s in task.segments) {
      s.speedBytesPerSec = 0;
    }
    _persistTasks();
    notifyListeners();
  }

  static bool _isRetryable(Object? error) {
    if (error is _DownloadException) return error.retryable;
    if (error is FileSystemException) return false; // full disk / no permission
    return true;
  }

  /// Turns a raw exception into something the user can actually act on.
  /// "Network connection failed" is only used when the network really is the
  /// problem — and even then the engine has already tried [maxDownloadAttempts]
  /// times and resumed instead of restarting.
  static String _describeFailure(Object? error) {
    if (error == null) return 'Download failed — tap retry';

    if (error is _DownloadException) {
      return error.retryable
          ? '${error.message} (reconnected $maxDownloadAttempts times)'
          : error.message;
    }
    if (error is FileSystemException) {
      return 'Storage problem: ${error.message} — free space or change the download folder';
    }

    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('sign in') || lower.contains('login required')) {
      return 'YouTube requires sign-in for this video or network';
    }
    if (text.contains('403')) {
      return 'Source refused the download link (403) — tap retry for a fresh link';
    }
    if (text.contains('404')) {
      return 'Media no longer exists on the server (404)';
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'Connection timed out — check your network, then tap retry';
    }
    if (lower.contains('socketexception') ||
        lower.contains('connection closed') ||
        lower.contains('connection reset') ||
        lower.contains('reset by peer') ||
        lower.contains('broken pipe') ||
        lower.contains('handshake') ||
        lower.contains('network is unreachable') ||
        lower.contains('failed host lookup') ||
        lower.contains('clientexception')) {
      return 'Network kept dropping — tap retry, it resumes where it stopped';
    }

    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.isEmpty
        ? 'Download failed — tap retry'
        : 'Download failed: $clean — tap retry';
  }

  /// Native yt-dlp download pipeline on supported platforms (Android / macOS).
  /// Bypasses GoogleVideo 15MB 403 throttles and handles 4K/2K/1080p DASH muxing.
  Future<void> _downloadWithYtDlp(DownloadTask task) async {
    final saveFile = File(task.savePath!);
    saveFile.parent.createSync(recursive: true);
    final taskFolder = task.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final workDir = Directory('${saveFile.parent.path}/.yt-dlp/$taskFolder');
    await workDir.create(recursive: true);
    final outputDir = workDir.path;

    String selector;
    String? audioFormat;
    if (task.isAudio) {
      selector = 'bestaudio/best';
      if (task.ext.toLowerCase() == 'mp3') {
        audioFormat = 'mp3';
      }
    } else {
      final nativeHeight = task.preferredFormatId?.startsWith('ytdlp_') == true
          ? int.tryParse(
              RegExp(r'^(\d+)p').firstMatch(task.formatLabel)?.group(1) ?? '',
            )
          : null;
      final h =
          nativeHeight ??
          ExtractorService.heightHint(task.preferredFormatId, task.formatLabel);
      if (h != null && h > 0) {
        selector = 'bv*[height=$h]+ba/b[height=$h]';
      } else {
        selector = 'bv*+ba/best';
      }
    }

    task.speedBytesPerSec = 0;
    task.nativeProgress = null;
    await _prepareNativeSize(task, task.originalUrl, selector);
    if (task.status != DownloadStatus.downloading) return;

    final finishedPath = await YtDlpService.instance.downloadFormat(
      url: task.originalUrl,
      formatSelector: selector,
      outputDir: outputDir,
      taskId: task.id,
      audioFormat: audioFormat,
      onProgress: (YtdlpProgress p) {
        if (task.status != DownloadStatus.downloading) return;
        _updateNativeProgress(task, p);
        notifyListeners();
      },
    );

    if (task.status != DownloadStatus.downloading) return;

    if (finishedPath.isNotEmpty &&
        File(finishedPath).existsSync() &&
        File(finishedPath).lengthSync() > 0) {
      final downloadedFile = File(finishedPath);
      final finalLen = downloadedFile.lengthSync();
      task.downloadedBytes = finalLen;
      task.totalBytes = finalLen;

      _adoptNativeFile(task, downloadedFile);
      task.payloadVerified = true;

      try {
        if (workDir.listSync().isEmpty) workDir.deleteSync();
      } on FileSystemException {
        // Cleanup must not invalidate the saved download.
      }

      if (!task.isImageTask && !task.isAudio && task.category != 'movie') {
        await _ensureMp4Output(task);
        if (task.status != DownloadStatus.downloading) return;
      }
      if (task.isAudio && task.ext.toLowerCase() == 'mp3') {
        await _ensureMp3Output(task);
        if (task.status != DownloadStatus.downloading) return;
      }

      _markCompleted(task);
    } else {
      throw const _DownloadException('The download engine produced no file');
    }
  }

  void _adoptNativeFile(DownloadTask task, File downloadedFile) {
    final outputExt = downloadedFile.uri.pathSegments.last.split('.').last;
    final currentPath = task.savePath!;
    if (outputExt != task.ext && currentPath.endsWith('.${task.ext}')) {
      final stem = currentPath.substring(
        0,
        currentPath.length - task.ext.length - 1,
      );
      var target = '$stem.$outputExt';
      for (
        var copy = 2;
        File(target).existsSync() ||
            _tasks.any((item) => item.savePath == target);
        copy++
      ) {
        target = '$stem ($copy).$outputExt';
      }
      task.savePath = target;
      task.ext = outputExt;
    }
    final targetPath = task.savePath!;
    if (downloadedFile.path != targetPath) {
      try {
        final targetFile = File(targetPath);
        if (targetFile.existsSync()) targetFile.deleteSync();
        downloadedFile.renameSync(targetPath);
      } catch (_) {
        task.savePath = downloadedFile.path;
        task.ext = downloadedFile.path.split('.').last;
      }
    }
  }

  void _setMeasuredSize(
    DownloadTask task,
    DownloadSize size, {
    int offset = 0,
  }) {
    task.totalBytes = offset + size.bytes;
    task.totalBytesIsEstimate = size.estimated;
  }

  Future<void> _prepareNativeSize(
    DownloadTask task,
    String url,
    String selector, {
    int offset = 0,
    Map<String, String> headers = const {},
  }) async {
    task.statusNote = 'Checking download size…';
    notifyListeners();
    DownloadSize? size;
    if (!task.isAudio && (task.isHls || _looksLikeHls(url))) {
      size = await _probeNativeHlsSize(task, url);
    }
    if (size == null && task.status == DownloadStatus.downloading) {
      try {
        final metadata = await YtDlpService.instance
            .resolve(url, format: selector, headers: headers)
            .timeout(const Duration(seconds: 12));
        if (metadata != null)
          size = YtDlpService.selectedDownloadSize(metadata);
      } on Exception {
        // Continue if the source cannot publish a size in advance.
      }
    }
    if (task.status != DownloadStatus.downloading) return;
    if (size != null) {
      _setMeasuredSize(task, size, offset: offset);
      unawaited(_persistTasks());
    }
    task.statusNote = 'Starting download…';
    notifyListeners();
  }

  void _updateNativeProgress(
    DownloadTask task,
    YtdlpProgress progress, {
    int offset = 0,
  }) {
    final bytes = progress.downloadedBytes;
    if (bytes != null) task.downloadedBytes = offset + bytes;
    final total = progress.totalBytes;
    // A native event may only describe the first track of a multi-track transfer.
    // Keep the complete preflight total until progress reports a larger transfer.
    if (total != null && total > 0 && offset + total > task.totalBytes) {
      _setMeasuredSize(task, (
        bytes: total,
        estimated: progress.totalBytesIsEstimate || task.totalBytes > 0,
      ), offset: offset);
    }
    task.speedBytesPerSec = progress.speedBytesPerSecond ?? 0;
    task.statusNote = null;
    final fraction = progress.fraction;
    if (task.displayTotalBytes <= 0 && fraction != null) {
      task.nativeProgress = fraction.clamp(0.0, 0.99);
    }
  }

  Future<File?> _transferResolvedWithYtDlp(
    DownloadTask task,
    String url, {
    bool companion = false,
  }) async {
    final folder = task.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final track = companion ? 'audio' : 'media';
    final workDir = Directory(
      '${File(task.savePath!).parent.path}/.yt-dlp/$folder/$track',
    );
    await workDir.create(recursive: true);
    if (task.status != DownloadStatus.downloading) return null;
    final audio = companion || task.isAudio;
    final offset = companion ? task.downloadedBytes : 0;
    task.nativeProgress = null;
    final exactHls = YtDlpService.exactHlsSelector(task.hlsVariantResolution);
    if (task.hlsVariantResolution != null && exactHls == null) {
      throw const _DownloadException(
        'Invalid dimensions for the selected video resolution.',
        retryable: false,
      );
    }
    final dash =
        task.ext.toLowerCase() == 'mpd' ||
        Uri.tryParse(url)?.path.toLowerCase().endsWith('.mpd') == true;
    final dashHeight = dash
        ? int.tryParse(
            RegExp(r'^(\d{3,4})p').firstMatch(task.formatLabel)?.group(1) ?? '',
          )
        : null;
    final dashSelector = dashHeight == null
        ? 'bv*+ba/best'
        : 'bv*[height=$dashHeight]+ba/b[height=$dashHeight]';
    final selector = audio
        ? 'ba/b'
        : exactHls ?? (dash ? dashSelector : 'b/bv/ba');
    final headers = _mediaHeadersFor(task, url);
    await _prepareNativeSize(
      task,
      url,
      selector,
      offset: offset,
      headers: headers,
    );
    if (task.status != DownloadStatus.downloading) return null;
    final String outputPath;
    try {
      outputPath = await YtDlpService.instance.downloadFormat(
        url: url,
        formatSelector: selector,
        outputDir: workDir.path,
        taskId: task.id,
        audioFormat: !companion && audio && task.ext.toLowerCase() == 'mp3'
            ? 'mp3'
            : null,
        headers: headers,
        onProgress: (progress) {
          if (task.status != DownloadStatus.downloading) return;
          _updateNativeProgress(task, progress, offset: offset);
          notifyListeners();
        },
      );
    } on YtdlpException catch (error) {
      if (exactHls != null &&
          error.toString().toLowerCase().contains(
            'requested format is not available',
          )) {
        throw const _DownloadException(
          'This source no longer offers the selected video resolution.',
          retryable: false,
        );
      }
      rethrow;
    }
    if (task.status != DownloadStatus.downloading) return null;
    final file = File(outputPath);
    if (!await file.exists() || await file.length() == 0) {
      throw const _DownloadException('The download engine produced no file');
    }
    return file;
  }

  /// One download attempt: resolve the exact source, fetch every part the
  /// format needs, merge them when required and only then mark the task done.
  Future<void> _runDownloadPass(
    DownloadTask task, {
    String? preferredFormatId,
  }) async {
    task.statusNote = 'Checking download size…';
    notifyListeners();

    // ---- 1. The exact source(s) the user asked for ----------------------
    String? streamUrl = task.streamUrl;
    String? audioUrl = task.needsAudioMerge ? task.audioStreamUrl : null;

    if (task.hlsVariantResolution != null && _isUnusableUrl(streamUrl)) {
      throw const _DownloadException(
        'The link for this resolution is unavailable. Select the format again.',
        retryable: false,
      );
    }

    // A language chosen in the picker is honoured on EVERY pass: re-resolving
    // always mints fresh links for exactly that dub (the extract-time URL is
    // the original track and may already be spent).
    final wantsTrackAudio =
        task.isAudio && (task.audioTrackId ?? '').isNotEmpty;
    // Expired signatures are the single biggest source of "HTTP 403 from
    // googlevideo": the bytes request goes out with a link that YouTube
    // stopped honouring hours ago. Re-mint BEFORE the first byte instead of
    // waiting for the CDN to reject it.
    final staleGoogleLink =
        _googleLinkExpiring(streamUrl) ||
        (task.needsAudioMerge && _googleLinkExpiring(audioUrl));
    final needsInitialResolution =
        _isUnusableUrl(streamUrl) ||
        (task.needsAudioMerge && _isUnusableUrl(audioUrl)) ||
        staleGoogleLink;
    if (needsInitialResolution || wantsTrackAudio) {
      task.statusNote = task.needsAudioMerge
          ? 'Fetching the original ${task.formatLabel} stream + audio…'
          : 'Fetching the original ${task.formatLabel} stream…';
      notifyListeners();

      final source = await _resolveSource(task, preferredFormatId);
      if (source != null && source.videoUrl.isNotEmpty) {
        streamUrl = source.videoUrl;
        task.streamUrl = streamUrl;
        if (task.needsAudioMerge) {
          audioUrl = source.audioUrl;
          task.audioStreamUrl = audioUrl;
          if (source.audioExt != null) task.audioExt = source.audioExt;
        }
      }
    }

    // Direct links and ordinary websites: run a full extract and take the
    // first format that actually carries a real stream URL.
    if (_isUnusableUrl(streamUrl) && task.series == null) {
      final res = await _extractFallbackFormat(task, preferredFormatId);
      if (res != null) {
        streamUrl = res.url;
        task.streamUrl = streamUrl;
        if ((res.fileSize ?? 0) > 0) {
          task.totalBytes = res.fileSize!;
          task.totalBytesIsEstimate = true;
        }
      }
    }

    if (_isUnusableUrl(streamUrl)) {
      throw const _DownloadException('Could not resolve the media stream');
    }
    final targetUrl = streamUrl!;
    final companion = task.needsAudioMerge && !_isUnusableUrl(audioUrl)
        ? audioUrl
        : null;
    task.pendingCompanionBytes = null;
    if (companion != null) {
      task.pendingCompanionBytes = 0;
      final probeClient = http.Client();
      try {
        task.pendingCompanionBytes =
            (await _probeSizeUrl(probeClient, task, companion)) ?? 0;
      } finally {
        probeClient.close();
      }
      if (task.status != DownloadStatus.downloading) return;
    }

    final savePath = task.savePath;
    if (savePath == null || savePath.isEmpty) {
      throw const _DownloadException(
        'Invalid download destination path',
        retryable: false,
      );
    }

    // ---- 2. The main payload --------------------------------------------
    if (!_savedFileIsComplete(task)) {
      final path = Uri.tryParse(targetUrl)?.path.toLowerCase() ?? '';
      final progressive =
          !task.isHls &&
          RegExp(r'\.(mp4|m4v|webm|mkv|mov|mp3|m4a|aac|flac|opus|ogg|wav)$')
              .hasMatch(path);
      Future<void> downloadWithNativeEngine() async {
        final file = await _transferResolvedWithYtDlp(task, targetUrl);
        if (file == null) return;
        _adoptNativeFile(task, file);
        task.downloadedBytes = File(task.savePath!).lengthSync();
        task.totalBytes = task.downloadedBytes;
      }

      final nativeHls = task.isHls || _looksLikeHls(targetUrl);
      final dash = task.ext.toLowerCase() == 'mpd' || path.endsWith('.mpd');
      if (dash && !YtDlpService.instance.supported) {
        throw const _DownloadException(
          'DASH downloads are not supported on this device.',
          retryable: false,
        );
      }
      if (dash ||
          (Platform.isAndroid &&
              !task.isImageTask &&
              !progressive &&
              (nativeHls || task.category != 'movie')) ||
          (task.hlsVariantResolution != null &&
              YtDlpService.instance.supported)) {
        await downloadWithNativeEngine();
      } else {
        try {
          await _downloadPayload(task, targetUrl);
        } on Exception {
          if (!Platform.isAndroid || progressive || task.isImageTask) rethrow;
          if (task.status != DownloadStatus.downloading) return;
          await downloadWithNativeEngine();
        }
      }
      if (task.status != DownloadStatus.downloading) return;
      task.payloadVerified = true;
    }

    if (task.status != DownloadStatus.downloading) return;

    // ---- 3. Companion audio + merge for adaptive (video-only) formats ----
    if (task.needsAudioMerge) {
      if (companion == null) {
        task.completionNote =
            'No separate audio track was published for this stream';
      } else {
        final audioBytes = task.pendingCompanionBytes ?? 0;
        task.pendingCompanionBytes = null;
        task.totalBytes = audioBytes > 0
            ? task.downloadedBytes + audioBytes
            : 0;
        task.totalBytesIsEstimate = false;
        if (Platform.isAndroid) {
          final file = await _transferResolvedWithYtDlp(
            task,
            companion,
            companion: true,
          );
          if (file == null) return;
          final target = File(_companionAudioPath(task));
          if (target.existsSync()) target.deleteSync();
          file.renameSync(target.path);
        } else {
          await _downloadCompanionAudio(task, companion, audioBytes);
        }
        if (task.status != DownloadStatus.downloading) return;
        await _mergeCompanionAudio(task);
      }
    }

    if (task.status != DownloadStatus.downloading) return;

    // ---- 4. Every non-movie VIDEO leaves this app as a real MP4 ----------
    if (!task.isImageTask && !task.isAudio && task.category != 'movie') {
      await _ensureMp4Output(task);
      if (task.status != DownloadStatus.downloading) return;
    }

    // ---- 5. Every AUDIO pick leaves this app as a real 320kbps MP3 -------
    if (task.isAudio && task.ext.toLowerCase() == 'mp3') {
      await _ensureMp3Output(task);
      if (task.status != DownloadStatus.downloading) return;
    }

    _markCompleted(task);
  }

  /// Guarantees the finished video file is MP4 when the user asked for a
  /// normal (non-movie, non-audio) download.
  ///
  /// Runs as the CONVERT PHASE: the download slider has already reached 100%,
  /// so progress here feeds [DownloadTask.convertStage] / convertProgress and
  /// the task is only completed once this ends. The swap is a lossless remux
  /// — the file keeps the exact byte size it downloaded, never more.
  Future<void> _ensureMp4Output(DownloadTask task) async {
    final path = task.savePath;
    if (path == null || path.isEmpty) return;
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp4')) return;

    task.convertStage = 'Converting to MP4…';
    task.convertProgress = 0.0;
    task.speedBytesPerSec = 0;
    notifyListeners();

    final out = await MediaMuxService.instance.convertToMp4(
      path,
      onProgress: (p) {
        task.convertProgress = p;
        notifyListeners();
      },
    );
    task.convertStage = null;
    if (out != null && out != path) {
      try {
        File(path).deleteSync();
      } catch (_) {}
      task.savePath = out;
      task.ext = 'mp4';
      task.completionNote = 'Converted to MP4';
    } else if (out == path) {
      task.ext = 'mp4';
    } else {
      task.completionNote =
          'Saved in its original format — this device cannot convert it';
    }
  }

  /// Guarantees an audio download named *.mp3 really IS an MP3.
  ///
  /// YouTube serves AAC/OPUS only, so the fetched original track is encoded
  /// to 320 kbps MP3 (FFmpeg-Kit on Android, ffmpeg on desktop) and swapped
  /// into the same file. This is the CONVERT PHASE of an audio task: the byte
  /// download already finished, so progress drives [DownloadTask.convertStage]
  /// and the task only completes when the encoder is done. A device without
  /// any encoder keeps the original audio bytes and says so honestly.
  Future<void> _ensureMp3Output(DownloadTask task) async {
    final path = task.savePath;
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (!file.existsSync()) return;
    if (_looksLikeMp3(file)) return;

    task.convertStage = 'Converting to MP3…';
    task.convertProgress = 0.0;
    task.speedBytesPerSec = 0;
    notifyListeners();

    // The temp output MUST keep a .mp3 suffix — ffmpeg picks the muxer from
    // the file extension and refuses anything like "song.mp3.enc.tmp".
    final tmpPath = '$path.mp3enc.mp3';
    final out = await MediaMuxService.instance.convertToMp3(
      path,
      outPath: tmpPath,
      onProgress: (p) {
        task.convertProgress = p;
        notifyListeners();
      },
    );
    task.convertStage = null;
    if (out != null && File(out).existsSync() && File(out).lengthSync() > 0) {
      try {
        // rename(2) over the original replaces it atomically on POSIX — a
        // separate delete first only added a window where BOTH steps could
        // fail (file busy) and strand the encoded MP3 next to a fake one.
        File(out).renameSync(path);
        task.completionNote = 'Converted to 320 kbps MP3';
      } catch (e) {
        debugPrint('MP3 swap failed for $path: $e');
        try {
          final bytes = File(out).readAsBytesSync();
          File(path).writeAsBytesSync(bytes);
          File(out).deleteSync();
          task.completionNote = 'Converted to 320 kbps MP3';
        } catch (e2) {
          debugPrint('MP3 copy fallback failed for $path: $e2');
          try {
            File(out).deleteSync();
          } catch (_) {}
          task.completionNote = 'Saved as its original audio — MP3 swap failed';
        }
      }
    } else {
      task.completionNote =
          'Saved in its original audio format — this device cannot convert it';
    }
  }

  /// First bytes of a genuine MP3: an 'ID3' tag or an MPEG frame sync.
  static bool _looksLikeMp3(File file) {
    try {
      final raf = file.openSync();
      try {
        final head = List<int>.filled(4, 0);
        final read = raf.readIntoSync(head);
        if (read < 2) return false;
        if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33)
          return true; // 'ID3'
        return head[0] == 0xFF && (head[1] & 0xE0) == 0xE0; // frame sync
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  Future<MediaFormat?> _extractFallbackFormat(
    DownloadTask task,
    String? preferredFormatId,
  ) async {
    try {
      final res = await ExtractorService.instance.extract(task.originalUrl);
      if (res == null) return null;
      final pool = task.isAudio ? res.audioFormats : res.videoFormats;
      final withUrl = pool.where((f) => (f.url ?? '').isNotEmpty).toList();
      MediaFormat? chosen;
      final prefId = preferredFormatId ?? '';
      if (prefId.isNotEmpty) {
        chosen = withUrl.where((f) => f.id == prefId).firstOrNull;
      }
      chosen ??= withUrl.isNotEmpty ? withUrl.first : null;
      return chosen;
    } catch (e) {
      debugPrint('Extract fallback failed for ${task.title}: $e');
      return null;
    }
  }

  void _markCompleted(DownloadTask task) {
    final path = task.savePath;
    final file = path == null ? null : File(path);
    final length = file != null && file.existsSync() ? file.lengthSync() : 0;
    if (!task.payloadVerified || length <= 0) {
      throw const _DownloadException(
        'The download did not produce a complete file',
      );
    }
    task.downloadedBytes = length;
    task.totalBytes = length;
    task.totalBytesIsEstimate = false;
    task.pendingCompanionBytes = null;
    task.status = DownloadStatus.completed;
    task.completedAt = DateTime.now();
    task.statusNote = null;
    task.speedBytesPerSec = 0;
    for (final s in task.segments) {
      s.isCompleted = true;
      s.speedBytesPerSec = 0;
    }
    _persistTasks();
    notifyListeners();

    // The finished file AND its cover picture go straight into the system
    // Download folder + Gallery index — no user action, no extra tap.
    GalleryMediaService.instance.archiveCompletedTask(task, _downloadDirectory);
  }

  // ---------------------------------------------------------------------------
  // One payload pass: probe the server, then pull the bytes (segmented or
  // single stream). Failures THROW so the retry loop above can mint a fresh
  // URL and RESUME, instead of leaving a permanent "network connection failed"
  // behind for the user to stare at.
  // ---------------------------------------------------------------------------
  Future<void> _downloadPayload(DownloadTask task, String streamUrl) async {
    File(task.savePath!).parent.createSync(recursive: true);

    final clients = <http.Client>[];
    _activeClients[task.id] = clients;

    try {
      // HLS playlists need segment-by-segment downloads; a plain HTTP fetch
      // would only save the .m3u8 text file.
      if (task.isHls || _looksLikeHls(streamUrl)) {
        await _downloadHls(task, streamUrl);
        return;
      }
      // 2. Probe non-GoogleVideo servers with Range header (bytes=0-0) to check Range support & total file size.
      // Note: googlevideo.com CDN flags rapid connect-disconnect probes as bot behavior (403),
      // and InnerTube already provides the exact file size via contentLength.
      final googleVideo = isGoogleVideoUrl(streamUrl);
      int totalLength = googleVideo
          ? int.tryParse(
                  Uri.tryParse(streamUrl)?.queryParameters['clen'] ?? '',
                ) ??
                0
          : 0;
      // GoogleVideo dislikes throwaway probe requests, but its signed links do
      // accept Range. Skip the probe and try parallel ranges directly; the
      // range worker falls back to one stream if a host refuses.
      bool supportsRanges = googleVideo && totalLength > 0;
      String? validator;

      if (!googleVideo) {
        final probeClient = http.Client();
        clients.add(probeClient);

        try {
          final probeReq = http.Request('GET', Uri.parse(streamUrl));
          probeReq.headers.addAll(
            _mediaHeadersFor(task, streamUrl, range: 'bytes=0-0'),
          );
          final probeRes = await probeClient
              .send(probeReq)
              .timeout(const Duration(seconds: 10));

          final probeType = (probeRes.headers['content-type'] ?? '')
              .toLowerCase();
          if (probeType.contains('mpegurl') ||
              probeType.contains('vnd.apple')) {
            await probeRes.stream.drain<void>();
            await _downloadHls(task, streamUrl);
            return;
          }

          if (probeRes.statusCode == 206) {
            _alignTaskExtension(
              task,
              probeRes.headers['content-type'],
              streamUrl,
            );
            final cr = probeRes.headers['content-range'];
            if (cr != null && cr.contains('/')) {
              final totalStr = cr.split('/').last.trim();
              final parsedTotal = int.tryParse(totalStr);
              if (parsedTotal != null && parsedTotal > 0) {
                supportsRanges = cr == 'bytes 0-0/$parsedTotal';
                validator = probeRes.headers['etag'];
                totalLength = parsedTotal;
                task.totalBytes = parsedTotal;
              }
            }
          } else if (probeRes.statusCode == 200) {
            _alignTaskExtension(
              task,
              probeRes.headers['content-type'],
              streamUrl,
            );
            if (probeRes.contentLength != null && probeRes.contentLength! > 0) {
              totalLength = probeRes.contentLength!;
              task.totalBytes = totalLength;
            }
          } else if (probeRes.statusCode == 403 || probeRes.statusCode == 404) {
            await probeRes.stream.drain<void>();
            final fresh = await _resolveSource(task, task.preferredFormatId);
            if (fresh == null ||
                fresh.videoUrl.isEmpty ||
                fresh.videoUrl == streamUrl) {
              final code = probeRes.statusCode;
              throw HttpException('HTTP $code from the media server');
            }
            streamUrl = fresh.videoUrl;
            task.streamUrl = fresh.videoUrl;

            final retryReq = http.Request('GET', Uri.parse(streamUrl));
            retryReq.headers.addAll(
              _mediaHeadersFor(task, streamUrl, range: 'bytes=0-0'),
            );
            final retryRes = await probeClient
                .send(retryReq)
                .timeout(const Duration(seconds: 20));
            final retryType = (retryRes.headers['content-type'] ?? '')
                .toLowerCase();
            if (retryType.contains('mpegurl') ||
                retryType.contains('vnd.apple')) {
              await retryRes.stream.drain<void>();
              await _downloadHls(task, streamUrl);
              return;
            }
            if (retryRes.statusCode != 206 && retryRes.statusCode != 200) {
              final code = retryRes.statusCode;
              await retryRes.stream.drain<void>();
              throw HttpException('HTTP $code from the media server');
            }

            _alignTaskExtension(
              task,
              retryRes.headers['content-type'],
              streamUrl,
            );
            if (retryRes.statusCode == 206) {
              final cr = retryRes.headers['content-range'];
              if (cr != null && cr.contains('/')) {
                final totalStr = cr.split('/').last.trim();
                final parsedTotal = int.tryParse(totalStr);
                if (parsedTotal != null && parsedTotal > 0) {
                  supportsRanges = cr == 'bytes 0-0/$parsedTotal';
                  validator = retryRes.headers['etag'];
                  totalLength = parsedTotal;
                  task.totalBytes = parsedTotal;
                }
              }
            } else {
              if (retryRes.contentLength != null &&
                  retryRes.contentLength! > 0) {
                totalLength = retryRes.contentLength!;
                task.totalBytes = totalLength;
              }
            }
          } else {
            await probeRes.stream.drain<void>();
          }
        } catch (e) {
          debugPrint('Probe error for ${task.title}: $e');
          if (e is HttpException) rethrow;
        } finally {
          probeClient.close();
          clients.remove(probeClient);
        }
      }

      if (task.status != DownloadStatus.downloading) return;

      if (totalLength > 0) {
        _setMeasuredSize(task, (bytes: totalLength, estimated: false));
      }
      task.statusNote = 'Starting download…';
      notifyListeners();

      if (supportsRanges &&
          totalLength >= (googleVideo ? 50 : 16) * 1024 * 1024 &&
          await _downloadMovieRanges(
            task,
            streamUrl,
            totalLength,
            validator,
            clients,
          )) {
        return;
      }
      if (task.status != DownloadStatus.downloading) return;
      task.threadsCount = 1;
      await _downloadSingleStream(task, streamUrl, totalLength, clients);
    } finally {
      _activeClients.remove(task.id);
      for (final c in clients) {
        try {
          c.close();
        } catch (_) {}
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Companion audio + merge for adaptive (video-only) streams
  // ---------------------------------------------------------------------------

  /// Path of the temporary audio half of an adaptive video download.
  String _companionAudioPath(DownloadTask task) {
    final base = task.savePath!.replaceFirst(RegExp(r'\.[^./\\]+$'), '');
    final ext = (task.audioExt ?? 'm4a').replaceAll(
      RegExp(r'[^a-zA-Z0-9]'),
      '',
    );
    return '$base.audio.${ext.isEmpty ? 'm4a' : ext}';
  }

  /// Downloads the ORIGINAL audio track that belongs to an adaptive video
  /// stream, resuming from whatever partial bytes a previous attempt already
  /// wrote. Nothing is re-encoded: the saved file keeps the exact bitrate the
  /// source published.
  Future<void> _downloadCompanionAudio(
    DownloadTask task,
    String url,
    int audioTotal,
  ) async {
    final audioPath = _companionAudioPath(task);
    final file = File(audioPath);
    file.parent.createSync(recursive: true);

    int start = 0;
    if (file.existsSync()) {
      final len = file.lengthSync();
      if (len > 0) start = len;
    }

    final videoBytes = task.downloadedBytes;
    int audioReceived = start;

    void refreshTotals() {
      task.totalBytes = audioTotal > 0 ? videoBytes + audioTotal : 0;
      task.totalBytesIsEstimate = false;
      task.downloadedBytes = videoBytes + audioReceived;
    }

    refreshTotals();
    task.statusNote = 'Downloading the original audio track…';
    notifyListeners();

    final isGv = isGoogleVideoUrl(url);
    const int chunkSize = 2 * 1024 * 1024;
    final holder = _activeClients.putIfAbsent(task.id, () => <http.Client>[]);

    try {
      final headers = <String, String>{};
      if (isGv) {
        headers['User-Agent'] = InnerTubeService.userAgentForUrl(url);
      } else {
        headers['User-Agent'] = defaultUserAgent;
        try {
          final uri = Uri.parse(url);
          if (uri.host.isNotEmpty) {
            headers['Referer'] = '${uri.scheme}://${uri.host}/';
          }
        } catch (_) {}
      }

      final sink = file.openWrite(
        mode: start > 0 ? FileMode.append : FileMode.write,
      );
      DateTime lastSpeed = DateTime.now();
      DateTime lastUi = DateTime.now();
      int lastBytes = audioReceived;
      DateTime windowStart = DateTime.now();
      int windowStartBytes = audioReceived;

      try {
        while (audioTotal <= 0 || audioReceived < audioTotal) {
          if (task.status != DownloadStatus.downloading) return;

          final chunkClient = http.Client();
          holder.add(chunkClient);

          try {
            final req = http.Request('GET', Uri.parse(url));
            req.headers.addAll(headers);
            if (isGv) {
              final end = (audioTotal > 0)
                  ? (audioReceived + chunkSize - 1).clamp(0, audioTotal - 1)
                  : (audioReceived + chunkSize - 1);
              req.headers['Range'] = 'bytes=$audioReceived-$end';
            } else {
              req.headers['Range'] = 'bytes=$audioReceived-';
            }

            final res = await chunkClient.send(req).timeout(_responseTimeout);

            if (res.statusCode == 416) {
              await res.stream.drain<void>();
              break;
            }

            if (res.statusCode != 200 && res.statusCode != 206) {
              final code = res.statusCode;
              await res.stream.drain<void>();
              if (isGv && (code == 403 || code == 410)) {
                debugPrint(
                  '[DownloadManager] googlevideo rejected the audio link '
                  '($code; ${_googlevideoIdentity(url)}) — minting a fresh one',
                );
                try {
                  final fresh = await ExtractorService.instance
                      .resolveLiveStreamUrl(
                        task.originalUrl,
                        isAudio: true,
                        audioTrackId: task.audioTrackId,
                      );
                  if (fresh != null && fresh.isNotEmpty) {
                    url = fresh;
                    task.audioStreamUrl = fresh;
                    headers['User-Agent'] = InnerTubeService.userAgentForUrl(
                      fresh,
                    );
                    continue;
                  }
                } catch (_) {}
              }
              throw HttpException('HTTP $code for the audio track');
            }

            if (res.statusCode == 206) {
              final cr = res.headers['content-range'];
              if (cr != null && cr.contains('/')) {
                final parsedTotal =
                    int.tryParse(cr.split('/').last.trim()) ?? 0;
                if (parsedTotal > 0) audioTotal = parsedTotal;
              }
            } else if (res.statusCode == 200 && audioReceived == 0) {
              audioTotal = res.contentLength ?? 0;
            }
            refreshTotals();

            await for (final chunk in res.stream.timeout(_chunkIdleTimeout)) {
              if (task.status != DownloadStatus.downloading) return;

              sink.add(chunk);
              audioReceived += chunk.length;

              final now = DateTime.now();
              final speedMs = now.difference(lastSpeed).inMilliseconds;
              if (speedMs >= 300) {
                task.speedBytesPerSec =
                    (audioReceived - lastBytes) / (speedMs / 1000.0);
                lastSpeed = now;
                lastBytes = audioReceived;
              }

              final windowMs = now.difference(windowStart).inMilliseconds;
              if (windowMs >= 60000) {
                final moved = audioReceived - windowStartBytes;
                final notFinishedYet =
                    audioTotal == 0 || audioReceived < audioTotal;
                if (moved < _minBytesPerMinute && notFinishedYet) {
                  throw const _DownloadException(
                    'Audio stream was throttled by the source',
                  );
                }
                windowStart = now;
                windowStartBytes = audioReceived;
              }

              task.downloadedBytes = videoBytes + audioReceived;
              if (now.difference(lastUi).inMilliseconds >= 120) {
                lastUi = now;
                notifyListeners();
              }
            }

            if (!isGv) break;
            if (audioTotal > 0 && audioReceived >= audioTotal) break;
          } finally {
            holder.remove(chunkClient);
            try {
              chunkClient.close();
            } catch (_) {}
          }
        }
        await sink.flush();
      } finally {
        try {
          await sink.flush();
          await sink.close();
        } catch (_) {}
      }

      if (task.status != DownloadStatus.downloading) return;

      final written = file.existsSync() ? file.lengthSync() : 0;
      if (written <= 0) {
        throw const _DownloadException('The audio track arrived empty');
      }
      task.downloadedBytes = videoBytes + written;
      task.totalBytes = videoBytes + (audioTotal > 0 ? audioTotal : written);
      task.statusNote = null;
      notifyListeners();
    } finally {
      if (holder.isEmpty) _activeClients.remove(task.id);
    }
  }

  /// Combines the downloaded video with its audio track into ONE playable
  /// file, stream-copied (never re-encoded) so the original resolution and the
  /// original audio quality are preserved exactly.
  Future<void> _mergeCompanionAudio(DownloadTask task) async {
    final target = task.savePath!;
    final videoFile = File(target);
    if (!videoFile.existsSync() || videoFile.lengthSync() <= 0) {
      throw const _DownloadException('The video file was lost before merging');
    }
    final audioPath = _companionAudioPath(task);
    if (!File(audioPath).existsSync()) {
      throw const _DownloadException('The audio track was lost before merging');
    }

    task.convertStage = 'Combining original video + audio…';
    task.convertProgress = 0.0;
    task.speedBytesPerSec = 0;
    notifyListeners();

    final ext = (task.ext.isNotEmpty ? task.ext : 'mp4').replaceAll(
      RegExp(r'[^a-zA-Z0-9]'),
      '',
    );
    final mergedPath = target.replaceFirst(
      RegExp(r'\.[^./\\]+$'),
      '.merged.$ext',
    );

    final result = await MediaMuxService.instance.merge(
      videoPath: target,
      audioPath: audioPath,
      outputPath: mergedPath,
      onProgress: (p) {
        task.convertProgress = p;
        notifyListeners();
      },
    );
    task.convertStage = null;

    if (result.success) {
      try {
        if (videoFile.existsSync()) videoFile.deleteSync();
        File(mergedPath).renameSync(target);
      } catch (e) {
        // The swap failed but the merged file is on disk: point the task at it.
        debugPrint('Could not swap in the merged file for ${task.title}: $e');
        task.savePath = mergedPath;
        try {
          if (videoFile.existsSync()) videoFile.deleteSync();
        } catch (_) {}
      }
      try {
        File(audioPath).deleteSync();
      } catch (_) {}
      task.statusNote = null;
      return;
    }

    // This device could not combine the two tracks. Keep BOTH original parts
    // so nothing the user spent bandwidth on is thrown away.
    debugPrint('Audio merge failed for ${task.title}: ${result.error}');
    task.statusNote = null;
    task.completionNote =
        'Saved as two parts (merge unavailable) — ${_shortError(result.error)}';
  }

  /// Maps an HTTP media type to the container extension we should save.
  String? _extensionForContentType(String? contentType) {
    final ct = (contentType ?? '').toLowerCase();
    if (ct.isEmpty) return null;
    if (ct.contains('audio/mp4') || ct.contains('audio/x-m4a')) return 'm4a';
    if (ct.contains('audio/mpeg') || ct.contains('audio/mp3')) return 'mp3';
    if (ct.contains('audio/aac')) return 'aac';
    if (ct.contains('audio/flac') || ct.contains('audio/x-flac')) return 'flac';
    if (ct.contains('audio/opus')) return 'opus';
    if (ct.contains('audio/ogg') || ct.contains('application/ogg'))
      return 'ogg';
    if (ct.contains('audio/wav') || ct.contains('audio/x-wav')) return 'wav';
    if (ct.contains('audio/webm')) return 'webm';
    if (ct.contains('video/mp4')) return 'mp4';
    if (ct.contains('video/webm')) return 'webm';
    if (ct.contains('video/x-matroska') || ct.contains('video/matroska'))
      return 'mkv';
    if (ct.contains('video/quicktime')) return 'mov';
    return null;
  }

  /// The source decides the real container. A quick audio download starts from
  /// a 30s store preview (M4A) but is then replaced by a full-length stream
  /// (often WebM/Opus), so the filename must follow the bytes we actually save.
  void _alignTaskExtension(DownloadTask task, String? contentType, String url) {
    String? ext = task.isImageTask
        ? switch (contentType?.split(';').first.trim().toLowerCase()) {
            'image/jpeg' => 'jpg',
            'image/png' => 'png',
            'image/webp' => 'webp',
            'image/avif' => 'avif',
            'image/gif' => 'gif',
            _ => null,
          }
        : _extensionForContentType(contentType);
    if (ext == null) {
      try {
        final uri = Uri.parse(url);
        final mime = uri.queryParameters['mime'];
        if (mime != null && mime.isNotEmpty) {
          ext = _extensionForContentType(mime);
        }
        if (ext == null) {
          final path = uri.path.toLowerCase();
          for (final candidate in const [
            'mp4',
            'm4a',
            'webm',
            'mkv',
            'mov',
            'mp3',
            'aac',
            'flac',
            'opus',
            'ogg',
            'wav',
          ]) {
            if (path.endsWith('.$candidate')) {
              ext = candidate;
              break;
            }
          }
        }
      } catch (_) {}
    }
    if (ext == null || ext == task.ext) return;

    final path = task.savePath;
    if (path == null || path.isEmpty) {
      task.ext = ext;
      return;
    }
    final updated = path.replaceFirst(RegExp(r'\.[^./\\]+$'), '.$ext');
    task.ext = ext;
    task.savePath = updated == path ? '$path.$ext' : updated;
  }

  bool _looksLikeHls(String? url) {
    if (url == null || url.isEmpty) return false;
    final lower = url.toLowerCase();
    try {
      return Uri.parse(url).path.toLowerCase().endsWith('.m3u8') ||
          lower.contains('.m3u8?');
    } catch (_) {
      return lower.contains('.m3u8');
    }
  }

  Future<int?> _probeSizeUrl(
    http.Client client,
    DownloadTask task,
    String url,
  ) {
    final uri = Uri.tryParse(url);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
      return Future.value();
    }
    return probeResourceBytes(client, uri, _mediaHeadersFor(task, url));
  }

  Future<DownloadSize?> _probePlaylistSize(
    http.Client client,
    DownloadTask task,
    _HlsPlaylist playlist,
  ) async {
    if (!playlist.usesByteRanges) {
      final sampled = await probeSegmentedSize(
        playlist.segments,
        initSegment: playlist.initSegment,
        probe: (url) => _probeSizeUrl(client, task, url),
      );
      if (sampled != null) return sampled;
    }
    if (playlist.bandwidth > 0 && playlist.duration > 0) {
      return (
        bytes: (playlist.bandwidth * playlist.duration / 8).round(),
        estimated: true,
      );
    }
    return null;
  }

  Future<DownloadSize?> _probeNativeHlsSize(
    DownloadTask task,
    String url,
  ) async {
    final client = http.Client();
    Future<DownloadSize?> inspect() async {
      final playlist = await _resolveHlsPlaylist(
        client,
        url,
        task.originalUrl,
        headers: task.headers,
        exactResolution: task.hlsVariantResolution,
        forSizing: true,
      );
      if (playlist == null ||
          !playlist.isFinite ||
          task.status != DownloadStatus.downloading) {
        return null;
      }
      final video = await _probePlaylistSize(client, task, playlist);
      if (video == null) return null;
      final audioUrl = playlist.externalAudioUrl;
      if (audioUrl == null) {
        return (
          bytes: video.bytes,
          estimated: video.estimated || task.hlsVariantResolution == null,
        );
      }
      final audio = await _resolveHlsPlaylist(
        client,
        audioUrl,
        task.originalUrl,
        headers: task.headers,
        forSizing: true,
      );
      if (audio == null ||
          !audio.isFinite ||
          task.status != DownloadStatus.downloading) {
        return null;
      }
      final audioSize = await _probePlaylistSize(client, task, audio);
      if (audioSize == null) return null;
      return (bytes: video.bytes + audioSize.bytes, estimated: true);
    }

    try {
      return await inspect().timeout(const Duration(seconds: 8));
    } on Exception {
      return null;
    } finally {
      client.close();
    }
  }

  /// Downloads an HLS stream by resolving the master playlist, choosing the
  /// highest-bandwidth variant and concatenating every media segment (plus the
  /// fMP4 init segment) into one playable file. Failures THROW so the retry
  /// loop can fetch a fresh playlist URL and try again.
  Future<void> _downloadHls(DownloadTask task, String playlistUrl) async {
    final client = http.Client();
    IOSink? sink;
    try {
      final playlist = await _resolveHlsPlaylist(
        client,
        playlistUrl,
        task.originalUrl.isNotEmpty ? task.originalUrl : playlistUrl,
        headers: task.headers,
        exactResolution: task.hlsVariantResolution,
      );
      if (playlist == null || playlist.segments.isEmpty) {
        throw const _DownloadException('Could not resolve the HLS playlist');
      }

      final initialSize = await _probePlaylistSize(client, task, playlist);
      if (task.status != DownloadStatus.downloading) return;
      if (initialSize != null) {
        _setMeasuredSize(task, initialSize);
        unawaited(_persistTasks());
      }
      task.statusNote = 'Starting download…';
      notifyListeners();

      final savePath = task.savePath;
      if (savePath == null || savePath.isEmpty) {
        throw const _DownloadException(
          'Invalid download destination path',
          retryable: false,
        );
      }

      final segmentPaths = playlist.segments
          .map((u) => Uri.tryParse(u)?.path.toLowerCase() ?? '')
          .toList();
      final usesFmp4 =
          playlist.initSegment != null ||
          segmentPaths.any((p) => p.endsWith('.m4s') || p.endsWith('.mp4'));
      final firstExt = segmentPaths.isNotEmpty
          ? segmentPaths.first.split('.').last
          : '';
      final outExt = usesFmp4
          ? 'mp4'
          : (const {
                  'aac',
                  'mp3',
                  'm4a',
                  'flac',
                  'opus',
                  'ogg',
                }.contains(firstExt)
                ? firstExt
                : 'ts');

      final targetPath = savePath.replaceFirst(
        RegExp(r'\.[^./\\]+$'),
        '.$outExt',
      );
      task.savePath = targetPath;

      final file = File(targetPath);
      file.parent.createSync(recursive: true);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
      sink = file.openWrite();
      task.downloadedBytes = 0;

      // HLS publishes no byte total up front. A fixed guess per segment made
      // the displayed size drift far away from the real file (a 357 MB movie
      // showing 500 MB), so the total is now a ROLLING estimate: every
      // finished segment updates the average, and totalBytes is always the
      // exact bytes written plus that average for what remains — it converges
      // on the true size and _markCompleted ends it on the exact file length.
      final segmentCount =
          playlist.segments.length + (playlist.initSegment != null ? 1 : 0);
      int segmentsSeen = 0;
      int bytesSeen = 0;
      int writtenAtSegStart = 0;
      void refineTotalEstimate() {
        if (segmentsSeen <= 0 || initialSize != null) return;
        final avg = bytesSeen ~/ segmentsSeen;
        task.totalBytes =
            bytesSeen +
            avg * (segmentCount - segmentsSeen).clamp(0, segmentCount);
        task.totalBytesIsEstimate = segmentsSeen < segmentCount;
      }

      DateTime lastSpeedTime = DateTime.now();
      int lastDownloaded = task.downloadedBytes;
      DateTime lastUiNotify = DateTime.now();

      Future<bool> copyResource(String url) async {
        final req = http.Request('GET', Uri.parse(url));
        req.headers.addAll(_mediaHeadersFor(task, url));
        final res = await client.send(req).timeout(_responseTimeout);
        if (res.statusCode != 200 && res.statusCode != 206) {
          final code = res.statusCode;
          throw HttpException('HTTP $code for an HLS resource');
        }
        writtenAtSegStart = task.downloadedBytes;
        await for (final chunk in res.stream.timeout(_chunkIdleTimeout)) {
          if (task.status != DownloadStatus.downloading) return false;
          sink!.add(chunk);
          task.downloadedBytes += chunk.length;

          final now = DateTime.now();
          final elapsedMs = now.difference(lastSpeedTime).inMilliseconds;
          if (elapsedMs >= 300) {
            final delta = task.downloadedBytes - lastDownloaded;
            task.speedBytesPerSec = delta / (elapsedMs / 1000.0);
            lastSpeedTime = now;
            lastDownloaded = task.downloadedBytes;
          }
          if (now.difference(lastUiNotify).inMilliseconds >= 120) {
            lastUiNotify = now;
            notifyListeners();
          }
        }
        return true;
      }

      if (playlist.initSegment != null) {
        final ok = await copyResource(playlist.initSegment!);
        if (!ok) return;
        segmentsSeen++;
        bytesSeen += task.downloadedBytes - writtenAtSegStart;
        refineTotalEstimate();
      }
      for (final segment in playlist.segments) {
        if (task.status != DownloadStatus.downloading) return;
        final ok = await copyResource(segment);
        if (!ok) return;
        segmentsSeen++;
        bytesSeen += task.downloadedBytes - writtenAtSegStart;
        refineTotalEstimate();
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (task.status != DownloadStatus.downloading) return;
      if (!file.existsSync() || file.lengthSync() <= 0) {
        throw const _DownloadException('The HLS stream arrived empty');
      }
    } finally {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}
      client.close();
    }
  }

  Future<String?> _fetchPlaylistText(
    http.Client client,
    String url,
    String referer, {
    Map<String, String> headers = const {},
    int redirects = 0,
  }) async {
    if (redirects > 5) return null;
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(downloadHeadersFor(url));
      if (referer.isNotEmpty) req.headers['Referer'] = referer;
      // Extension-supplied auth (Cookie/token) — protected playlists 403
      // without it.
      req.headers.addAll(headers);
      final res = await client.send(req).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 300 &&
          res.statusCode < 400 &&
          res.headers['location'] != null) {
        final loc = Uri.parse(url).resolve(res.headers['location']!).toString();
        await res.stream.drain<void>();
        return await _fetchPlaylistText(
          client,
          loc,
          referer,
          headers: headers,
          redirects: redirects + 1,
        );
      }
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      return await res.stream.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    }
  }

  Future<_HlsPlaylist?> _resolveHlsPlaylist(
    http.Client client,
    String url,
    String referer, {
    int depth = 0,
    Map<String, String> headers = const {},
    String? exactResolution,
    bool forSizing = false,
  }) async {
    if (depth > 3) return null;
    final text = await _fetchPlaylistText(
      client,
      url,
      referer,
      headers: headers,
    );
    if (text == null || !text.contains('#EXTM3U')) return null;

    final base = Uri.parse(url);
    final lines = const LineSplitter()
        .convert(text)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // Only Auto may pick a different resolution by bandwidth.
    if (text.contains('#EXT-X-STREAM-INF')) {
      final variants = <_HlsVariant>[];
      var requiresNativeAudio = false;
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
        if (exactResolution != null &&
            RegExp(r'(?:^|[:,])RESOLUTION=(\d+x\d+)(?:,|$)')
                    .firstMatch(line)
                    ?.group(1) !=
                exactResolution) {
          continue;
        }

        final bandwidth =
            int.tryParse(
              RegExp(r'AVERAGE-BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ??
                  RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ??
                  '',
            ) ??
            0;
        String? externalAudioUrl;
        if (exactResolution != null || forSizing) {
          final audioGroup = RegExp(r'(?:^|[:,])AUDIO="([^"]+)"')
              .firstMatch(line)
              ?.group(1);
          final candidates = lines.where(
            (entry) =>
                audioGroup != null &&
                entry.startsWith('#EXT-X-MEDIA:') &&
                entry.contains('TYPE=AUDIO') &&
                entry.contains('GROUP-ID="$audioGroup"') &&
                entry.contains('URI='),
          );
          final audio =
              candidates
                  .where((entry) => entry.contains('DEFAULT=YES'))
                  .firstOrNull ??
              candidates.firstOrNull;
          if (audio != null) {
            final uri = RegExp(r'URI="([^"]+)"').firstMatch(audio)?.group(1);
            if (uri != null) externalAudioUrl = base.resolve(uri).toString();
            if (!forSizing) {
              requiresNativeAudio = true;
              continue;
            }
          }
        }
        for (int j = i + 1; j < lines.length; j++) {
          final next = lines[j];
          if (next.startsWith('#')) continue;
          variants.add(
            _HlsVariant(
              bandwidth: bandwidth,
              url: base.resolve(next).toString(),
              externalAudioUrl: externalAudioUrl,
            ),
          );
          break;
        }
      }
      if (exactResolution != null && variants.isEmpty) {
        throw _DownloadException(
          requiresNativeAudio
              ? 'This version has a separate audio track. Download it on Android or macOS.'
              : 'This source no longer offers the selected video resolution.',
          retryable: false,
        );
      }
      variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
      for (final variant in variants) {
        final media = await _resolveHlsPlaylist(
          client,
          variant.url,
          referer,
          depth: depth + 1,
          headers: headers,
          exactResolution: exactResolution,
          forSizing: forSizing,
        );
        if (media != null && media.segments.isNotEmpty) {
          return _HlsPlaylist(
            segments: media.segments,
            initSegment: media.initSegment,
            duration: media.duration,
            isFinite: media.isFinite,
            usesByteRanges: media.usesByteRanges,
            bandwidth: media.bandwidth > 0
                ? media.bandwidth
                : variant.bandwidth,
            externalAudioUrl:
                media.externalAudioUrl ?? variant.externalAudioUrl,
          );
        }
      }
      return null;
    }
    if (exactResolution != null && depth == 0) {
      throw const _DownloadException(
        'Could not confirm the selected video resolution from this source.',
        retryable: false,
      );
    }

    // Media playlist.
    String? initSegment;
    var duration = 0.0;
    var usesByteRanges = false;
    final segments = <String>[];
    for (final line in lines) {
      if (line.startsWith('#EXTINF:')) {
        duration += double.tryParse(line.substring(8).split(',').first) ?? 0;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:') || line.contains('BYTERANGE=')) {
        usesByteRanges = true;
      }
      if (line.startsWith('#EXT-X-KEY')) {
        // AES-encrypted HLS cannot be decoded without a key handshake.
        if (!forSizing && !line.contains('METHOD=NONE')) return null;
        continue;
      }
      if (line.startsWith('#EXT-X-MAP')) {
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (match != null) {
          initSegment = base.resolve(match.group(1)!).toString();
        }
        continue;
      }
      if (line.startsWith('#')) continue;
      segments.add(base.resolve(line).toString());
    }

    if (segments.isEmpty) return null;
    return _HlsPlaylist(
      segments: segments,
      initSegment: initSegment,
      duration: duration,
      isFinite:
          lines.contains('#EXT-X-ENDLIST') ||
          lines.contains('#EXT-X-PLAYLIST-TYPE:VOD'),
      usesByteRanges: usesByteRanges,
    );
  }

  /// ONE connection per (re)link, streaming continuously to the end.
  ///
  /// googlevideo signs every URL for a single sequential fetch: bouncing
  /// between many byte-range requests on one signature gets flagged, which
  /// is exactly what made downloads stall after a while and flash
  /// "Reconnecting — attempt N". So each attempt is ONE plain GET that
  /// streams until the file ends; only when the CDN genuinely closes the
  /// socket or the signature expires does this mint ONE fresh link and
  /// resume from the current byte offset — written bytes never restart.
  Future<void> _downloadGoogleVideoChunked(
    DownloadTask task,
    String streamUrl,
    int totalLength,
    List<http.Client> clients,
  ) async {
    final file = File(task.savePath!);
    int downloaded = 0;

    if (file.existsSync()) {
      final len = file.lengthSync();
      if (len > 0 && (totalLength <= 0 || len < totalLength)) {
        downloaded = len;
      }
    }

    task.downloadedBytes = downloaded;

    DateTime lastSpeedTime = DateTime.now();
    int lastDownloaded = downloaded;
    DateTime lastUiNotify = DateTime.now();

    final sink = file.openWrite(
      mode: downloaded > 0 ? FileMode.append : FileMode.write,
    );
    String url = streamUrl;
    int relinks = 0;

    try {
      while (totalLength <= 0 || downloaded < totalLength) {
        if (task.status != DownloadStatus.downloading) return;

        final streamClient = http.Client();
        clients.add(streamClient);
        final bytesAtConnect = downloaded;
        try {
          final req = http.Request('GET', Uri.parse(url));
          req.headers['User-Agent'] = InnerTubeService.userAgentForUrl(url);
          if (downloaded > 0) req.headers['Range'] = 'bytes=$downloaded-';

          final res = await streamClient.send(req).timeout(_responseTimeout);

          if (res.statusCode == 416) {
            final range = res.headers['content-range'] ?? '';
            final remoteLength = int.tryParse(range.split('/').last);
            if (downloaded > 0 && remoteLength == downloaded) break;
            throw const _DownloadException(
              'The server refused the resume position',
            );
          }

          if (res.statusCode != 200 && res.statusCode != 206) {
            final code = res.statusCode;
            await res.stream.drain<void>();
            if (code == 403 || code == 410) {
              debugPrint(
                '[DownloadManager] googlevideo rejected the link '
                '($code; ${_googlevideoIdentity(url)}) — minting a fresh one',
              );
              InnerTubeService.instance.clearCache();
              if (relinks >= 2) {
                InnerTubeService.instance.rotateClient();
              }
            }
            if (++relinks > 2 && (code == 403 || code == 410)) {
              throw _DownloadException(
                'YouTube refused the download link (HTTP $code)',
                retryable: false,
              );
            }
            if (relinks > 5) throw HttpException('HTTP $code from googlevideo');
            await Future.delayed(Duration(milliseconds: 300 * relinks));
            final fresh = await _remintGoogleVideoUrl(task);
            if (fresh == null) {
              throw HttpException('HTTP $code from googlevideo');
            }
            url = fresh;
            continue;
          }

          if (downloaded > 0) {
            final contentRange = res.headers['content-range'] ?? '';
            final start = RegExp(r'^bytes (\d+)-').firstMatch(contentRange);
            if (res.statusCode != 206 ||
                int.tryParse(start?.group(1) ?? '') != downloaded) {
              throw const _DownloadException(
                'YouTube returned an invalid resume range',
                retryable: false,
              );
            }
          }

          if (res.headers['content-range'] != null) {
            final cr = res.headers['content-range']!;
            if (cr.contains('/')) {
              final parsedTotal = int.tryParse(cr.split('/').last.trim());
              if (parsedTotal != null && parsedTotal > 0) {
                totalLength = parsedTotal;
                task.totalBytes = parsedTotal;
              }
            }
          } else if (downloaded == 0 &&
              res.contentLength != null &&
              res.contentLength! > 0) {
            totalLength = res.contentLength!;
            task.totalBytes = totalLength;
          }

          await for (final chunk in res.stream.timeout(_chunkIdleTimeout)) {
            if (task.status != DownloadStatus.downloading) return;
            sink.add(chunk);
            downloaded += chunk.length;
            task.downloadedBytes = downloaded;

            final now = DateTime.now();
            final elapsedMs = now.difference(lastSpeedTime).inMilliseconds;
            if (elapsedMs >= 300) {
              final delta = downloaded - lastDownloaded;
              task.speedBytesPerSec = delta / (elapsedMs / 1000.0);
              lastSpeedTime = now;
              lastDownloaded = downloaded;
            }

            if (now.difference(lastUiNotify).inMilliseconds >= 120) {
              lastUiNotify = now;
              notifyListeners();
            }
          }

          // If the whole file landed we are done.
          if (totalLength <= 0 || downloaded >= totalLength) break;

          // Continue a short response from the last written byte.
          if (downloaded > bytesAtConnect) {
            relinks = 0;
            continue;
          }

          // Zero bytes received on a 200/206 connection -> server closed socket prematurely
          if (++relinks > 12) {
            throw const _DownloadException(
              'The video server kept closing the connection',
            );
          }
          final fresh = await _remintGoogleVideoUrl(task);
          if (fresh != null) url = fresh;
          task.statusNote = _resumeNote(totalLength, downloaded);
          notifyListeners();
          await Future.delayed(const Duration(milliseconds: 500));
        } catch (e) {
          // A dead socket or a stalled connection is not a failure: the
          // bytes already written stand, and the next iteration asks for
          // the CURRENT offset over one fresh connection. Only genuine
          // server rejections escalate.
          if (e is TimeoutException ||
              e is SocketException ||
              e is http.ClientException) {
            if (task.status != DownloadStatus.downloading) return;
            if (downloaded > bytesAtConnect) relinks = 0;
            if (++relinks > 12) rethrow;
            final fresh = await _remintGoogleVideoUrl(task);
            if (fresh != null) url = fresh;
            task.speedBytesPerSec = 0;
            task.statusNote = _resumeNote(totalLength, downloaded);
            notifyListeners();
            await Future.delayed(const Duration(milliseconds: 500));
            continue;
          }
          rethrow;
        } finally {
          streamClient.close();
          clients.remove(streamClient);
        }
      }
      await sink.flush();
    } finally {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }

    if (task.status != DownloadStatus.downloading) return;

    final written = file.existsSync() ? file.lengthSync() : 0;
    if (written <= 0) {
      throw const _DownloadException('The download arrived empty');
    }
    task.downloadedBytes = written;
    task.totalBytes = written;
  }

  /// A short, calm status line shown while a fresh link is being minted.
  /// Never says "reconnecting" — the download is CONTINUING, and saying so
  /// in plain words is both honest and far less alarming.
  static String _resumeNote(int totalLength, int downloaded) {
    if (totalLength > 0) {
      final pct = (downloaded * 100 / totalLength).clamp(0, 100).toInt();
      return 'Continuing from $pct%…';
    }
    return 'Continuing the download…';
  }

  /// Mints ONE fresh, correctly-signed link for the exact format this task
  /// is already downloading (same resolution AND same dub language).
  /// Returns null when the task carries no re-analysable page URL.
  Future<String?> _remintGoogleVideoUrl(DownloadTask task) async {
    InnerTubeService.instance.clearCache();
    if (_isUnusableUrl(task.originalUrl)) {
      if (task.category == 'audio') {
        try {
          final fresh = await ExtractorService.instance
              .resolveLiveAudioStreamForTrack(task.title, task.author);
          if (fresh != null && fresh.isNotEmpty) {
            task.streamUrl = fresh;
            return fresh;
          }
        } catch (_) {}
      }
      return null;
    }
    try {
      final fresh = await ExtractorService.instance.resolveLiveStreamUrl(
        task.originalUrl,
        isAudio: task.isAudio,
        preferredFormatId: task.preferredFormatId,
        preferredLabel: task.formatLabel,
        audioTrackId: task.audioTrackId,
      );
      if (fresh != null && fresh.isNotEmpty) {
        task.streamUrl = fresh;
        return fresh;
      }
    } catch (e) {
      debugPrint('[DownloadManager] googlevideo re-mint failed: $e');
    }

    return null;
  }

  /// Fetches bounded batches of ranges and writes them in order. Only complete
  /// batches reach disk, so an unsupported range or interrupted connection can
  /// fall back to the regular downloader at the last contiguous byte.
  Future<bool> _downloadMovieRanges(
    DownloadTask task,
    String url,
    int total,
    String? validator,
    List<http.Client> activeClients,
  ) async {
    const blockSize = 4 * 1024 * 1024;
    const connections = 10;
    final file = File(task.savePath!);
    var offset = await file.exists() ? await file.length() : 0;
    if (offset > total) return false;
    task.threadsCount = connections;
    task.downloadedBytes = offset;
    final clients = List.generate(connections, (_) => http.Client());
    activeClients.addAll(clients);
    RandomAccessFile? output;
    try {
      output = await file.open(mode: FileMode.append);
      while (offset < total && task.status == DownloadStatus.downloading) {
        final startTime = Stopwatch()..start();
        final remaining = (total - offset + blockSize - 1) ~/ blockSize;
        final blocks = await Future.wait(
          List.generate(remaining.clamp(1, connections), (index) async {
            final start = offset + index * blockSize;
            final end = (start + blockSize - 1).clamp(start, total - 1);
            final request = http.Request('GET', Uri.parse(url));
            request.headers.addAll(
              _mediaHeadersFor(task, url, range: 'bytes=$start-$end'),
            );
            request.headers['Accept-Encoding'] = 'identity';
            if (validator != null && !validator.startsWith('W/')) {
              request.headers['If-Range'] = validator;
            }
            final response = await clients[index]
                .send(request)
                .timeout(_responseTimeout);
            if (response.statusCode != 206 ||
                response.headers['content-range'] !=
                    'bytes $start-$end/$total') {
              throw const _DownloadException(
                'The server did not honor the parallel range',
              );
            }
            final bytes = BytesBuilder(copy: false);
            await for (final chunk in response.stream.timeout(
              _chunkIdleTimeout,
            )) {
              bytes.add(chunk);
              if (bytes.length > end - start + 1) {
                throw const _DownloadException(
                  'The server returned an oversized range',
                );
              }
            }
            if (bytes.length != end - start + 1) {
              throw const _DownloadException(
                'The connection ended inside a range',
              );
            }
            return bytes.takeBytes();
          }),
          eagerError: true,
        );
        if (task.status != DownloadStatus.downloading) return true;
        final before = offset;
        for (final block in blocks) {
          await output.writeFrom(block);
          offset += block.length;
        }
        if (task.status != DownloadStatus.downloading) return true;
        task.downloadedBytes = offset;
        task.speedBytesPerSec =
            (offset - before) *
            1000000 /
            startTime.elapsedMicroseconds.clamp(1, 1 << 30);
        notifyListeners();
      }
      return true;
    } on Exception catch (error) {
      debugPrint(
        'Parallel movie transfer fell back to a single connection: $error',
      );
      return false;
    } finally {
      for (final client in clients) {
        client.close();
        activeClients.remove(client);
      }
      await output?.close();
      if (task.status == DownloadStatus.cancelled && await file.exists()) {
        await file.delete();
      }
    }
  }

  /// Single high-speed stream downloader, used for hosts without Range support
  /// AND for googlevideo URLs (which reject multi-connection byte ranges).
  ///
  /// RESUMES: when an earlier attempt already wrote part of the file, the
  /// request starts at that byte offset — a dropped connection costs seconds
  /// instead of re-downloading gigabytes of 4K.
  Future<void> _downloadSingleStream(
    DownloadTask task,
    String streamUrl,
    int totalLength,
    List<http.Client> clients,
  ) async {
    // EVERY googlevideo URL — progressive itags included — goes through the
    // continuous single-connection streamer: it never restarts written bytes,
    // quietly re-mints a spent signature and resumes from the current offset,
    // which is exactly what the CDN expects for one sequential fetch.
    if (isGoogleVideoUrl(streamUrl)) {
      await _downloadGoogleVideoChunked(task, streamUrl, totalLength, clients);
      return;
    }

    final client = http.Client();
    clients.add(client);

    try {
      final file = File(task.savePath!);

      // How much of the file a previous attempt already delivered.
      int start = 0;
      if (file.existsSync()) {
        final len = file.lengthSync();
        if (len > 0 && (totalLength <= 0 || len <= totalLength)) {
          start = len;
        }
      }

      http.StreamedResponse res;
      bool append;

      if (start > 0) {
        final resumeReq = http.Request('GET', Uri.parse(streamUrl));
        resumeReq.headers.addAll(
          _mediaHeadersFor(task, streamUrl, range: 'bytes=$start-'),
        );
        res = await client.send(resumeReq).timeout(_responseTimeout);

        if (res.statusCode == 206) {
          append = true;
        } else if (res.statusCode == 200) {
          // Server ignored the range and is streaming the whole file again.
          append = false;
          start = 0;
        } else if (res.statusCode == 416) {
          final range = res.headers['content-range'] ?? '';
          if (range == 'bytes */$start' && totalLength == start) {
            task.downloadedBytes = start;
            task.totalBytes = start;
            return;
          }
          throw const _DownloadException(
            'The server refused the resume offset',
          );
        } else {
          final code = res.statusCode;
          await res.stream.drain<void>();
          // A spent signature usually answers 403 here — the retry loop mints
          // a fresh one and resumes.
          throw HttpException('HTTP $code');
        }
      } else {
        // Initial download: normal full-stream GET request without arbitrary artificial clamp
        final headers = _mediaHeadersFor(task, streamUrl);
        final req = http.Request('GET', Uri.parse(streamUrl));
        req.headers.addAll(headers);
        res = await client.send(req).timeout(_responseTimeout);

        if (res.statusCode != 200 && res.statusCode != 206) {
          final code = res.statusCode;
          throw HttpException('HTTP $code');
        }
        append = false;
      }

      if (task.status != DownloadStatus.downloading) return;

      final mime = (res.headers['content-type'] ?? '')
          .split(';')
          .first
          .toLowerCase();
      if (const {
        'text/html',
        'application/json',
        'text/xml',
        'application/xml',
        'application/dash+xml',
      }.contains(mime)) {
        throw const _DownloadException(
          'The server returned a page instead of media',
          retryable: false,
        );
      }
      int expectedTotal = res.contentLength ?? totalLength;
      int? rangeEnd;
      if (res.statusCode == 206) {
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
            .firstMatch(res.headers['content-range'] ?? '');
        final rangeStart = int.tryParse(range?.group(1) ?? '');
        rangeEnd = int.tryParse(range?.group(2) ?? '');
        final fullLength = int.tryParse(range?.group(3) ?? '');
        if (rangeStart != start ||
            rangeEnd == null ||
            fullLength == null ||
            rangeEnd < start ||
            rangeEnd >= fullLength ||
            (append && totalLength > 0 && totalLength != fullLength)) {
          throw const _DownloadException(
            'The server returned an invalid resume range',
          );
        }
        expectedTotal = fullLength;
      }
      _alignTaskExtension(task, res.headers['content-type'], streamUrl);
      final destination = File(task.savePath!);
      if (append && destination.path != file.path) {
        file.renameSync(destination.path);
      }
      if (expectedTotal > 0) {
        _setMeasuredSize(task, (bytes: expectedTotal, estimated: false));
      }

      int received = start;
      task.downloadedBytes = received;
      notifyListeners();

      DateTime lastSpeedTime = DateTime.now();
      int lastDownloaded = received;
      DateTime lastUiNotify = DateTime.now();
      DateTime windowStart = DateTime.now();
      int windowStartBytes = received;

      final sink = destination.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in res.stream.timeout(_chunkIdleTimeout)) {
          if (task.status != DownloadStatus.downloading) return;

          sink.add(chunk);
          received += chunk.length;
          task.downloadedBytes = received;

          final now = DateTime.now();
          final elapsedMs = now.difference(lastSpeedTime).inMilliseconds;
          if (elapsedMs >= 300) {
            final delta = received - lastDownloaded;
            task.speedBytesPerSec = delta / (elapsedMs / 1000.0);
            lastSpeedTime = now;
            lastDownloaded = received;
          }

          // A stream that crawls is throttled or its signature expired — a
          // fresh URL beats waiting hours for a file that will not finish.
          final windowMs = now.difference(windowStart).inMilliseconds;
          if (windowMs >= 60000) {
            final moved = received - windowStartBytes;
            final notFinishedYet =
                task.totalBytes <= 0 || received < task.totalBytes;
            if (moved < _minBytesPerMinute && notFinishedYet) {
              throw const _DownloadException(
                'The stream was throttled by the source',
              );
            }
            windowStart = now;
            windowStartBytes = received;
          }

          if (now.difference(lastUiNotify).inMilliseconds >= 120) {
            lastUiNotify = now;
            notifyListeners();
          }
        }
        await sink.flush();
      } finally {
        try {
          await sink.flush();
          await sink.close();
        } catch (_) {}
      }

      if (task.status != DownloadStatus.downloading) return;

      final written = destination.existsSync() ? destination.lengthSync() : 0;
      if (written <= 0) {
        throw const _DownloadException('The download arrived empty');
      }
      if ((rangeEnd != null && written != rangeEnd + 1) ||
          (expectedTotal > 0 && written != expectedTotal)) {
        throw const _DownloadException(
          'The connection ended before the whole file arrived',
        );
      }
      task.downloadedBytes = written;
      task.totalBytes = written;
    } finally {
      client.close();
      clients.remove(client);
    }
  }

  void pauseTask(DownloadTask task) {
    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued) {
      task.status = DownloadStatus.paused;
      task.speedBytesPerSec = 0;
      for (final seg in task.segments) {
        seg.speedBytesPerSec = 0;
      }
      if (YtDlpService.instance.supported) {
        YtDlpService.instance.cancel(task.id);
      }
      final active = _activeClients[task.id];
      if (active != null) {
        for (final c in active) {
          try {
            c.close();
          } catch (_) {}
        }
      }
      _persistTasks();
      notifyListeners();
    }
  }

  void resumeTask(DownloadTask task) {
    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.failed) {
      final active = _runningDownloads[task.id];
      if (active != null) {
        // whenComplete also fires when the tracked download ended in an error,
        // otherwise the task would stay paused forever.
        unawaited(active.whenComplete(() => resumeTask(task)));
        return;
      }
      task.errorMessage = null;
      if (task.series != null) {
        task.status = DownloadStatus.queued;
        unawaited(_persistTasks());
        _startQueuedDownloads();
      } else {
        task.status = DownloadStatus.downloading;
        _persistTasks();
        notifyListeners();
        _downloadRealMedia(task);
      }
    }
  }

  void cancelTask(DownloadTask task) {
    task.status = DownloadStatus.cancelled;
    if (YtDlpService.instance.supported) {
      YtDlpService.instance.cancel(task.id);
    }
    final active = _activeClients[task.id];
    if (active != null) {
      for (final c in active) {
        try {
          c.close();
        } catch (_) {}
      }
    }
    // Clean up temporary parts (segments, companion audio half, merge output)
    _deleteTempFiles(task);
    _tasks.remove(task);
    VirtualFolderService.instance.removeTaskEverywhere(task.id);
    _persistTasks();
    notifyListeners();
  }

  /// Removes a task entry from the download index without deleting its file from disk
  /// (used when moving a file into the Secret Vault).
  Future<void> removeTaskOnly(DownloadTask task) async {
    _tasks.remove(task);
    // Folder tiles must stop counting an id that no longer exists in the
    // index — otherwise the outside says "N Files" while the folder is empty.
    await VirtualFolderService.instance.removeTaskEverywhere(task.id);
    await _persistTasks();
    notifyListeners();
  }

  Future<void> restoreCompletedTask(DownloadTask task) async {
    await ready;
    _tasks.removeWhere(
      (existing) =>
          existing.id == task.id || existing.savePath == task.savePath,
    );
    _tasks.insert(0, task);
    await _persistTasks();
    notifyListeners();
  }

  void deleteTask(DownloadTask task) {
    if (task.savePath != null) {
      final f = File(task.savePath!);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
      _deleteTempFiles(task);
    }
    _tasks.remove(task);
    VirtualFolderService.instance.removeTaskEverywhere(task.id);
    _persistTasks();
    notifyListeners();
  }

  /// Deletes a selected movie/series batch and persists the change once.
  /// Each task is removed from custom folders as well as from disk and the
  /// Downloads index, so season/full-series deletion cannot leave stale rows.
  Future<void> deleteTasks(Iterable<DownloadTask> tasks) async {
    await ready;
    final ids = tasks.map((task) => task.id).toSet();
    if (ids.isEmpty) return;
    final selected = _tasks.where((task) => ids.contains(task.id)).toList();
    for (final task in selected) {
      final path = task.savePath;
      if (path != null && path.isNotEmpty) {
        final file = File(path);
        if (file.existsSync()) {
          try {
            file.deleteSync();
          } catch (_) {}
        }
        _deleteTempFiles(task);
      }
      await VirtualFolderService.instance.removeTaskEverywhere(task.id);
    }
    _tasks.removeWhere((task) => ids.contains(task.id));
    await _persistTasks();
    notifyListeners();
  }

  void clearCompleted() {
    for (final t in _tasks.where((t) => t.status == DownloadStatus.completed)) {
      VirtualFolderService.instance.removeTaskEverywhere(t.id);
    }
    _tasks.removeWhere((t) => t.status == DownloadStatus.completed);
    _persistTasks();
    notifyListeners();
  }

  /// Removes every side-car file an in-flight download may have produced:
  /// segment parts, the companion audio half and any merge output.
  void _deleteTempFiles(DownloadTask? task) {
    final savePath = task?.savePath;
    if (savePath == null || savePath.isEmpty) return;

    // Segmented download parts. The engine scales up to 16 threads, so the
    // sweep has to cover every .partN an interrupted pass may have opened.
    for (int i = 0; i < 16; i++) {
      final p = File('$savePath.part$i');
      if (p.existsSync()) {
        try {
          p.deleteSync();
        } catch (_) {}
      }
    }

    final base = savePath.replaceFirst(RegExp(r'\.[^./\\]+$'), '');
    final dir = Directory(base).parent;
    if (!dir.existsSync()) return;

    // "<base>.audio.*" companions, "<base>.merged.*" outputs and the
    // MediaMuxer in-progress "<output>.part" file next to them.
    final prefix = base.split(Platform.pathSeparator).last;
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith(prefix)) continue;
        final isTemp = name.contains('.audio.') || name.contains('.merged.');
        if (!isTemp) continue;
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// A download failure that carries an accurate, human readable reason.
///
/// The retry loop in `_downloadRealMedia` reads [retryable] to decide whether
/// another attempt is worthwhile; the UI shows [message] instead of the old
/// blanket "Network connection failed".
class _DownloadException implements Exception {
  const _DownloadException(this.message, {this.retryable = true});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

class _HlsVariant {
  const _HlsVariant({
    required this.bandwidth,
    required this.url,
    this.externalAudioUrl,
  });

  final int bandwidth;
  final String url;
  final String? externalAudioUrl;
}

class _HlsPlaylist {
  const _HlsPlaylist({
    required this.segments,
    this.initSegment,
    this.duration = 0,
    this.bandwidth = 0,
    this.usesByteRanges = false,
    this.isFinite = false,
    this.externalAudioUrl,
  });

  final List<String> segments;
  final String? initSegment;
  final double duration;
  final int bandwidth;
  final bool usesByteRanges;
  final bool isFinite;
  final String? externalAudioUrl;
}
