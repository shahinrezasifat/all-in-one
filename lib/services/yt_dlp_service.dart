import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ytdlp_flutter/ytdlp_flutter.dart';

import 'download_size_probe.dart';

/// A quality tier parsed from yt-dlp's real format list. [selector] is passed
/// straight to yt-dlp's `-f` option by [Ytdlp.downloadAudio].
class YtDlpQuality {
  final String label;
  final String subtitle;
  final String selector;
  final bool is4k;

  const YtDlpQuality({
    required this.label,
    required this.subtitle,
    required this.selector,
    this.is4k = false,
  });
}

/// On-device yt-dlp wrapper. This is the PRIMARY YouTube resolver: running the
/// real yt-dlp bypasses YouTube's n-parameter throttling, SABR URLs and the
/// HTTP 403 wall that breaks youtube_explode / plain InnerTube.
class YtDlpService {
  YtDlpService._();
  static final YtDlpService instance = YtDlpService._();

  Future<void>? _initFuture;
  bool _initialized = false;

  bool get supported => Platform.isAndroid || Platform.isMacOS;

  bool get isReady => _initialized;

  /// Idempotent. First call may extract/download the engine — never block UI
  /// on it; callers await only when they actually need a resolve.
  Future<void> ensureInit() {
    if (!supported) return Future.value();
    final existing = _initFuture;
    if (existing != null) return existing;
    debugPrint('[YtDlp] initializing on-device engine…');
    _initFuture = Ytdlp.init()
        .then((_) {
          _initialized = true;
          debugPrint('[YtDlp] engine ready');
        })
        .catchError((Object e) {
          debugPrint('[YtDlp] init failed: $e');
          _initFuture = null;
          _initialized = false;
        });
    return _initFuture!;
  }

