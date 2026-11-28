import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/download_task.dart';
import '../models/movie_model.dart';
import '../services/download_manager.dart';
import '../services/extractor_service.dart';
import '../services/movie_repository_service.dart';
import '../services/permission_service.dart';
import '../services/playback_controls.dart';
import '../services/preference_service.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../services/provider_engine/provider_models.dart';
import '../services/stream_fallback_service.dart';
import '../services/watch_history_service.dart';
import '../services/mpv_controller.dart';
import '../theme/app_palette.dart';
import '../utils/episode_parser.dart';
import '../widgets/mpv_view.dart';

/// Full-featured cinema player backed by **libmpv** — the same engine used by
/// mpvExtended (mpvEx). There is no second video engine in this screen.
///
/// Episode switching and server/provider switching are first-class controls,
/// because those are the two things this app needs that a plain file player
/// does not have.
class MpvPlayerScreen extends StatefulWidget {
  final MovieItem movie;
  final MovieSource initialSource;
  final int initialSeason;
  final int initialEpisode;
  final double initialPositionSeconds;
  final String? downloadTaskId;
  final List<DownloadTask> downloadedEpisodes;

  /// Full episode list resolved by the Series details screen. The player can
  /// then offer every episode instead of only the one currently playing.
  final List<ProviderEpisode> seriesEpisodes;
  final bool trailerOnly;
  final bool isLiveTv;
  final List<MovieSource> liveSources;

  MpvPlayerScreen({
    super.key,
    required this.movie,
    required this.initialSource,
    this.initialSeason = 1,
    this.initialEpisode = 1,
    this.initialPositionSeconds = 0.0,
    this.downloadTaskId,
    this.downloadedEpisodes = const [],
    this.seriesEpisodes = const [],
    this.trailerOnly = false,
    this.isLiveTv = false,
    this.liveSources = const [],
  });

  @override
  State<MpvPlayerScreen> createState() => _MpvPlayerScreenState();
}