  static bool isYouTubeSite(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !const ['http', 'https'].contains(uri.scheme)) {
      return false;
    }
    final host = uri.host.toLowerCase();
    return host == 'youtu.be' ||
        const [
          'youtube.com',
          'youtube-nocookie.com',
        ].any((domain) => host == domain || host.endsWith('.$domain'));
  }

  static bool isYouTubeUrl(String url) => youtubeVideoUrl(url) != null;

  static String? youtubeVideoUrl(String url) {
    if (!isYouTubeSite(url)) return null;
    final uri = Uri.parse(url.trim());
    final parts = uri.pathSegments;
    if (parts.isEmpty) return null;
    final id = switch (parts.first) {
      _ when uri.host.toLowerCase() == 'youtu.be' => parts.first,
      'watch' => uri.queryParameters['v'],
      'shorts' || 'live' || 'embed' || 'v' when parts.length > 1 => parts[1],
      _ => null,
    };
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) return null;
    return Uri.https('www.youtube.com', '/watch', {'v': id}).toString();
  }

  final _infoCache = <String, _CachedInfo>{};

  Future<VideoInfo?> resolve(
    String url, {
    String? format,
    Map<String, String> headers = const {},
  }) async {
    if (!supported) return null;
    final canonical = youtubeVideoUrl(url) ?? url.trim();
    // The format picker already analysed the video; reuse that metadata when
    // the download starts so the same link is not resolved twice.
    if (format == null && headers.isEmpty) {
      final cached = _infoCache[canonical];
      if (cached != null &&
          DateTime.now().difference(cached.at) < const Duration(minutes: 15)) {
        return cached.info;
      }
    }
    await ensureInit();
    if (!_initialized) throw StateError('The download engine could not start');
    final info = await Ytdlp.getVideoInfo(
      canonical,
      format: format,
      headers: headers,
    ).timeout(
      const Duration(seconds: 6),
      onTimeout: () => throw TimeoutException(
        'The on-device engine took too long to read this video',
        const Duration(seconds: 6),
      ),
    );
    if (format == null && headers.isEmpty) {
      _infoCache[canonical] = _CachedInfo(DateTime.now(), info);
      if (_infoCache.length > 24) _infoCache.remove(_infoCache.keys.first);
    }
    return info;
  }

  /// Size of the selected transfer, including all requested tracks.
  static DownloadSize? selectedDownloadSize(VideoInfo info) {
    final root = info.raw;
    if (root == null || root['is_live'] == true) return null;
    DownloadSize? read(Map format) {
      final parts = format['requested_formats'] ?? format['requested_downloads'];
      if (parts is List && parts.isNotEmpty) {
        var bytes = 0;
        var estimated = false;
        for (final part in parts) {
          final size = part is Map ? read(part) : null;
          if (size == null) return null;
          bytes += size.bytes;
          estimated |= size.estimated;
        }
        return (bytes: bytes, estimated: estimated);
      }
      final exact = format['filesize'];
      if (exact is num && exact.isFinite && exact > 0) {
        return (bytes: exact.round(), estimated: false);
      }
      final approximate = format['filesize_approx'];
      if (approximate is num && approximate.isFinite && approximate > 0) {
        return (bytes: approximate.round(), estimated: true);
      }
      final duration = format['duration'] ?? info.durationSeconds;
      final bitrate = format['tbr'];
      if (duration is num && duration.isFinite && duration > 0 &&
          bitrate is num && bitrate.isFinite && bitrate > 0) {
        return (bytes: (duration * bitrate * 1000 / 8).round(), estimated: true);
      }
      return null;
    }
    return read(root);
  }

  /// Builds a clean quality ladder from the full yt-dlp info dict.
  List<YtDlpQuality> qualities(VideoInfo info) {
    final rawFormats = info.raw?['formats'];
    final formats = rawFormats is List
        ? rawFormats
        : [if (info.raw != null) info.raw];

    final byHeight = <int, Map<String, dynamic>>{};
    for (final entry in formats) {
      if (entry is! Map) continue;
      final f = Map<String, dynamic>.from(entry);
      final vcodec = (f['vcodec'] ?? '').toString();
      if (vcodec.isEmpty || vcodec == 'none') continue; // audio-only
      final h = (f['height'] as num?)?.toInt() ?? 0;
      if (h <= 0) continue;
      final existing = byHeight[h];
      final size = _size(f);
      final prevSize = existing == null ? -1 : _size(existing);
      if (existing == null || size > prevSize) byHeight[h] = f;
    }

    final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
    final out = <YtDlpQuality>[];
    for (final h in heights) {
      final f = byHeight[h]!;
      final fid = (f['format_id'] ?? '').toString();
      final ext = (f['ext'] ?? 'mp4').toString().toUpperCase();
      final hasAudio = (f['acodec'] ?? '').toString() != 'none';
      final selector = hasAudio && fid.isNotEmpty
          ? fid
          : 'bv*[height=$h]+ba/b[height=$h]';
      out.add(
        YtDlpQuality(
          label: h == 2160 ? '4K' : '${h}p',
          subtitle: hasAudio
              ? '$ext • video + audio${_sizeText(f)}'
              : '$ext • video + audio (merged)${_sizeText(f)}',
          selector: selector,
          is4k: h >= 2160,
        ),
      );
    }

    bool hasCodec(String key) => formats.any(
      (entry) => entry is Map && entry[key] is String && entry[key] != 'none',
    );
    if (out.isNotEmpty || hasCodec('vcodec')) {
      out.add(
        const YtDlpQuality(
          label: 'Best',
          subtitle: 'Highest available video quality',
          selector: 'bv*+ba/b',
        ),
      );
    }
    if (hasCodec('acodec')) {
      out.add(
        const YtDlpQuality(
          label: 'Audio',
          subtitle: 'MP3 audio',
          selector: 'bestaudio/best',
        ),
      );
    }
    return out;
  }

  static int _size(Map<String, dynamic> f) =>
      ((f['filesize'] ?? f['filesize_approx'] ?? 0) as num?)?.toInt() ?? 0;

  static String _sizeText(Map<String, dynamic> f) {
    final b = _size(f);
    if (b <= 0) return '';
    final mb = b / (1024 * 1024);
    return mb >= 1024
        ? ' • ${(mb / 1024).toStringAsFixed(1)} GB'
        : ' • ${mb.toStringAsFixed(0)} MB';
  }

  Future<String> download({
    required String url,
    required YtDlpQuality quality,
    required String outputDir,
    required String taskId,
    void Function(YtdlpProgress progress)? onProgress,
  }) async {
    await ensureInit();
    return Ytdlp.downloadAudio(
      url: url,
      outputDir: outputDir,
      taskId: taskId,
      format: quality.selector,
      onProgress: onProgress,
    );
  }

  static String? exactHlsSelector(String? dimensions) {
    final match = RegExp(r'^([1-9]\d*)x([1-9]\d*)$')
        .firstMatch(dimensions ?? '');
    if (match == null) return null;
    final filter = '[width=${match[1]}][height=${match[2]}]';
    return 'b$filter/bv$filter+ba';
  }

  /// Downloads with an explicit format selector (e.g. height-capped video+audio or audio only).
  Future<String> downloadFormat({
    required String url,
    required String formatSelector,
    required String outputDir,
    required String taskId,
    String? audioFormat,
    Map<String, String> headers = const {},
    void Function(YtdlpProgress progress)? onProgress,
  }) async {
    await ensureInit();
    if (!_initialized) throw StateError('The download engine could not start');
    try {
      return await Ytdlp.downloadAudio(
        url: youtubeVideoUrl(url) ?? url,
        outputDir: outputDir,
        taskId: taskId,
        format: formatSelector,
        audioFormat: audioFormat,
        headers: headers,
        onProgress: onProgress,
      );
    } on YtdlpException catch (error) {
      if (!error.toString().toLowerCase().contains('no file path')) rethrow;
      final uri = Uri.tryParse(url);
      final segments = uri?.pathSegments ?? const <String>[];
      final id =
          uri?.queryParameters['v'] ?? (segments.isEmpty ? '' : segments.last);
      if (!RegExp(r'^[\w-]{11}$').hasMatch(id)) rethrow;
      // The plugin names final files <video id>.<ext>. Match that exact
      // basename so partial downloads and unmerged format files are ignored.
      final extensions = audioFormat == null
          ? const ['mp4', 'webm', 'mkv', 'm4a', 'mp3', 'opus', 'aac', 'ogg']
          : [audioFormat];
      final directory = Directory(outputDir);
      if (!directory.existsSync()) rethrow;
      final candidates = extensions
          .map((ext) => File('$outputDir/$id.$ext'))
          .where((file) => file.existsSync() && file.lengthSync() > 0)
          .toList();
      if (candidates.length != 1) rethrow;
      return candidates.single.path;
    }
  }

  Future<bool> cancel(String taskId) async {
    if (!supported) return false;
    try {
      return await Ytdlp.cancel(taskId);
    } catch (_) {
      return false;
    }
  }

  /// Self-update the bundled yt-dlp engine (Android/macOS).
  Future<String?> update() async {
    if (!supported) return null;
    try {
      return await Ytdlp.update();
    } catch (e) {
      return 'Update failed: $e';
    }
  }
}

class _CachedInfo {
  const _CachedInfo(this.at, this.info);

  final DateTime at;
  final VideoInfo info;
}