class _MpvPlayerScreenState extends State<MpvPlayerScreen>
    with TickerProviderStateMixin {
  late MovieSource _currentSource;
  late int _currentSeasonNumber;
  late int _currentEpisodeNumber;
  late String _currentAudioTrack;
  late String _currentQuality;

  bool _mini = false;
  double _zoom = 1.0;
  double _zoomStart = 1.0;
  bool _completionPromptShown = false;
  double _currentSeconds = 0.0;
  double _totalSeconds = 7200.0;
  String? _videoErrorMessage;

  final MpvController _mpv = MpvController();
  String? _lastSubtitleBackColor;

  /// Provider episodes behind the picker entries that have no local file yet;
  /// their stream links are resolved only when the user selects them.
  final Map<(int, int), ProviderEpisode> _providerEpisodes = {};

  // Server failover engine
  bool _isAnalyzingServers = false;
  String _analyzingStatus = '';
  int _analyzedServerIndex = 0;
  int _totalCandidateServers = 0;
  bool _analysisInFlight = false;
  bool _usingAutomaticSource = false;
  int _sourceRequest = 0;
  final Set<String> _failedSourceKeys = {};
  final Set<String> _blacklistedThisPass = {};
  List<ProviderStreamReport> _lastProviderReports = [];
  String? _lastFailedSourceKey;
  Timer? _failoverWatchdog;

  // Gestures / HUD
  double _brightness = 0.75;
  double _volume = 0.80;
  double _volumeHud = 0.80;
  final _playbackControls = PlaybackControls();
  bool _brightnessGesture = false;
  bool _firstVerticalUpdate = true;
  bool _showBrightnessHud = false;
  bool _showVolumeHud = false;
  bool _showSeekHud = false;
  double _seekDeltaSeconds = 0.0;
  Timer? _hudDismissTimer;

  bool _showControls = true;
  Timer? _controlsDismissTimer;
  bool _isLocked = false;
  bool _isFullScreen = true;

  bool _showLeftDoubleTap = false;
  bool _showRightDoubleTap = false;

  @override
  void initState() {
    super.initState();
    _currentSource = widget.initialSource;
    _currentSeasonNumber = widget.initialSeason;
    _currentEpisodeNumber = widget.initialEpisode;
    for (final task in widget.downloadedEpisodes) {
      if (task.id != widget.downloadTaskId) continue;
      final parsedSeason =
          EpisodeParser.season(task.seriesSeason ?? '') ??
          EpisodeParser.season(task.title) ??
          EpisodeParser.season(task.savePath ?? '');
      final parsedEpisode =
          EpisodeParser.episode(task.title) ??
          EpisodeParser.episode(task.savePath ?? '');
      if (parsedSeason != null) _currentSeasonNumber = parsedSeason;
      if (parsedEpisode != null) _currentEpisodeNumber = parsedEpisode;
      break;
    }
    _currentSeconds = widget.initialPositionSeconds;
    _currentAudioTrack = widget.movie.audioTracks.isNotEmpty
        ? widget.movie.audioTracks.first
        : 'Original';
    _currentQuality = _currentSource.resolution;
    _totalSeconds = _parseDurationSeconds(widget.movie.duration);

    _mpv.addListener(_onMpvChanged);
    // Keep the display awake for the whole time the cinema player is on
    // screen — including buffering and seek pauses. Releasing it in dispose
    // covers back/exit and mini-player teardown.
    unawaited(_playbackControls.keepScreenOn(true));

    if (!widget.trailerOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        PreferenceService.instance.logVideoWatch(
          widget.movie,
          audioTrackLabel: _currentAudioTrack,
          quality: _currentQuality,
        );
      });
    }

    _applyPlayerOrientation(true);
    if (widget.trailerOnly) {
      unawaited(_playTrailer());
    } else if (widget.isLiveTv) {
      unawaited(_connectLiveTv());
    } else {
      unawaited(_loadCurrentSource());
    }
    _resetControlsTimer();
  }

  void _onMpvChanged() {
    if (!mounted) return;
    final controllerError = _mpv.error;
    if (controllerError != null && _lastFailedSourceKey == null) {
      _lastFailedSourceKey = StreamFallbackService.sourceKey(_currentSource);
      WidgetsBinding.instance.addPostFrameCallback((_) => _failForward());
    }
    if (_mpv.isCompleted) _maybePromptCompletion();
    if (_mpv.position > 0 && (_mpv.position - _currentSeconds).abs() >= 0.5) {
      _currentSeconds = _mpv.position;
      if (_currentSeconds.toInt() % 5 == 0) _saveProgress();
    }
    if (_mpv.duration > 0 && (_mpv.duration - _totalSeconds).abs() > 1) {
      _totalSeconds = _mpv.duration;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _mpv.removeListener(_onMpvChanged);
    _mpv.dispose();
    unawaited(_playbackControls.restoreBrightness());
    unawaited(_playbackControls.keepScreenOn(false));
    _failoverWatchdog?.cancel();
    _hudDismissTimer?.cancel();
    _controlsDismissTimer?.cancel();
    _saveProgress();
    _applyPlayerOrientation(false);
    super.dispose();
  }

  // ─── Playback ────────────────────────────────────────────────────────────

  Future<void> _playTrailer() async {
    setState(() {
      _isAnalyzingServers = true;
      _analyzingStatus = 'Loading trailer for "${widget.movie.title}"...';
    });
    try {
      final liveUrl = await ExtractorService.instance.resolveLiveMovieStream(
        widget.movie.title,
        resolution: '720p',
        preferMuxedForPlayback: true,
      );
      if (!mounted) return;
      if (liveUrl == null || liveUrl.isEmpty) {
        setState(() {
          _isAnalyzingServers = false;
          _videoErrorMessage =
              'No trailer available for "${widget.movie.title}".';
        });
        return;
      }
      setState(() {
        _isAnalyzingServers = false;
        _analyzingStatus = '';
      });
      await _mpv.load(
        path: liveUrl,
        headers: StreamFallbackService.streamHeadersFor(liveUrl),
        position: 0,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isAnalyzingServers = false;
        _videoErrorMessage = 'Could not load the trailer: $e';
      });
    }
  }

  Map<String, String> _headersFor(MovieSource source, String url) {
    final h = StreamFallbackService.streamHeadersFor(url);
    if (source.headers.isNotEmpty) h.addAll(source.headers);
    return h;
  }

  Future<void> _loadCurrentSource({
    MovieSource? source,
    double? position,
  }) async {
    final request = ++_sourceRequest;
    final active = source ?? _currentSource;
    final url = active.streamUrl.isNotEmpty
        ? active.streamUrl
        : active.downloadUrl;
    final start = position ?? _currentSeconds;
    _lastFailedSourceKey = null;
    setState(() {
      _currentSource = active;
      _currentQuality = active.resolution;
      _videoErrorMessage = null;
      _isAnalyzingServers = false;
    });
    if (url.isEmpty) {
      setState(() => _videoErrorMessage = 'This source has no playable URL.');
      return;
    }
    final uri = Uri.tryParse(url);
    final isRemote =
        uri != null &&
        uri.host.isNotEmpty &&
        ['http', 'https'].contains(uri.scheme);
    if (!isRemote && !File(url).existsSync()) {
      setState(() => _videoErrorMessage = 'The local file no longer exists.');
      return;
    }
    await _mpv.load(
      path: url,
      headers: _headersFor(active, url),
      position: widget.isLiveTv || widget.trailerOnly ? 0 : start,
      isLive: widget.isLiveTv,
    );
    if (request != _sourceRequest) return;
    // If nothing loads within the window, treat the server as dead.
    _failoverWatchdog?.cancel();
    _failoverWatchdog = Timer(const Duration(seconds: 18), () {
      if (!mounted || request != _sourceRequest) return;
      if (_mpv.duration <= 0 && _mpv.error == null) {
        _lastFailedSourceKey = StreamFallbackService.sourceKey(active);
        _failForward();
      }
    });
  }

  Future<void> _connectLiveTv({bool resetFailures = false}) async {
    if (_analysisInFlight) return;
    _analysisInFlight = true;
    if (resetFailures) _failedSourceKeys.clear();
    var extensionSources = <MovieSource>[];
    try {
      extensionSources = await ProviderEngineService.instance
          .resolveStreams(widget.movie, keepAllFormats: true)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}

    final candidates = <MovieSource>[
      ...extensionSources,
      widget.initialSource,
      ...widget.liveSources,
    ];
    final unique = <String, MovieSource>{};
    for (final s in candidates) {
      final url = s.streamUrl.isNotEmpty ? s.streamUrl : s.downloadUrl;
      if (url.trim().isNotEmpty) unique.putIfAbsent(url.trim(), () => s);
    }
    final queue = unique.values
        .where(
          (s) =>
              !_failedSourceKeys.contains(StreamFallbackService.sourceKey(s)),
        )
        .toList();
    setState(() {
      _isAnalyzingServers = queue.isNotEmpty;
      _analyzingStatus = 'Connecting to ${queue.length} channel link(s)…';
      _totalCandidateServers = queue.length;
      _analyzedServerIndex = 0;
      _videoErrorMessage = null;
    });
    try {
      for (var i = 0; i < queue.length; i++) {
        if (!mounted) return;
        final source = queue[i];
        setState(() {
          _analyzedServerIndex = i + 1;
          _analyzingStatus =
              'Trying ${source.serverName.isEmpty ? 'channel stream' : source.serverName}…';
        });
        await _loadCurrentSource(source: source, position: 0);
        // Give libmpv a moment to report a hard failure before trying the next.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        if (_mpv.error == null) {
          setState(() {
            _isAnalyzingServers = false;
            _analyzingStatus = '';
          });
          _analysisInFlight = false;
          return;
        }
        _failedSourceKeys.add(StreamFallbackService.sourceKey(source));
      }
      if (!mounted) return;
      setState(() {
        _isAnalyzingServers = false;
        _videoErrorMessage =
            'Could not connect to this channel. Tap Retry to try again.';
      });
    } finally {
      _analysisInFlight = false;
    }
  }

  /// Validate all installed providers, then try the healthiest streams in
  /// ranked order. A dead server is remembered and skipped on later passes.
  Future<void> _autoAnalyzeAndConnect({bool resetFailures = false}) async {
    if (_analysisInFlight) return;
    final request = ++_sourceRequest;
    _usingAutomaticSource = true;
    _analysisInFlight = true;
    if (resetFailures) _failedSourceKeys.clear();
    try {
      if (!mounted || request != _sourceRequest) return;
      setState(() {
        _isAnalyzingServers = true;
        _analyzingStatus = 'Scanning all installed providers...';
        _analyzedServerIndex = 0;
        _totalCandidateServers = 0;
        _videoErrorMessage = null;
      });
      List<ProviderStreamReport> reports;
      try {
        reports = await StreamFallbackService.instance.validateAcrossProviders(
          widget.movie,
          primary: widget.initialSource,
          season: _currentSeasonNumber,
          episode: _currentEpisodeNumber,
          forceRescan: resetFailures,
        );
      } catch (_) {
        reports = [];
      }
      if (!mounted || request != _sourceRequest) return;
      _lastProviderReports = reports;
      final queue = reports
          .where(
            (r) => !_failedSourceKeys.contains(
              StreamFallbackService.sourceKey(r.source),
            ),
          )
          .toList();
      setState(() {
        _totalCandidateServers = queue.length;
        _analyzingStatus =
            'Found ${queue.length} provider server(s). Connecting...';
      });
      for (var i = 0; i < queue.length; i++) {
        if (!mounted || request != _sourceRequest) return;
        final candidate = queue[i].source;
        setState(() {
          _analyzedServerIndex = i + 1;
          _analyzingStatus = 'Trying "${candidate.serverName}"…';
        });
        await _loadCurrentSource(source: candidate);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (!mounted || request != _sourceRequest) return;
        if (_mpv.error == null && _mpv.duration > 0) {
          setState(() {
            _isAnalyzingServers = false;
            _analyzingStatus = '✓ Connected to "${candidate.serverName}"';
          });
          _analysisInFlight = false;
          return;
        }
        _failedSourceKeys.add(StreamFallbackService.sourceKey(candidate));
      }
      if (!mounted || request != _sourceRequest) return;
      setState(() {
        _isAnalyzingServers = false;
        _videoErrorMessage =
            'None of the tested servers could play "${widget.movie.title}". '
            'Choose another server or retry.';
      });
    } finally {
      _analysisInFlight = false;
    }
  }

  void _failForward() {
    if (_analysisInFlight || widget.trailerOnly) return;
    final key = _lastFailedSourceKey;
    _lastFailedSourceKey = null;
    if (key != null) {
      _failedSourceKeys.add(key);
      _blacklistedThisPass.add(key);
    }
    _mpv.error; // errors are surfaced by the controller; clear via reload below
    if (widget.isLiveTv) {
      unawaited(_connectLiveTv());
    } else if (_usingAutomaticSource) {
      unawaited(_autoAnalyzeAndConnect());
    } else {
      unawaited(_autoAnalyzeAndConnect(resetFailures: false));
    }
  }

  double _parseDurationSeconds(String dur) {
    if (dur.contains('h')) {
      final parts = dur.split('h');
      final hours = double.tryParse(parts[0].trim()) ?? 2.0;
      final mins = parts.length > 1
          ? (double.tryParse(parts[1].replaceAll('m', '').trim()) ?? 0.0)
          : 0.0;
      return (hours * 3600) + (mins * 60);
    } else if (dur.contains('m')) {
      final mins = double.tryParse(dur.replaceAll('m', '').trim()) ?? 120.0;
      return mins * 60;
    }
    return 7200.0;
  }

  // ─── Episodes / progress ─────────────────────────────────────────────────

  ({int season, MovieEpisode episode})? _nextEpisode() {
    final seasons = _pickerSeasons();
    for (final season in seasons) {
      if (season.seasonNumber != _currentSeasonNumber) continue;
      final index = season.episodes.indexWhere(
        (e) => e.episodeNumber == _currentEpisodeNumber,
      );
      if (index >= 0 && index + 1 < season.episodes.length) {
        return (
          season: season.seasonNumber,
          episode: season.episodes[index + 1],
        );
      }
    }
    final nextSeason =
        seasons.where((s) => s.seasonNumber > _currentSeasonNumber).toList()
          ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    if (nextSeason.isNotEmpty && nextSeason.first.episodes.isNotEmpty) {
      return (
        season: nextSeason.first.seasonNumber,
        episode: nextSeason.first.episodes.first,
      );
    }
    return null;
  }

  void _playEpisode(({int season, MovieEpisode episode}) next) {
    setState(() {
      _currentSeasonNumber = next.season;
      _currentEpisodeNumber = next.episode.episodeNumber;
      _currentSeconds = 0;
      _completionPromptShown = false;
      _failedSourceKeys.clear();
      _currentSource = next.episode.sources.firstWhere(
        (source) =>
            source.streamUrl.isNotEmpty || source.downloadUrl.isNotEmpty,
      );
    });
    _saveProgress();
    unawaited(_loadCurrentSource(position: 0));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Playing S$_currentSeasonNumber E$_currentEpisodeNumber · ${next.episode.title}',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _maybePromptCompletion() {
    if (_completionPromptShown ||
        !mounted ||
        widget.trailerOnly ||
        widget.isLiveTv ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    if (widget.downloadTaskId == null && widget.movie.isSeries) {
      final next = _nextEpisode();
      if (next != null &&
          next.episode.sources.any(
            (source) =>
                source.streamUrl.isNotEmpty || source.downloadUrl.isNotEmpty,
          )) {
        _completionPromptShown = true;
        _playEpisode(next);
        return;
      }
    }
    final taskId = widget.downloadTaskId;
    if (taskId == null) return;
    final manager = DownloadManager.instance;
    final path = _currentSource.streamUrl;
    final task = manager.completedTasks
        .where((task) => task.id == taskId && task.savePath == path)
        .firstOrNull;
    if (task == null) return;
    _completionPromptShown = true;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Downloaded file'),
        content: Text(
          'You finished "${widget.movie.title}". Delete the downloaded file to free space?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (manager.completedTasks.contains(task) &&
                  task.savePath == path) {
                manager.deleteTask(task);
              }
              if (mounted) Navigator.of(context).pop();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _saveProgress() {
    if (widget.trailerOnly || widget.isLiveTv) return;
    final repositoryId = _currentSource.repoId.isNotEmpty
        ? _currentSource.repoId
        : widget.movie.repoId;
    final providerId = _currentSource.providerId.isNotEmpty
        ? _currentSource.providerId
        : widget.movie.providerId;
    final repository = MovieRepositoryService.instance.repositories
        .where((repo) => repo.id == repositoryId)
        .firstOrNull;
    final isAdultSource =
        repository?.isAdult == true ||
        (repository?.providers.any(
              (provider) => provider.id == providerId && provider.isAdult,
            ) ??
            false);
    WatchHistoryService.instance.saveProgress(
      movieId: widget.downloadTaskId ?? widget.movie.id,
      title: widget.movie.title,
      posterUrl: widget.movie.posterUrl,
      backdropUrl: widget.movie.backdropUrl,
      positionSeconds: _currentSeconds,
      totalSeconds: _totalSeconds,
      seasonNumber: _currentSeasonNumber,
      episodeNumber: _currentEpisodeNumber,
      episodeTitle: _getCurrentEpisodeTitle(),
      sourceUrl: _currentSource.downloadUrl,
      quality: _currentQuality,
      audioTrack: _currentAudioTrack,
      isDownloaded: widget.downloadTaskId != null,
      isAdultSource: isAdultSource,
      repositoryId: repositoryId,
      providerId: providerId,
    );
  }

  /// Seasons shown by the episode picker. Online seasons and locally
  /// downloaded episodes must be merged: returning [saved] whenever it is
  /// non-empty used to hide every completed download whose series metadata
  /// carried no episode sources, leaving an empty "No episodes available"
  /// sheet even though the files were on the device.
  List<MovieSeason> _pickerSeasons() {
    final saved = widget.movie.seasons;
    final groups = <int, List<MovieEpisode>>{};
    for (final task in widget.downloadedEpisodes) {
      final number =
          EpisodeParser.episode(task.title) ??
          EpisodeParser.episode(task.savePath ?? '');
      if (number == null) continue;
      final seasonNumber =
          EpisodeParser.season(task.seriesSeason ?? '') ??
          EpisodeParser.season(task.title) ??
          EpisodeParser.season(task.savePath ?? '') ??
          1;
      final path = task.savePath ?? '';
      final source = MovieSource(
        serverName: 'Downloaded',
        resolution: task.formatLabel.isNotEmpty ? task.formatLabel : 'Original',
        downloadUrl: path,
        streamUrl: path,
        fileSize: '',
        format: task.ext.toLowerCase(),
      );
      groups
          .putIfAbsent(seasonNumber, () => [])
          .add(
            MovieEpisode(
              episodeNumber: number,
              title: EpisodeParser.episodeName(task.title),
              thumbnailUrl: task.thumbnailUrl,
              synopsis: task.author,
              sources: [source],
            ),
          );
    }

    final fromProvider = <int, List<MovieEpisode>>{};
    for (final episode in widget.seriesEpisodes) {
      final seasonNumber = episode.season ?? 1;
      final title = episode.title.trim().isEmpty || episode.title == 'Episode'
          ? 'Episode ${episode.number}'
          : episode.title;
      fromProvider
          .putIfAbsent(seasonNumber, () => [])
          .add(
            MovieEpisode(
              episodeNumber: episode.number,
              title: title,
              sources: const [],
            ),
          );
      _providerEpisodes[(seasonNumber, episode.number)] = episode;
    }

    final merged = <int, MovieSeason>{
      for (final season in saved)
        season.seasonNumber: MovieSeason(
          seasonNumber: season.seasonNumber,
          title: season.title,
          episodes: List<MovieEpisode>.from(season.episodes),
        ),
    };
    for (final entry in groups.entries) {
      final existing = merged[entry.key];
      if (existing == null) {
        merged[entry.key] = MovieSeason(
          seasonNumber: entry.key,
          title: 'Season ${entry.key}',
          episodes: List<MovieEpisode>.from(entry.value),
        );
        continue;
      }
      final episodes = <int, MovieEpisode>{
        for (final episode in existing.episodes) episode.episodeNumber: episode,
      };
      for (final downloaded in entry.value) {
        // A local file always wins over a stale online link for the same
        // episode — this is what makes the picker playable offline.
        episodes[downloaded.episodeNumber] = downloaded;
      }
      merged[entry.key] = MovieSeason(
        seasonNumber: existing.seasonNumber,
        title: existing.title,
        episodes: episodes.values.toList(),
      );
    }

    for (final entry in fromProvider.entries) {
      final existing = merged[entry.key];
      if (existing == null) {
        merged[entry.key] = MovieSeason(
          seasonNumber: entry.key,
          title: 'Season ${entry.key}',
          episodes: List<MovieEpisode>.from(entry.value),
        );
        continue;
      }
      final episodes = <int, MovieEpisode>{
        for (final episode in existing.episodes) episode.episodeNumber: episode,
      };
      for (final providerEpisode in entry.value) {
        episodes.putIfAbsent(
          providerEpisode.episodeNumber,
          () => providerEpisode,
        );
      }
      merged[entry.key] = MovieSeason(
        seasonNumber: existing.seasonNumber,
        title: existing.title,
        episodes: episodes.values.toList(),
      );
    }

    if (merged.isEmpty && widget.movie.isSeries) {
      // The sheet is opened for the current episode even when no sibling is
      // completed yet; always give it at least that one playable entry.
      merged[_currentSeasonNumber] = MovieSeason(
        seasonNumber: _currentSeasonNumber,
        title: 'Season $_currentSeasonNumber',
        episodes: [
          MovieEpisode(
            episodeNumber: _currentEpisodeNumber,
            title: EpisodeParser.episodeName(widget.movie.title),
            sources: [_currentSource],
          ),
        ],
      );
    }

    final seasons = merged.values.toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    for (final season in seasons) {
      season.episodes.sort(
        (a, b) => a.episodeNumber.compareTo(b.episodeNumber),
      );
    }
    return seasons;
  }

  String _getCurrentEpisodeTitle() {
    if (!widget.movie.isSeries) return '';
    final seasons = _pickerSeasons();
    final season = seasons.firstWhere(
      (s) => s.seasonNumber == _currentSeasonNumber,
      orElse: () => seasons.isNotEmpty
          ? seasons.first
          : MovieSeason(seasonNumber: 1, title: '', episodes: []),
    );
    final ep = season.episodes.firstWhere(
      (e) => e.episodeNumber == _currentEpisodeNumber,
      orElse: () => season.episodes.isNotEmpty
          ? seasons.first.episodes.first
          : MovieEpisode(episodeNumber: 1, title: ''),
    );
    return ep.title;
  }

  // ─── Controls ────────────────────────────────────────────────────────────

  void _togglePlay() {
    unawaited(_mpv.togglePlay());
    _resetControlsTimer();
  }

  void _seekTo(double seconds) {
    final target = seconds.clamp(
      0.0,
      _totalSeconds > 0 ? _totalSeconds : seconds,
    );
    setState(() => _currentSeconds = target);
    unawaited(_mpv.seek(target));
    _saveProgress();
    _resetControlsTimer();
  }

  void _skip(double delta) => _seekTo(_currentSeconds + delta);

  void _applyPlayerOrientation(bool fullscreen) {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  void _setMini(bool value) {
    if (_mini == value) return;
    setState(() {
      _mini = value;
      _zoom = 1.0;
      _showControls = true;
    });
    _applyPlayerOrientation(!value);
    _resetControlsTimer();
  }

  Future<void> _exitPlayer() async {
    _saveProgress();
    if (mounted) Navigator.of(context).pop();
  }

  void _toggleFullScreen() {
    setState(() => _isFullScreen = !_isFullScreen);
    _applyPlayerOrientation(_isFullScreen);
  }

  void _resetControlsTimer() {
    _controlsDismissTimer?.cancel();
    if (_showControls && !_isLocked) {
      _controlsDismissTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _mpv.isPlaying) setState(() => _showControls = false);
      });
    }
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _resetControlsTimer();
  }

  void _onDoubleTapLeft() {
    _skip(-10);
    setState(() => _showLeftDoubleTap = true);
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showLeftDoubleTap = false);
    });
  }

  void _onDoubleTapRight() {
    _skip(10);
    setState(() => _showRightDoubleTap = true);
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showRightDoubleTap = false);
    });
  }

  Future<void> _onVerticalDragUpdate(DragUpdateDetails details) async {
    if (_isLocked) return;
    final isRightSide = _brightnessGesture;
    final delta = -(details.primaryDelta ?? 0) / 250;
    final first = _firstVerticalUpdate;
    _firstVerticalUpdate = false;
    final systemLevel = await _playbackControls.adjust(
      brightness: isRightSide,
      delta: delta,
      first: first,
    );
    if (!mounted || _isLocked) return;
    if (isRightSide) {
      setState(() {
        _brightness = systemLevel ?? (_brightness + delta).clamp(0.05, 1.0);
        _showBrightnessHud = true;
        _showVolumeHud = false;
        _showSeekHud = false;
      });
    } else {
      setState(() {
        if (systemLevel == null) _volume = (_volume + delta).clamp(0.0, 1.0);
        _volumeHud = systemLevel ?? _volume;
        _showVolumeHud = true;
        _showBrightnessHud = false;
        _showSeekHud = false;
      });
      if (systemLevel == null) unawaited(_mpv.setVolume(_volume));
    }
    _hudDismissTimer?.cancel();
    _hudDismissTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _showBrightnessHud = false;
          _showVolumeHud = false;
        });
      }
    });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_isLocked) return;
    setState(() {
      _seekDeltaSeconds += (details.primaryDelta ?? 0) * 1.5;
      _showSeekHud = true;
      _showBrightnessHud = false;
      _showVolumeHud = false;
    });
    _hudDismissTimer?.cancel();
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_isLocked) return;
    _skip(_seekDeltaSeconds);
    _seekDeltaSeconds = 0.0;
    _hudDismissTimer?.cancel();
    _hudDismissTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) setState(() => _showSeekHud = false);
    });
  }

  String _formatTime(double sec) {
    final s = sec.toInt();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sc = s % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${sc.toString().padLeft(2, '0')}';
    }
    return '$m:${sc.toString().padLeft(2, '0')}';
  }

  // ─── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final p = context.palette;
    // Keep native subtitle styling derived from the active app theme instead
    // of a fixed black colour. The four-byte Flutter colour format matches
    // mpv's #AARRGGBB option format.
    final subtitleBack =
        '#${p.videoScrim.withValues(alpha: .5).toARGB32().toRadixString(16).padLeft(8, '0')}';
    if (_lastSubtitleBackColor != subtitleBack) {
      _lastSubtitleBackColor = subtitleBack;
      unawaited(_mpv.setOption('sub-back-color', subtitleBack));
    }
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_mini) {
          _exitPlayer();
        } else {
          _setMini(true);
        }
      },
      child: Scaffold(
        backgroundColor: p.background,
        body: Stack(
          children: [
            if (_mini) Positioned.fill(child: Container(color: p.background)),
            _buildVideoLayer(size),
            if (!_mini)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleControls,
                  onVerticalDragStart: (details) {
                    _brightnessGesture =
                        details.localPosition.dx >= size.width / 2;
                    _firstVerticalUpdate = true;
                  },
                  onVerticalDragUpdate: _onVerticalDragUpdate,
                  onHorizontalDragUpdate: _onHorizontalDragUpdate,
                  onHorizontalDragEnd: _onHorizontalDragEnd,
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTap: _onDoubleTapLeft,
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                      const SizedBox(width: 60),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTap: _onDoubleTapRight,
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_showLeftDoubleTap)
              Positioned(
                left: 40,
                top: size.height / 2 - 40,
                child: _buildDoubleTapIndicator(
                  Icons.replay_10_rounded,
                  '-10s',
                ),
              ),
            if (_showRightDoubleTap)
              Positioned(
                right: 40,
                top: size.height / 2 - 40,
                child: _buildDoubleTapIndicator(
                  Icons.forward_10_rounded,
                  '+10s',
                ),
              ),
            if (_showBrightnessHud)
              Center(
                child: _buildHudCard(
                  icon: Icons.brightness_6_rounded,
                  label: 'Brightness',
                  value: _brightness,
                  percentage: '${(_brightness * 100).toInt()}%',
                ),
              ),
            if (_showVolumeHud)
              Center(
                child: _buildHudCard(
                  icon: _volumeHud == 0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  label: 'Volume',
                  value: _volumeHud,
                  percentage: '${(_volumeHud * 100).toInt()}%',
                ),
              ),
            if (_showSeekHud)
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: p.videoScrimAt(0.75),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: p.onVideoScrim.withValues(alpha: 0.15),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _seekDeltaSeconds >= 0
                                ? Icons.fast_forward_rounded
                                : Icons.fast_rewind_rounded,
                            color: p.onVideoScrim,
                            size: 28,
                          ),
                          const SizedBox(width: 10),
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text:
                                      '${_seekDeltaSeconds >= 0 ? '+' : ''}${_seekDeltaSeconds.toInt()}s ',
                                  style: TextStyle(
                                    color: p.onVideoScrim,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                TextSpan(
                                  text:
                                      '(${_formatTime((_currentSeconds + _seekDeltaSeconds).clamp(0.0, _totalSeconds > 0 ? _totalSeconds : double.infinity))})',
                                  style: TextStyle(
                                    color: p.onVideoScrim.withValues(
                                      alpha: 0.85,
                                    ),
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (!_mini && _showControls) ...[
              Positioned(left: 0, right: 0, top: 0, child: _buildTopBar()),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBottomBar(),
              ),
            ],
            if (_isLocked && !_mini)
              Positioned(
                left: 20,
                top: 20,
                child: IconButton(
                  onPressed: () {
                    setState(() => _isLocked = false);
                    _resetControlsTimer();
                  },
                  icon: Icon(
                    Icons.lock_rounded,
                    color: p.onVideoScrim,
                    size: 30,
                  ),
                ),
              ),
            if (_mini) _buildMiniPlayer(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoLayer(Size size) {
    final p = context.palette;
    final miniBottom = MediaQuery.paddingOf(context).bottom + 116.0;
    return Positioned(
      left: _mini ? null : 0,
      top: _mini ? null : 0,
      right: _mini ? 14.0 : 0,
      bottom: _mini ? miniBottom : 0,
      width: _mini ? 168.0 : null,
      height: _mini ? 96.0 : null,
      child: GestureDetector(
        onTap: _mini ? () => _setMini(false) : null,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: p.videoScrim,
            borderRadius: BorderRadius.circular(_mini ? 14 : 0),
            border: _mini
                ? Border.all(color: p.tint(p.onVideoScrim, 0.22))
                : null,
          ),
          child: ClipRect(
            child: GestureDetector(
              onScaleStart: _mini ? null : (_) => _zoomStart = _zoom,
              onScaleUpdate: _mini
                  ? null
                  : (details) {
                      final next = (_zoomStart * details.scale).clamp(1.0, 3.0);
                      if ((next - _zoom).abs() > 0.001) {
                        setState(() => _zoom = next);
                        unawaited(_mpv.setZoom(_zoom));
                      }
                    },
              // Zoom is applied natively by mpv (video-zoom) so the video can
              // fill the surface without Flutter letterboxing it. Scaling the
              // whole Flutter layer here as well would double-zoom and crop
              // the HUD controls.
              child: Transform.scale(
                scale: 1.0,
                alignment: Alignment.center,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MpvVideoView(controller: _mpv),
                    if (!_mini) _buildVideoOverlay(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoOverlay() {
    final p = context.palette;
    if (_videoErrorMessage != null) {
      return Container(
        color: p.videoScrim,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, color: p.error, size: 38),
                const SizedBox(height: 10),
                Text(
                  _videoErrorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.onVideoScrim, fontSize: 12.5),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        if (widget.isLiveTv) {
                          unawaited(_connectLiveTv(resetFailures: true));
                        } else {
                          unawaited(
                            _autoAnalyzeAndConnect(resetFailures: true),
                          );
                        }
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Retry / Find server'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _showServerPicker,
                      icon: const Icon(Icons.dns_rounded, size: 16),
                      label: const Text('Choose server'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: p.onVideoScrim,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_isAnalyzingServers) {
      return Container(
        color: p.videoScrimAt(0.76),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: p.surface.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: p.videoAccent, strokeWidth: 3),
                const SizedBox(height: 10),
                Text(
                  'Auto Server Analyzer',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _analyzingStatus,
                  style: TextStyle(color: p.textSecondary, fontSize: 11),
                ),
                if (_totalCandidateServers > 0) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 220,
                    child: LinearProgressIndicator(
                      value: (_analyzedServerIndex / _totalCandidateServers)
                          .clamp(0.0, 1.0),
                      color: p.primary,
                      backgroundColor: p.trackBg,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    if (_mpv.isBuffering) {
      return Center(
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: p.videoScrimAt(0.65),
            shape: BoxShape.circle,
          ),
          child: CircularProgressIndicator(
            color: p.videoAccent,
            strokeWidth: 3.5,
          ),
        ),
      );
    }
    if (!_mpv.isPlaying) {
      return Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: p.videoScrimAt(0.6),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.play_arrow_rounded,
            color: p.onVideoScrim,
            size: 48,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildMiniPlayer() {
    final p = context.palette;
    final bottom = MediaQuery.paddingOf(context).bottom + 18.0;
    final progress = _totalSeconds > 0
        ? (_currentSeconds / _totalSeconds).clamp(0.0, 1.0)
        : 0.0;
    final episodeLabel = widget.movie.isSeries
        ? 'S$_currentSeasonNumber E$_currentEpisodeNumber • '
        : '';
    return Positioned(
      left: 12,
      right: 12,
      bottom: bottom,
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0).abs() > 350) _exitPlayer();
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 6, 8),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.tint(p.border, 0.8)),
            boxShadow: [
              BoxShadow(
                color: p.videoScrimAt(0.34),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 32,
                    decoration: BoxDecoration(
                      color: p.primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.movie.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '$episodeLabel${_formatTime(_currentSeconds)} / ${_formatTime(_totalSeconds)}',
                          style: TextStyle(
                            color: p.textSecondary,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: _mpv.isPlaying ? 'Pause' : 'Play',
                    icon: Icon(
                      _mpv.isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      color: p.primary,
                      size: 30,
                    ),
                    onPressed: _togglePlay,
                  ),
                  IconButton(
                    tooltip: 'Back to full screen',
                    icon: Icon(
                      Icons.open_in_full_rounded,
                      color: p.primary,
                      size: 22,
                    ),
                    onPressed: () => _setMini(false),
                  ),
                  IconButton(
                    tooltip: 'Close player',
                    icon: Icon(
                      Icons.close_rounded,
                      color: p.textSecondary,
                      size: 22,
                    ),
                    onPressed: _exitPlayer,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: p.trackBg,
                  color: p.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [p.videoScrimAt(0.85), Colors.transparent],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              onPressed: () => _setMini(true),
              icon: Icon(
                Icons.arrow_back_rounded,
                color: p.onVideoScrim,
                size: 26,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.movie.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.onVideoScrim,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  if (widget.movie.isSeries)
                    Text(
                      'Season $_currentSeasonNumber • Episode $_currentEpisodeNumber: '
                      '${_getCurrentEpisodeTitle()}',
                      style: TextStyle(
                        color: p.tint(p.onVideoScrim, 0.7),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!widget.isLiveTv && !widget.trailerOnly)
                      _buildHeaderAction(
                        icon: Icons.dns_rounded,
                        label:
                            'Server${_lastProviderReports.isNotEmpty ? ' (${_lastProviderReports.length})' : ''}',
                        onTap: _showServerPicker,
                      ),
                    if (!widget.trailerOnly)
                      _buildHeaderAction(
                        icon: Icons.hd_rounded,
                        label: _currentQuality,
                        onTap: _showQualityPicker,
                      ),
                    _buildHeaderAction(
                      icon: Icons.audiotrack_rounded,
                      label: 'Tracks',
                      onTap: _showTrackPicker,
                    ),
                    if (widget.movie.isSeries && !widget.trailerOnly)
                      _buildHeaderAction(
                        icon: Icons.video_library_rounded,
                        label: 'Episodes',
                        onTap: _showSeasonEpisodeDrawer,
                      ),
                    _buildHeaderAction(
                      icon: Icons.tune_rounded,
                      label: 'Settings',
                      onTap: _showSettingsPanel,
                    ),
                    IconButton(
                      tooltip: 'Lock Screen',
                      onPressed: () {
                        setState(() {
                          _isLocked = true;
                          _showControls = false;
                        });
                      },
                      icon: Icon(
                        Icons.lock_open_rounded,
                        color: p.onVideoScrim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: p.onVideoScrim.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: p.onVideoScrim, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: p.onVideoScrim,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.transparent, p.videoScrimAt(0.9)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  _formatTime(_currentSeconds),
                  style: TextStyle(color: p.onVideoScrim, fontSize: 12),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3.5,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      activeTrackColor: p.videoAccent,
                      inactiveTrackColor: p.tint(p.onVideoScrim, 0.24),
                      thumbColor: p.videoAccent,
                    ),
                    child: Slider(
                      value: _currentSeconds.clamp(
                        0.0,
                        _totalSeconds > 0 ? _totalSeconds : 1,
                      ),
                      min: 0,
                      max: _totalSeconds > 0 ? _totalSeconds : 1,
                      onChanged: widget.isLiveTv ? null : _seekTo,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.isLiveTv ? 'LIVE' : _formatTime(_totalSeconds),
                  style: TextStyle(color: p.onVideoScrim, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      setState(() => _zoom = 1.0);
                      unawaited(_mpv.setZoom(1.0));
                    },
                    icon: Icon(
                      Icons.crop_free_rounded,
                      color: p.onVideoScrim,
                      size: 19,
                    ),
                    label: Text(
                      'Fit',
                      style: TextStyle(
                        color: p.onVideoScrim,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.replay_10_rounded,
                          color: p.onVideoScrim,
                          size: 28,
                        ),
                        onPressed: () => _skip(-10),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        decoration: BoxDecoration(
                          color: p.videoAccent,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: Icon(
                            _mpv.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: p.onPrimary,
                            size: 32,
                          ),
                          onPressed: _togglePlay,
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: Icon(
                          Icons.forward_10_rounded,
                          color: p.onVideoScrim,
                          size: 28,
                        ),
                        onPressed: () => _skip(10),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.movie.isSeries && !widget.trailerOnly)
                        TextButton.icon(
                          onPressed: _showSeasonEpisodeDrawer,
                          icon: Icon(
                            Icons.video_library_outlined,
                            color: p.onVideoScrim,
                            size: 15,
                          ),
                          label: Text(
                            'S$_currentSeasonNumber E$_currentEpisodeNumber',
                            style: TextStyle(
                              color: p.onVideoScrim,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      TextButton(
                        onPressed: _showSpeedPicker,
                        child: Text(
                          '${_mpv.speed}x',
                          style: TextStyle(
                            color: p.onVideoScrim,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (!widget.trailerOnly)
                        IconButton(
                          tooltip: 'Download',
                          icon: Icon(
                            Icons.download_rounded,
                            color: p.onVideoScrim,
                          ),
                          onPressed: _downloadCurrent,
                        ),
                      IconButton(
                        tooltip: _isFullScreen
                            ? 'Exit Fullscreen'
                            : 'Fullscreen',
                        icon: Icon(
                          _isFullScreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          color: p.onVideoScrim,
                          size: 26,
                        ),
                        onPressed: _toggleFullScreen,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDoubleTapIndicator(IconData icon, String label) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.videoScrimAt(0.7),
        shape: BoxShape.circle,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: p.onVideoScrim, size: 32),
          Text(
            label,
            style: TextStyle(
              color: p.onVideoScrim,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHudCard({
    required IconData icon,
    required String label,
    required double value,
    required String percentage,
  }) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: 170,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: p.videoScrimAt(0.75),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: p.onVideoScrim, size: 34),
              const SizedBox(height: 10),
              Text(
                label,
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: value,
                backgroundColor: p.tint(p.onVideoScrim, 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(p.videoAccent),
                minHeight: 5,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Text(
                percentage,
                style: TextStyle(
                  color: p.onVideoScrim,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Pickers ─────────────────────────────────────────────────────────────

  void _showQualityPicker() {
    final sources = {
      for (final source in [
        _currentSource,
        ...widget.movie.sources,
        ..._lastProviderReports.map((report) => report.source),
      ])
        if (source.streamUrl.isNotEmpty || source.downloadUrl.isNotEmpty)
          (
            source.resolution,
            source.format,
            source.serverName,
            source.streamUrl,
            source.downloadUrl,
          ): source,
    }.values.toList();
    final p = context.palette;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: p.surface,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * .65,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              ListTile(
                title: Text(
                  'Available quality',
                  style: TextStyle(color: p.textPrimary),
                ),
              ),
              for (final source in sources)
                ListTile(
                  leading: Icon(Icons.hd_outlined, color: p.primary),
                  title: Text(
                    source.resolution,
                    style: TextStyle(color: p.textPrimary),
                  ),
                  subtitle: Text(
                    '${source.serverName} · ${source.format.toUpperCase()}',
                    style: TextStyle(color: p.textSecondary),
                  ),
                  trailing:
                      source.streamUrl == _currentSource.streamUrl &&
                          source.downloadUrl == _currentSource.downloadUrl
                      ? Icon(Icons.check_rounded, color: p.primary)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    _failedSourceKeys.clear();
                    unawaited(_loadCurrentSource(source: source));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpeedPicker() {
    final p = context.palette;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Playback speed',
                style: TextStyle(
                  color: p.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final speed in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0])
                  ChoiceChip(
                    label: Text('${speed}x'),
                    selected: (_mpv.speed - speed).abs() < 0.01,
                    onSelected: (_) {
                      Navigator.pop(ctx);
                      unawaited(_mpv.setSpeed(speed));
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showTrackPicker() {
    final p = context.palette;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: p.surface,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * .7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: [
              if (_mpv.audioTracks.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Audio',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                for (final track in _mpv.audioTracks)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      track.selected
                          ? Icons.check_circle_rounded
                          : Icons.audiotrack_rounded,
                      color: track.selected ? p.primary : p.textSecondary,
                    ),
                    title: Text(
                      track.label,
                      style: TextStyle(color: p.textPrimary),
                    ),
                    subtitle: track.language.isNotEmpty
                        ? Text(
                            track.language,
                            style: TextStyle(color: p.textSecondary),
                          )
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() => _currentAudioTrack = track.label);
                      unawaited(_mpv.selectTrack('audio', track.id));
                    },
                  ),
              ],
              if (_mpv.subtitleTracks.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Subtitles',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ListTile(
                  dense: true,
                  title: Text('Off', style: TextStyle(color: p.textPrimary)),
                  trailing: !_mpv.subtitleTracks.any((t) => t.selected)
                      ? Icon(Icons.check_rounded, color: p.primary)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    unawaited(_mpv.selectTrack('subtitle', -1));
                  },
                ),
                for (final track in _mpv.subtitleTracks)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      track.selected
                          ? Icons.check_circle_rounded
                          : Icons.subtitles_rounded,
                      color: track.selected ? p.primary : p.textSecondary,
                    ),
                    title: Text(
                      track.label,
                      style: TextStyle(color: p.textPrimary),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      unawaited(_mpv.selectTrack('subtitle', track.id));
                    },
                  ),
              ],
              if (_mpv.audioTracks.isEmpty && _mpv.subtitleTracks.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'No separate tracks in this stream. libmpv is using the embedded tracks.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.textSecondary, fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSettingsPanel() {
    final p = context.palette;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: p.surface,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Player settings',
                style: TextStyle(
                  color: p.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Powered by libmpv · mpvExtended engine',
                style: TextStyle(color: p.textSecondary, fontSize: 11),
              ),
              const SizedBox(height: 14),
              ListTile(
                leading: Icon(Icons.speed_rounded, color: p.primary),
                title: Text('Speed', style: TextStyle(color: p.textPrimary)),
                subtitle: Text(
                  '${_mpv.speed}x',
                  style: TextStyle(color: p.textSecondary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSpeedPicker();
                },
              ),
              ListTile(
                leading: Icon(Icons.graphic_eq_rounded, color: p.primary),
                title: Text(
                  'Equalizer / volume',
                  style: TextStyle(color: p.textPrimary),
                ),
                subtitle: Slider(
                  value: _mpv.volume.clamp(0.0, 1.5),
                  max: 1.5,
                  onChanged: (v) => unawaited(_mpv.setVolume(v)),
                ),
              ),
              ListTile(
                leading: Icon(Icons.subtitles_rounded, color: p.primary),
                title: Text(
                  'Subtitle delay',
                  style: TextStyle(color: p.textPrimary),
                ),
                subtitle: Text(
                  'Slightly shift subtitles if they are out of sync',
                  style: TextStyle(color: p.textSecondary, fontSize: 11),
                ),
                onTap: () => _showDelayPicker(ctx, audio: false),
              ),
              ListTile(
                leading: Icon(Icons.audiotrack_rounded, color: p.primary),
                title: Text(
                  'Audio delay',
                  style: TextStyle(color: p.textPrimary),
                ),
                subtitle: Text(
                  'Shift audio relative to video',
                  style: TextStyle(color: p.textSecondary, fontSize: 11),
                ),
                onTap: () => _showDelayPicker(ctx, audio: true),
              ),
              ListTile(
                leading: Icon(Icons.fullscreen_rounded, color: p.primary),
                title: Text('Zoom', style: TextStyle(color: p.textPrimary)),
                subtitle: Slider(
                  value: _zoom,
                  min: 1.0,
                  max: 3.0,
                  onChanged: (v) {
                    setState(() => _zoom = v);
                    unawaited(_mpv.setZoom(v));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDelayPicker(BuildContext ctx, {required bool audio}) {
    final p = context.palette;
    final property = audio ? 'audio-delay' : 'sub-delay';
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: p.surface,
        title: Text(
          audio ? 'Audio delay (seconds)' : 'Subtitle delay (seconds)',
          style: TextStyle(color: p.textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final delay in [-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0])
              ListTile(
                dense: true,
                title: Text(
                  delay == 0 ? 'Default' : '${delay > 0 ? '+' : ''}$delay s',
                  style: TextStyle(color: p.textPrimary),
                ),
                onTap: () {
                  Navigator.pop(dialogCtx);
                  unawaited(_mpv.setOption(property, delay.toString()));
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showSeasonEpisodeDrawer() {
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (drawerContext, setDrawerState) {
            final seasons = _pickerSeasons();
            final activeSeason = seasons.firstWhere(
              (s) => s.seasonNumber == _currentSeasonNumber,
              orElse: () => seasons.isNotEmpty
                  ? seasons.first
                  : MovieSeason(
                      seasonNumber: 1,
                      title: 'Season 1',
                      episodes: [],
                    ),
            );
            return Container(
              height: MediaQuery.of(drawerContext).size.height * 0.8,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${widget.movie.title} • Episodes',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: p.textSecondary),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: seasons.map((s) {
                        final isSel = s.seasonNumber == _currentSeasonNumber;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(s.title),
                            selected: isSel,
                            onSelected: (_) {
                              setDrawerState(
                                () => _currentSeasonNumber = s.seasonNumber,
                              );
                              setState(() {});
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: activeSeason.episodes.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.video_library_outlined,
                                  size: 38,
                                  color: p.textSecondary,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'No episodes available',
                                  style: TextStyle(
                                    color: p.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: activeSeason.episodes.length,
                            itemBuilder: (context, idx) {
                              final ep = activeSeason.episodes[idx];
                              final isSelected =
                                  ep.episodeNumber == _currentEpisodeNumber;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 9),
                                child: Material(
                                  color: isSelected
                                      ? p.selectedBg
                                      : p.tint(p.border, 0.18),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: BorderSide(
                                      color: isSelected
                                          ? p.primary
                                          : p.tint(p.border, 0.4),
                                    ),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: ListTile(
                                    leading: Container(
                                      width: 56,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        image: ep.thumbnailUrl.isNotEmpty
                                            ? DecorationImage(
                                                image: NetworkImage(
                                                  ep.thumbnailUrl,
                                                ),
                                                fit: BoxFit.cover,
                                              )
                                            : null,
                                        color: p.trackBg,
                                      ),
                                      alignment: Alignment.center,
                                      child: ep.thumbnailUrl.isEmpty
                                          ? Text(
                                              '${ep.episodeNumber}',
                                              style: TextStyle(
                                                color: p.textSecondary,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            )
                                          : null,
                                    ),
                                    title: Text(
                                      'E${ep.episodeNumber.toString().padLeft(2, '0')}'
                                      '${ep.title.isNotEmpty ? ' · ${ep.title}' : ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.textPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                    subtitle: Text(
                                      ep.synopsis.isNotEmpty
                                          ? ep.synopsis
                                          : (widget.downloadedEpisodes.isEmpty
                                                ? 'Online stream'
                                                : 'Downloaded episode'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: p.textSecondary,
                                      ),
                                    ),
                                    trailing: Icon(
                                      isSelected
                                          ? Icons.play_circle_fill_rounded
                                          : Icons.chevron_right_rounded,
                                      color: isSelected
                                          ? p.primary
                                          : p.textSecondary,
                                    ),
                                    onTap: () async {
                                      _saveProgress();
                                      if (!mounted || !ctx.mounted) return;
                                      if (ep.sources.isEmpty) {
                                        final providerEpisode =
                                            _providerEpisodes[(
                                              activeSeason.seasonNumber,
                                              ep.episodeNumber,
                                            )];
                                        if (providerEpisode != null) {
                                          final formats =
                                              await ProviderEngineService
                                                  .instance
                                                  .episodeDownloadFormats(
                                                    widget.movie,
                                                    providerEpisode,
                                                  );
                                          if (!mounted ||
                                              !ctx.mounted ||
                                              formats.isEmpty) {
                                            return;
                                          }
                                          setState(
                                            () =>
                                                _currentSource = formats.first,
                                          );
                                        }
                                      }
                                      DownloadTask? task;
                                      for (final t
                                          in widget.downloadedEpisodes) {
                                        final n =
                                            EpisodeParser.episode(t.title) ??
                                            EpisodeParser.episode(
                                              t.savePath ?? '',
                                            );
                                        final s =
                                            EpisodeParser.season(
                                              t.seriesSeason ?? '',
                                            ) ??
                                            EpisodeParser.season(t.title) ??
                                            EpisodeParser.season(
                                              t.savePath ?? '',
                                            ) ??
                                            1;
                                        if (n == ep.episodeNumber &&
                                            s == activeSeason.seasonNumber) {
                                          task = t;
                                          break;
                                        }
                                      }
                                      final history = task == null
                                          ? null
                                          : WatchHistoryService.instance
                                                .getProgress(task.id);
                                      setState(() {
                                        _currentSeasonNumber =
                                            activeSeason.seasonNumber;
                                        _currentEpisodeNumber =
                                            ep.episodeNumber;
                                        _currentSeconds =
                                            history?.positionSeconds ?? 0;
                                        _failedSourceKeys.clear();
                                        if (ep.sources.isNotEmpty) {
                                          _currentSource = ep.sources.first;
                                        }
                                      });
                                      Navigator.pop(ctx);
                                      unawaited(
                                        _loadCurrentSource(
                                          position: _currentSeconds,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showServerPicker() {
    final reports = _lastProviderReports.isNotEmpty
        ? _lastProviderReports
        : widget.movie.sources
              .map(
                (s) => ProviderStreamReport(
                  source: s,
                  reachable: true,
                  validStream: false,
                  latencyMs: 0,
                  statusText: 'Untested',
                ),
              )
              .toList();
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      backgroundColor: p.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * .8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Row(
                  children: [
                    Icon(Icons.hub_rounded, color: p.success),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Providers / Servers (${reports.length})',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Re-scan & test all providers',
                      icon: Icon(Icons.refresh_rounded, color: p.info),
                      onPressed: () {
                        Navigator.pop(ctx);
                        unawaited(_autoAnalyzeAndConnect(resetFailures: true));
                      },
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Green = verified • Grey = untested • Red = known dead',
                  style: TextStyle(color: p.textSecondary, fontSize: 11),
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemCount: reports.length,
                  itemBuilder: (context, index) {
                    final report = reports[index];
                    final source = report.source;
                    final isSelected =
                        StreamFallbackService.sourceKey(source) ==
                        StreamFallbackService.sourceKey(_currentSource);
                    final isDead =
                        report.reachable && !report.validStream ||
                        _failedSourceKeys.contains(
                          StreamFallbackService.sourceKey(source),
                        );
                    final healthColor = report.validStream
                        ? p.success
                        : (isDead ? p.error : p.textSecondary);
                    return Material(
                      color: isSelected
                          ? p.tint(p.success, 0.18)
                          : p.tint(p.card, 0.05),
                      borderRadius: BorderRadius.circular(12),
                      child: ListTile(
                        leading: Icon(
                          source.isFastBDIX
                              ? Icons.flash_on_rounded
                              : Icons.dns_rounded,
                          color: source.isFastBDIX ? p.info : healthColor,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                source.serverName,
                                style: TextStyle(
                                  color: isSelected ? p.success : p.textPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            if (report.validStream)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: p.tint(p.success, 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${report.latencyMs}ms',
                                  style: TextStyle(
                                    color: p.success,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          '${source.providerName.isNotEmpty ? "${source.providerName} • " : ""}'
                          '${source.resolution} • ${source.fileSize}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDead
                                ? p.tint(p.error, 0.8)
                                : p.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(Icons.check_circle_rounded, color: p.success)
                            : null,
                        onTap: () {
                          _failedSourceKeys.remove(
                            StreamFallbackService.sourceKey(source),
                          );
                          setState(() {
                            _currentSource = source;
                            _currentQuality = source.resolution;
                          });
                          Navigator.pop(ctx);
                          unawaited(_loadCurrentSource());
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Switched to ${source.serverName}',
                                ),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _downloadCurrent() async {
    final customTitle = widget.movie.isSeries
        ? '${widget.movie.title} - S$_currentSeasonNumber E$_currentEpisodeNumber'
        : widget.movie.title;
    final hasPerm = await PermissionService.instance.hasStoragePermission();
    if (!hasPerm) {
      final granted = await PermissionService.instance
          .requestStoragePermission();
      if (!granted) {
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Storage permission required to download.'),
            ),
          );
        }
        return;
      }
    }
    await DownloadManager.instance.startMovieDownload(
      movie: widget.movie,
      source: _currentSource,
      customTitle: customTitle,
      seasonNumber: widget.movie.isSeries ? _currentSeasonNumber : null,
    );
  }
}
