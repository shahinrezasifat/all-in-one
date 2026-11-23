import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/movie_model.dart';
import '../models/video_item.dart';
import '../services/download_manager.dart';
import '../services/extractor_service.dart';
import '../services/permission_service.dart';
import '../services/playback_controls.dart';
import '../services/player_service.dart';
import '../services/preference_service.dart';
import '../services/provider_engine/provider_models.dart';
import '../services/stream_fallback_service.dart';
import '../services/watch_history_service.dart';
import '../theme/app_palette.dart';
import '../widgets/remote_image.dart';
import 'audio_player_screen.dart';

class MoviePlayerScreen extends StatefulWidget {
  final MovieItem movie;
  final MovieSource initialSource;
  final int initialSeason;
  final int initialEpisode;
  final double initialPositionSeconds;

  /// When true the player shows ONLY the movie's YouTube trailer (on-demand,
  /// opened from the "Trailer" button). It never touches the real provider
  /// streams and progress is not saved. The MOVIE itself never auto-plays a
  /// trailer — this path is entered exclusively by explicit user action.
  final bool trailerOnly;

  /// Live IPTV channel mode. Uses the SAME full-featured player as movies but
  /// skips the movie-only multi-provider scan, stays in portrait (no forced
  /// landscape), treats the stream as endless (no seek/progress), and tries
  /// every supplied [liveSources] link until one actually plays.
  final bool isLiveTv;
  final List<MovieSource> liveSources;

  MoviePlayerScreen({
    super.key,
    required this.movie,
    required this.initialSource,
    this.initialSeason = 1,
    this.initialEpisode = 1,
    this.initialPositionSeconds = 0.0,
    this.trailerOnly = false,
    this.isLiveTv = false,
    this.liveSources = const [],
  });

  @override
  State<MoviePlayerScreen> createState() => _MoviePlayerScreenState();
}

class _MoviePlayerScreenState extends State<MoviePlayerScreen>
    with TickerProviderStateMixin {
  late MovieSource _currentSource;
  late int _currentSeasonNumber;
  late int _currentEpisodeNumber;
  late String _currentAudioTrack;
  late String _currentSubtitle;
  late String _currentQuality;

  bool _isPlaying = true;
  double _currentSeconds = 0.0;
  double _totalSeconds = 7200.0; // 2h default
  double _playbackSpeed = 1.0;

  // Real Video Player Engine
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isBuffering = true;
  bool _isFullScreen = true;
  String? _videoErrorMessage;

  // Automatic Multi-Provider Fallback Engine
  bool _isAnalyzingServers = false;
  String _analyzingStatus = '';
  int _analyzedServerIndex = 0;
  int _totalCandidateServers = 0;
  bool _analysisInFlight = false;
  bool _usingAutomaticSource = false;
  int _sourceRequest = 0;
  final Set<String> _failedSourceKeys = {};
  List<ProviderStreamReport> _lastProviderReports = [];

  // Gesture Controls (MX Player Style)
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

  // Controls Visibility
  bool _showControls = true;
  Timer? _controlsDismissTimer;
  bool _isLocked = false;
  String _aspectRatioMode = 'Fit'; // 'Fit', 'Fill', 'Zoom', '16:9'

  // Double tap skip animations
  bool _showLeftDoubleTap = false;
  bool _showRightDoubleTap = false;

  @override
  void initState() {
    super.initState();
    _currentSource = widget.initialSource;
    _currentSeasonNumber = widget.initialSeason;
    _currentEpisodeNumber = widget.initialEpisode;
    _currentSeconds = widget.initialPositionSeconds;
    _currentAudioTrack = widget.movie.audioTracks.isNotEmpty
        ? widget.movie.audioTracks.first
        : 'Bengali (Original)';
    _currentSubtitle = widget.movie.subtitles.isNotEmpty
        ? widget.movie.subtitles.first
        : 'English';
    _currentQuality = _currentSource.resolution;

    // Estimate duration from movie item
    _totalSeconds = _parseDurationSeconds(widget.movie.duration);

    // Feed the recommendation engine: opening the player on the real feature
    // (not a trailer) counts as a watch, teaching category/language/quality.
    if (!widget.trailerOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        PreferenceService.instance.logVideoWatch(
          widget.movie,
          audioTrackLabel: _currentAudioTrack,
          quality: _currentQuality,
        );
      });
    }

    // Movies force landscape for cinema view. Live IPTV stays in portrait (the
    // user clearly chose portrait) and simply follows the device rotation.
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (widget.isLiveTv) {
        // IPTV channels are watched in portrait — do NOT rotate to landscape.
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      } else {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    }

    if (widget.trailerOnly) {
      _playTrailer();
    } else if (widget.isLiveTv) {
      unawaited(_connectLiveTv());
    } else {
      unawaited(_initVideoPlayer());
    }
    _resetControlsTimer();
  }

  /// On-demand trailer: resolve the movie's YouTube trailer stream and play it
  /// ONLY when the user explicitly tapped "Trailer". Never invoked on movie
  /// auto-play.
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
      // A retry (or a second trailer request) must not leak the old native
      // player instance.
      _videoController?.removeListener(_videoListener);
      await _videoController?.dispose();
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(liveUrl),
        httpHeaders: StreamFallbackService.streamHeadersFor(liveUrl),
      );
      _videoController = controller;
      await controller.initialize().timeout(Duration(seconds: 15));
      if (!mounted) return;
      if (controller.value.isInitialized && !controller.value.hasError) {
        await controller.setVolume(_volume);
        controller.addListener(_videoListener);
        setState(() {
          _isVideoInitialized = true;
          _isBuffering = false;
          _isAnalyzingServers = false;
          _analyzingStatus = '▶ Trailer';
          final dur = controller.value.duration.inSeconds.toDouble();
          if (dur > 0) _totalSeconds = dur;
        });
        await controller.play();
      } else {
        throw Exception('trailer not playable');
      }
    } catch (e) {
      debugPrint('Trailer load failed: $e');
      _videoController?.removeListener(_videoListener);
      await _videoController?.dispose();
      _videoController = null;
      if (!mounted) return;
      setState(() {
        _isAnalyzingServers = false;
        _isBuffering = false;
        _videoErrorMessage =
            'Could not load the trailer for "${widget.movie.title}".';
      });
    }
  }

  @override
  void dispose() {
    unawaited(_playbackControls.restoreBrightness());
    unawaited(_playbackControls.keepScreenOn(false));
    _videoController?.removeListener(_videoListener);
    _videoController?.dispose();
    _hudDismissTimer?.cancel();
    _controlsDismissTimer?.cancel();

    // Save final progress
    _saveProgress();

    // Restore UI orientation (Mobile only)
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    super.dispose();
  }

  /// Browser-style base headers plus any provider-supplied headers (Referer,
  /// User-Agent, cookies) required by the specific stream — real repo CDNs
  /// (pixeldrain/hubcloud/etc.) reject raw requests without them.
  Map<String, String> _headersFor(MovieSource source, String url) {
    final h = StreamFallbackService.streamHeadersFor(url);
    if (source.headers.isNotEmpty) h.addAll(source.headers);
    return h;
  }

  /// Live IPTV connection. Unlike movies, a channel is a single continuous
  /// stream — there is no multi-provider scan and no seek/progress. We try every
  /// resolved link (a channel often ships several mirrors) with browser-like
  /// headers and the correct HLS/DASH format hint until one actually plays.
  Future<void> _connectLiveTv({bool resetFailures = false}) async {
    if (_analysisInFlight) return;
    _analysisInFlight = true;
    if (resetFailures) _failedSourceKeys.clear();

    final candidates = <MovieSource>[
      widget.initialSource,
      ...widget.liveSources,
    ];
    final unique = <String, MovieSource>{};
    for (final s in candidates) {
      final url = s.streamUrl.isNotEmpty ? s.streamUrl : s.downloadUrl;
      if (url.trim().isNotEmpty) unique.putIfAbsent(url.trim(), () => s);
    }

    setState(() {
      _isAnalyzingServers = true;
      _videoErrorMessage = null;
      _analyzedServerIndex = 0;
      _totalCandidateServers = unique.length;
      _analyzingStatus = unique.isEmpty
          ? 'No stream links found for this channel'
          : 'Connecting to ${unique.length} channel link(s)…';
    });

    final tried = <String>[];
    var connectCount = 0;
    try {
      for (final entry in unique.values) {
        if (!mounted) return;
        final key = StreamFallbackService.sourceKey(entry);
        if (_failedSourceKeys.contains(key)) continue;
        final url = entry.streamUrl.isNotEmpty
            ? entry.streamUrl
            : entry.downloadUrl;
        final uri = Uri.tryParse(url);
        if (uri == null ||
            uri.host.isEmpty ||
            !['http', 'https'].contains(uri.scheme)) {
          _failedSourceKeys.add(key);
          continue;
        }

        setState(() {
          _analyzedServerIndex = ++connectCount;
          _analyzingStatus =
              'Trying ${entry.serverName.isEmpty ? 'channel stream' : entry.serverName}…';
        });

        final old = _videoController;
        _videoController = null;
        old?.removeListener(_videoListener);
        await old?.dispose();

        final fmt = entry.format.toLowerCase();
        final controller = VideoPlayerController.networkUrl(
          uri,
          httpHeaders: _headersFor(entry, url),
          formatHint: fmt == 'm3u8'
              ? VideoFormat.hls
              : fmt == 'mpd'
              ? VideoFormat.dash
              : null,
        );
        _videoController = controller;
        var kept = false;
        try {
          await controller.initialize().timeout(Duration(seconds: 18));
          if (!mounted) return;
          if (!controller.value.isInitialized || controller.value.hasError) {
            throw Exception('stream not playable');
          }
          await controller.setVolume(_volume);
          await controller.setPlaybackSpeed(_playbackSpeed);
          controller.addListener(_videoListener);
          setState(() {
            _isVideoInitialized = true;
            _isBuffering = false;
            _isAnalyzingServers = false;
            _analyzingStatus = '';
            _currentSource = entry;
            _currentQuality = entry.resolution;
            _totalSeconds = 0; // live: no fixed duration
          });
          await controller.play();
          kept = true;
          return;
        } catch (e) {
          tried.add(entry.serverName.isEmpty ? uri.host : entry.serverName);
          debugPrint('Live TV link failed ($url): $e');
          _failedSourceKeys.add(key);
        } finally {
          if (!kept) {
            controller.removeListener(_videoListener);
            await controller.dispose();
            _videoController = null;
          }
        }
      }

      // Every link failed — give an honest, useful message.
      if (!mounted) return;
      final failed = tried.isEmpty
          ? 'No playable stream links'
          : tried.join(', ');
      setState(() {
        _isAnalyzingServers = false;
        _isBuffering = false;
        _isVideoInitialized = false;
        _videoErrorMessage =
            'Could not connect to this channel '
            '($failed).\n\n'
            'Possible causes: this channel link is offline/dead, or this device has no internet. '
            'Tap "Retry" to try again.';
      });
    } finally {
      _analysisInFlight = false;
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

  /// Automatically validates streams across ALL installed providers and
  /// connects to the fastest healthy server, falling forward on failure.
  Future<void> _autoAnalyzeAndConnect({bool resetFailures = false}) async {
    // Guard: never run two analysis passes concurrently (prevents the
    // infinite re-test loop that caused the endless spinner).
    if (_analysisInFlight) return;
    final request = ++_sourceRequest;
    _usingAutomaticSource = true;
    _analysisInFlight = true;
    if (resetFailures) _failedSourceKeys.clear();

    try {
      if (!mounted || request != _sourceRequest) return;
      setState(() {
        _isAnalyzingServers = true;
        _analyzedServerIndex = 0;
        _totalCandidateServers = 0;
        _analyzingStatus = 'Scanning all installed providers...';
        _videoErrorMessage = null;
      });

      // Phase 1: connectivity + stream validity check across every provider
      // offering this title (cached per title, force-rescan on manual retry).
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

      // Build the play queue: ranked candidates, skipping known-dead servers.
      final queue = reports
          .where(
            (r) => !_failedSourceKeys.contains(
              StreamFallbackService.sourceKey(r.source),
            ),
          )
          .toList();
      setState(() {
        _totalCandidateServers = queue.isEmpty ? reports.length : queue.length;
        _analyzingStatus = queue.isEmpty
            ? 'All providers previously failed — retrying...'
            : 'Found ${queue.length} provider server(s) to try. Connecting...';
      });

      // Phase 2: try each provider in ranked order until one actually plays.
      for (int i = 0; i < queue.length; i++) {
        if (!mounted || request != _sourceRequest) return;
        final report = queue[i];
        final candidate = report.source;
        final key = StreamFallbackService.sourceKey(candidate);
        if (_failedSourceKeys.contains(key)) continue;

        setState(() {
          _analyzedServerIndex = i + 1;
          _analyzingStatus =
              'Trying "${candidate.serverName}" (${candidate.providerName.isNotEmpty ? candidate.providerName : 'mirror'})${report.validStream ? ' • ${report.latencyMs}ms' : ' • unverified, testing live...'}';
        });

        final url = candidate.streamUrl.isNotEmpty
            ? candidate.streamUrl
            : candidate.downloadUrl;
        if (url.isEmpty) {
          _failedSourceKeys.add(key);
          continue;
        }

        final oldController = _videoController;
        _videoController = null;
        oldController?.removeListener(_videoListener);
        await oldController?.dispose();
        if (!mounted || request != _sourceRequest) return;

        try {
          final controller = url.startsWith('http')
              ? VideoPlayerController.networkUrl(
                  Uri.parse(url),
                  httpHeaders: _headersFor(candidate, url),
                  formatHint: candidate.format == 'm3u8'
                      ? VideoFormat.hls
                      : null,
                )
              : VideoPlayerController.file(File(url));
          _videoController = controller;

          // Healthy (pre-validated) servers get a generous window; unverified
          // real provider streams (HLS / redirecting CDNs like pixeldrain,
          // hubcloud, AniKoto) still need time to spin up, so give them a fair
          // window before falling forward to the next server.
          final initTimeout = report.validStream
              ? Duration(seconds: 20)
              : Duration(seconds: 16);
          await controller.initialize().timeout(initTimeout);
          if (!mounted || request != _sourceRequest) return;

          if (controller.value.isInitialized && !controller.value.hasError) {
            // Playable server confirmed!
            await controller.setVolume(_volume);
            await controller.setPlaybackSpeed(_playbackSpeed);

            if (_currentSeconds > 0) {
              await controller.seekTo(
                Duration(seconds: _currentSeconds.toInt()),
              );
            }

            controller.addListener(_videoListener);

            setState(() {
              _currentSource = candidate;
              _currentQuality = candidate.resolution;
              _isVideoInitialized = true;
              _isBuffering = false;
              _isAnalyzingServers = false;
              _analyzingStatus = '✓ Connected to "${candidate.serverName}"!';
              final dur = controller.value.duration.inSeconds.toDouble();
              if (dur > 0) {
                _totalSeconds = dur;
              }
            });

            if (_isPlaying) {
              await controller.play();
            }

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        color: context.palette.success,
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Playing via ${candidate.serverName}'
                          '${candidate.providerName.isNotEmpty ? ' (${candidate.providerName})' : ''}',
                          style: TextStyle(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  duration: Duration(seconds: 3),
                  backgroundColor: context.palette.surface,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
            return;
          }
          throw Exception('Player reported an unusable stream');
        } catch (e) {
          if (!mounted || request != _sourceRequest) return;
          debugPrint('Server "${candidate.serverName}" failed: $e');
          _videoController?.removeListener(_videoListener);
          await _videoController?.dispose();
          _videoController = null;

          // On Linux desktop, if native video_player throws, auto-open VLC/System player
          if (Platform.isLinux && url.isNotEmpty) {
            PlayerService.instance.launchSystemPlayer(url);
          }

          // Remember this server as dead so later passes never retry it.
          _failedSourceKeys.add(key);
        }
      }

      // No native playback succeeded from the real provider URLs.
      if (!mounted || request != _sourceRequest) return;

      // There is deliberately NO silent fallback to a YouTube trailer / sample
      // clip here — the user must only ever watch the REAL movie. If none of
      // the provider's actual streams played, report the failure honestly.
      setState(() {
        _isAnalyzingServers = false;
        _isBuffering = false;
        _isVideoInitialized = false;
        _videoErrorMessage =
            'Tested ${_failedSourceKeys.length} server(s) for "${widget.movie.title}" — none responded.\nThe real movie is unavailable from the provider right now. Choose another server or retry.';
      });
    } finally {
      _analysisInFlight = false;
    }
  }

  Future<void> _initVideoPlayer() async {
    final request = ++_sourceRequest;
    _usingAutomaticSource = false;
    final source = _currentSource;
    final streamUrl = source.streamUrl.isNotEmpty
        ? source.streamUrl
        : source.downloadUrl;
    final old = _videoController;
    _videoController = null;
    old?.removeListener(_videoListener);
    unawaited(_playbackControls.keepScreenOn(false));
    setState(() {
      _isAnalyzingServers = false;
      _isVideoInitialized = false;
      _isBuffering = true;
      _videoErrorMessage = null;
      _currentQuality = source.resolution;
    });

    VideoPlayerController? controller;
    try {
      await old?.dispose();
      if (!mounted || request != _sourceRequest) return;
      if (streamUrl.isEmpty) throw StateError('No stream URL');
      final format = source.format.toLowerCase();
      controller = streamUrl.startsWith('http')
          ? VideoPlayerController.networkUrl(
              Uri.parse(streamUrl),
              httpHeaders: _headersFor(source, streamUrl),
              formatHint: switch (format) {
                'm3u8' || 'hls' => VideoFormat.hls,
                'mpd' || 'dash' => VideoFormat.dash,
                _ => null,
              },
            )
          : VideoPlayerController.file(File(streamUrl));
      _videoController = controller;
      await controller.initialize().timeout(Duration(seconds: 15));
      if (!mounted || request != _sourceRequest) return;
      if (controller.value.hasError) throw StateError('Source rejected');
      if ({'m3u8', 'hls', 'mpd', 'dash'}.contains(format) &&
          controller.isVideoTrackSupportAvailable()) {
        final resolution = providerResolution(source.resolution);
        final height =
            int.tryParse(resolution.replaceAll('p', '')) ??
            int.tryParse(source.resolution.toLowerCase().replaceAll('p', ''));
        if (height != null) {
          final tracks = await controller.getVideoTracks();
          if (!mounted || request != _sourceRequest) return;
          final widescreenWidth = (height * 16 / 9).round();
          final matching = tracks
              .where(
                (track) => source.hlsVariantResolution != null
                    ? '${track.width}x${track.height}' ==
                          source.hlsVariantResolution
                    : track.height == height ||
                          (track.width == widescreenWidth &&
                              (track.height ?? 0) <= height),
              )
              .firstOrNull;
          if (matching == null && tracks.isNotEmpty) {
            throw StateError('The selected resolution is unavailable');
          }
          if (matching != null && !matching.isSelected) {
            await controller.selectVideoTrack(matching);
          }
        }
      }
      if (!mounted || request != _sourceRequest) return;
      await controller.setVolume(_volume);
      await controller.setPlaybackSpeed(_playbackSpeed);
      if (controller.value.duration > Duration.zero && _currentSeconds > 0) {
        await controller.seekTo(
          Duration(milliseconds: (_currentSeconds * 1000).round()),
        );
      }
      if (!mounted || request != _sourceRequest) return;

      controller.addListener(_videoListener);
      setState(() {
        _isVideoInitialized = true;
        _isBuffering = false;
        final duration = controller!.value.duration.inMilliseconds / 1000;
        if (duration > 0) _totalSeconds = duration;
      });
      if (_isPlaying) await controller.play();
    } catch (_) {
      if (!mounted || request != _sourceRequest) return;
      _showSelectedSourceError();
      if (identical(controller, _videoController)) {
        _videoController = null;
        controller?.removeListener(_videoListener);
        await controller?.dispose();
      }
    }
  }

  void _showSelectedSourceError() {
    unawaited(_playbackControls.keepScreenOn(false));
    setState(() {
      _isVideoInitialized = false;
      _isBuffering = false;
      _videoErrorMessage =
          '${_currentSource.resolution} from ${_currentSource.serverName} could not play.';
    });
  }

  void _videoListener() {
    if (!mounted || _videoController == null) return;
    final val = _videoController!.value;
    unawaited(
      _playbackControls.keepScreenOn(
        (val.isPlaying || val.isBuffering) && !val.hasError,
      ),
    );

    if (val.hasError) {
      if (!widget.isLiveTv && !_usingAutomaticSource) {
        _showSelectedSourceError();
        return;
      }
      debugPrint('Stream error detected: ${val.errorDescription}');
      // Smart failover: blacklist the failing server and jump to the next
      // healthy provider. Guarded so this can never loop indefinitely.
      _failedSourceKeys.add(StreamFallbackService.sourceKey(_currentSource));
      setState(() {
        _videoErrorMessage = val.errorDescription;
        _isBuffering = false;
        _isVideoInitialized = false;
      });
      if (!_analysisInFlight) {
        if (widget.isLiveTv) {
          unawaited(_connectLiveTv());
        } else {
          _autoAnalyzeAndConnect();
        }
      }
      return;
    }

    final isBuffering = val.isBuffering;
    final isPlaying = val.isPlaying;
    final pos = val.position.inMilliseconds / 1000.0;
    final dur = val.duration.inMilliseconds / 1000.0;

    bool needsUpdate = false;
    if (isBuffering != _isBuffering) {
      _isBuffering = isBuffering;
      needsUpdate = true;
    }
    if (isPlaying != _isPlaying) {
      _isPlaying = isPlaying;
      needsUpdate = true;
    }
    if ((pos - _currentSeconds).abs() >= 0.5) {
      _currentSeconds = pos;
      needsUpdate = true;
      if (_currentSeconds.toInt() % 5 == 0) {
        _saveProgress();
      }
    }
    if (dur > 0 && (_totalSeconds - dur).abs() > 1.0) {
      _totalSeconds = dur;
      needsUpdate = true;
    }

    if (needsUpdate && mounted) {
      setState(() {});
    }
  }

  void _saveProgress() {
    // Never record a trailer watch as movie progress, and live TV has no
    // seekable progress to remember.
    if (widget.trailerOnly || widget.isLiveTv) return;
    WatchHistoryService.instance.saveProgress(
      movieId: widget.movie.id,
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
    );
  }

  String _getCurrentEpisodeTitle() {
    if (!widget.movie.isSeries) return '';
    final season = widget.movie.seasons.firstWhere(
      (s) => s.seasonNumber == _currentSeasonNumber,
      orElse: () => widget.movie.seasons.isNotEmpty
          ? widget.movie.seasons.first
          : MovieSeason(seasonNumber: 1, title: '', episodes: []),
    );
    final ep = season.episodes.firstWhere(
      (e) => e.episodeNumber == _currentEpisodeNumber,
      orElse: () => season.episodes.isNotEmpty
          ? season.episodes.first
          : MovieEpisode(episodeNumber: 1, title: ''),
    );
    return ep.title;
  }

  void _togglePlay() {
    if (_videoController != null && _isVideoInitialized) {
      if (_videoController!.value.isPlaying) {
        _videoController!.pause();
        setState(() => _isPlaying = false);
      } else {
        if (PlayerService.instance.isAudioView) PlayerService.instance.close();
        _videoController!.play();
        setState(() => _isPlaying = true);
      }
    } else {
      setState(() {
        _isPlaying = !_isPlaying;
      });
    }
    _resetControlsTimer();
  }

  void _seekTo(double seconds) {
    final target = seconds.clamp(0.0, _totalSeconds);
    setState(() {
      _currentSeconds = target;
    });
    if (_videoController != null && _isVideoInitialized) {
      _videoController!.seekTo(Duration(milliseconds: (target * 1000).toInt()));
    }
    _saveProgress();
    _resetControlsTimer();
  }

  void _skip(double deltaSeconds) {
    _seekTo(_currentSeconds + deltaSeconds);
  }

  void _toggleFullScreen() {
    setState(() {
      _isFullScreen = !_isFullScreen;
    });

    if (Platform.isAndroid || Platform.isIOS) {
      if (_isFullScreen) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    }
  }

  void _resetControlsTimer() {
    _controlsDismissTimer?.cancel();
    if (_showControls && !_isLocked) {
      _controlsDismissTimer = Timer(Duration(seconds: 4), () {
        if (mounted && _isPlaying) {
          setState(() {
            _showControls = false;
          });
        }
      });
    }
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _resetControlsTimer();
    }
  }

  // Double tap forward/backward skip
  void _onDoubleTapLeft() {
    _skip(-10);
    setState(() {
      _showLeftDoubleTap = true;
    });
    Future.delayed(Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showLeftDoubleTap = false);
    });
  }

  void _onDoubleTapRight() {
    _skip(10);
    setState(() {
      _showRightDoubleTap = true;
    });
    Future.delayed(Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showRightDoubleTap = false);
    });
  }

  // MX Player Vertical Swipe Gestures
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
      // Right side: Brightness
      setState(() {
        _brightness = systemLevel ?? (_brightness + delta).clamp(0.05, 1.0);
        _showBrightnessHud = true;
        _showVolumeHud = false;
        _showSeekHud = false;
      });
    } else {
      // Left side: Volume
      setState(() {
        if (systemLevel == null) _volume = (_volume + delta).clamp(0.0, 1.0);
        _volumeHud = systemLevel ?? _volume;
        _showVolumeHud = true;
        _showBrightnessHud = false;
        _showSeekHud = false;
      });
      if (systemLevel == null) _videoController?.setVolume(_volume);
    }

    _hudDismissTimer?.cancel();
    _hudDismissTimer = Timer(Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _showBrightnessHud = false;
          _showVolumeHud = false;
        });
      }
    });
  }

  // Horizontal Drag Timeline Scrubbing
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
    _hudDismissTimer = Timer(Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() {
          _showSeekHud = false;
        });
      }
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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: context.palette.background,
      body: Stack(
        children: [
          // 1. Real Video Player Canvas
          _buildVideoCanvas(size),

          // 2. Gesture Detector Layer (MX Player Swipe Controls)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _toggleControls,
              onVerticalDragStart: (details) {
                _brightnessGesture = details.localPosition.dx >= size.width / 2;
                _firstVerticalUpdate = true;
              },
              onVerticalDragUpdate: _onVerticalDragUpdate,
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              onHorizontalDragEnd: _onHorizontalDragEnd,
              child: Row(
                children: [
                  // Left Double-Tap zone (Rewind 10s)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: _onDoubleTapLeft,
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                  // Center dead-zone
                  SizedBox(width: 60),
                  // Right Double-Tap zone (Fast-Forward 10s)
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

          // 3. Double-Tap Animated Ripple Overlays
          if (_showLeftDoubleTap)
            Positioned(
              left: 40,
              top: size.height / 2 - 40,
              child: _buildDoubleTapIndicator(Icons.replay_10_rounded, '-10s'),
            ),
          if (_showRightDoubleTap)
            Positioned(
              right: 40,
              top: size.height / 2 - 40,
              child: _buildDoubleTapIndicator(Icons.forward_10_rounded, '+10s'),
            ),

          // 4. MX Player HUD Overlays (Volume, Brightness, Scrubbing)
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
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: context.palette.shadowAt(0.8),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _seekDeltaSeconds >= 0
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      color: context.palette.onScrim,
                      size: 28,
                    ),
                    SizedBox(width: 10),
                    Text(
                      '${_seekDeltaSeconds >= 0 ? '+' : ''}${_seekDeltaSeconds.toInt()}s (${_formatTime(_currentSeconds + _seekDeltaSeconds)})',
                      style: TextStyle(
                        color: context.palette.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 5. Cinematic Player Overlay Controls (Header + Bottom Bar)
          if (_showControls) ...[
            // Top App Bar
            Positioned(left: 0, right: 0, top: 0, child: _buildTopBar(context)),

            // Bottom Controller Bar
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomBar(context),
            ),
          ],

          // Lock Indicator Button
          if (_isLocked)
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
                  color: context.palette.onScrim,
                  size: 30,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVideoCanvas(Size size) {
    if (_isVideoInitialized && _videoController != null) {
      Widget videoWidget;
      if (_aspectRatioMode == 'Fill' || _aspectRatioMode == 'Zoom') {
        videoWidget = SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _videoController!.value.size.width > 0
                  ? _videoController!.value.size.width
                  : 16,
              height: _videoController!.value.size.height > 0
                  ? _videoController!.value.size.height
                  : 9,
              child: VideoPlayer(_videoController!),
            ),
          ),
        );
      } else {
        final ratio = _aspectRatioMode == '16:9'
            ? 16 / 9
            : (_videoController!.value.aspectRatio > 0
                  ? _videoController!.value.aspectRatio
                  : 16 / 9);
        videoWidget = Center(
          child: AspectRatio(
            aspectRatio: ratio,
            child: VideoPlayer(_videoController!),
          ),
        );
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          videoWidget,
          if (_isBuffering)
            Center(
              child: Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: context.palette.shadowAt(0.7),
                  shape: BoxShape.circle,
                ),
                child: CircularProgressIndicator(
                  color: context.palette.primary,
                  strokeWidth: 3.5,
                ),
              ),
            ),
        ],
      );
    }

    if (_isAnalyzingServers) {
      return AspectRatio(
        aspectRatio: _getAspectRatio(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            SmartNetworkImage(
              url: widget.movie.backdropUrl.isNotEmpty
                  ? widget.movie.backdropUrl
                  : widget.movie.posterUrl,
              fit: BoxFit.cover,
              placeholderColor: context.palette.background,
              placeholderIcon: Icons.movie_rounded,
              accentColor: context.palette.tint(context.palette.onScrim, 0.24),
            ),
            Container(color: context.palette.shadowAt(0.82)),
            Center(
              child: SingleChildScrollView(
                child: Container(
                  margin: EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  padding: EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: context.palette.surface.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: context.palette.error.withValues(alpha: 0.2),
                        blurRadius: 24,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: context.palette.error
                              .withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: context.palette.error,
                              strokeWidth: 3,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 10),
                      Text(
                        'Auto Server Analyzer',
                        style: TextStyle(
                          color: context.palette.onScrim,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Analyzing and testing servers for optimal playback...',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: context.palette.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 240,
                          child: LinearProgressIndicator(
                            value: _totalCandidateServers > 0
                                ? (_analyzedServerIndex /
                                          _totalCandidateServers)
                                      .clamp(0.0, 1.0)
                                : null,
                            backgroundColor: context.palette.tint(context.palette.onScrim, 0.12),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              context.palette.error,
                            ),
                            minHeight: 5,
                          ),
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        _analyzingStatus,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: context.palette.error,
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _isAnalyzingServers = false;
                          });
                          _showServerPicker();
                        },
                        icon: Icon(
                          Icons.tune_rounded,
                          size: 15,
                          color: context.palette.textSecondary,
                        ),
                        label: Text(
                          'Select Server Manually',
                          style: TextStyle(color: context.palette.textSecondary, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AspectRatio(
      aspectRatio: _getAspectRatio(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          SmartNetworkImage(
            url: widget.movie.backdropUrl.isNotEmpty
                ? widget.movie.backdropUrl
                : widget.movie.posterUrl,
            fit: BoxFit.cover,
            placeholderColor: context.palette.background,
            placeholderIcon: Icons.movie_rounded,
            accentColor: context.palette.tint(context.palette.onScrim, 0.24),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  context.palette.shadowAt(0.3),
                  Colors.transparent,
                  context.palette.shadowAt(0.5),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          if (_videoErrorMessage != null)
            Center(
              child: Container(
                margin: EdgeInsets.symmetric(horizontal: 24),
                padding: EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: context.palette.shadowAt(0.90),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      color: context.palette.error,
                      size: 36,
                    ),
                    SizedBox(height: 8),
                    Text(
                      _videoErrorMessage!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.palette.onScrim, fontSize: 12),
                    ),
                    SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => widget.isLiveTv
                              ? _connectLiveTv(resetFailures: true)
                              : widget.trailerOnly
                              ? _playTrailer()
                              : _initVideoPlayer(),
                          icon: Icon(Icons.refresh_rounded, size: 16),
                          label: Text(
                            widget.isLiveTv
                                ? 'Retry Channel'
                                : 'Retry selected source',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: context.palette.primary,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _launchSystemPlayer,
                          icon: Icon(
                            Icons.play_circle_fill_rounded,
                            size: 16,
                          ),
                          label: Text('Open in VLC / MPV'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: context.palette.card,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _showServerPicker,
                          icon: Icon(
                            Icons.dns_rounded,
                            size: 16,
                            color: context.palette.textSecondary,
                          ),
                          label: Text(
                            'Choose Server',
                            style: TextStyle(color: context.palette.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          else if (_isBuffering)
            Center(
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: context.palette.shadowAt(0.8),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      color: context.palette.primary,
                      strokeWidth: 3,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Connecting to Stream...',
                      style: TextStyle(
                        color: context.palette.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (!_isPlaying)
            Center(
              child: Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: context.palette.shadowAt(0.6),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.pause_rounded,
                  color: context.palette.onScrim,
                  size: 48,
                ),
              ),
            ),
        ],
      ),
    );
  }

  double _getAspectRatio() {
    switch (_aspectRatioMode) {
      case '16:9':
        return 16 / 9;
      case 'Fill':
        return 21 / 9;
      case 'Zoom':
        return 4 / 3;
      case 'Fit':
      default:
        if (_videoController != null &&
            _isVideoInitialized &&
            _videoController!.value.aspectRatio > 0) {
          return _videoController!.value.aspectRatio;
        }
        return 16 / 9;
    }
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [context.palette.shadowAt(0.85), Colors.transparent],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: Icon(
                Icons.arrow_back_rounded,
                color: context.palette.onScrim,
                size: 26,
              ),
            ),
            SizedBox(width: 8),
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
                      color: context.palette.onScrim,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  if (widget.movie.isSeries)
                    Text(
                      'Season $_currentSeasonNumber • Episode $_currentEpisodeNumber: ${_getCurrentEpisodeTitle()}',
                      style: TextStyle(
                        color: context.palette.tint(context.palette.onScrim, 0.7),
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
                    // Repository / Server Switcher
                    if (widget.movie.sources.isNotEmpty)
                      _buildHeaderAction(
                        icon: Icons.dns_rounded,
                        label:
                            'Servers (${_lastProviderReports.isNotEmpty ? _lastProviderReports.length : widget.movie.sources.length})',
                        color: context.palette.onScrim,
                        onTap: _showServerPicker,
                      ),

                    // Quality Badge Button
                    _buildHeaderAction(
                      icon: Icons.hd_rounded,
                      label: _currentQuality,
                      color: context.palette.onScrim,
                      onTap: _showQualityPicker,
                    ),

                    // Audio & Subs Picker
                    _buildHeaderAction(
                      icon: Icons.audiotrack_rounded,
                      label: 'Audio/Subs',
                      color: context.palette.onScrim,
                      onTap: _showAudioAndSubtitlesPicker,
                    ),

                    _buildHeaderAction(
                      icon: Icons.headphones_rounded,
                      label: 'Audio only',
                      color: context.palette.onScrim,
                      onTap: _openAudioPlayer,
                    ),

                    // Seasons & Episodes (if series)
                    if (widget.movie.isSeries)
                      _buildHeaderAction(
                        icon: Icons.video_library_rounded,
                        label: 'Episodes',
                        color: context.palette.onScrim,
                        onTap: _showSeasonEpisodeDrawer,
                      ),

                    // External System Player Launch
                    IconButton(
                      tooltip: 'Play in External Player (VLC / MPV / MX)',
                      onPressed: _launchSystemPlayer,
                      icon: Icon(
                        Icons.open_in_new_rounded,
                        color: context.palette.onScrim,
                      ),
                    ),

                    // Lock Screen Button
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
                        color: context.palette.onScrim,
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
    required Color color,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: context.palette.onScrim, size: 16),
              SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: context.palette.onScrim,
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

  Widget _buildBottomBar(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.transparent, context.palette.shadowAt(0.9)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Timeline Scrubber
            Row(
              children: [
                Text(
                  _formatTime(_currentSeconds),
                  style: TextStyle(color: context.palette.onScrim, fontSize: 12),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3.5,
                      thumbShape: RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      activeTrackColor: context.palette.primary,
                      inactiveTrackColor: context.palette.tint(context.palette.onScrim, 0.24),
                      thumbColor: context.palette.primary,
                    ),
                    child: Slider(
                      value: _currentSeconds.clamp(0.0, _totalSeconds),
                      min: 0.0,
                      max: _totalSeconds,
                      onChanged: (val) {
                        _seekTo(val);
                      },
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  _formatTime(_totalSeconds),
                  style: TextStyle(color: context.palette.onScrim, fontSize: 12),
                ),
              ],
            ),

            // Controls Row
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Aspect Ratio Selector
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        if (_aspectRatioMode == 'Fit') {
                          _aspectRatioMode = '16:9';
                        } else if (_aspectRatioMode == '16:9') {
                          _aspectRatioMode = 'Zoom';
                        } else if (_aspectRatioMode == 'Zoom') {
                          _aspectRatioMode = 'Fill';
                        } else {
                          _aspectRatioMode = 'Fit';
                        }
                      });
                    },
                    icon: Icon(
                      Icons.aspect_ratio_rounded,
                      color: context.palette.onScrim,
                      size: 18,
                    ),
                    label: Text(
                      _aspectRatioMode,
                      style: TextStyle(
                        color: context.palette.onScrim,
                        fontSize: 12,
                      ),
                    ),
                  ),

                  SizedBox(width: 8),

                  // Center Playback Controls
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.replay_10_rounded,
                          color: context.palette.onScrim,
                          size: 28,
                        ),
                        onPressed: () => _skip(-10),
                      ),
                      SizedBox(width: 10),
                      Container(
                        decoration: BoxDecoration(
                          gradient: context.palette.primaryGradient,
                          shape: BoxShape.circle,
                        ),
                        child: Tooltip(
                          message: _isPlaying ? 'Pause' : 'Play',
                          child: IconButton(
                            icon: Icon(
                              _isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: context.palette.onPrimary,
                              size: 32,
                            ),
                            onPressed: _togglePlay,
                          ),
                        ),
                      ),
                      SizedBox(width: 10),
                      IconButton(
                        icon: Icon(
                          Icons.forward_10_rounded,
                          color: context.palette.onScrim,
                          size: 28,
                        ),
                        onPressed: () => _skip(10),
                      ),
                    ],
                  ),

                  SizedBox(width: 8),

                  // Speed Selector & Download Trigger & Fullscreen Toggle
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            if (_playbackSpeed == 1.0) {
                              _playbackSpeed = 1.25;
                            } else if (_playbackSpeed == 1.25) {
                              _playbackSpeed = 1.5;
                            } else if (_playbackSpeed == 1.5) {
                              _playbackSpeed = 2.0;
                            } else if (_playbackSpeed == 2.0) {
                              _playbackSpeed = 0.75;
                            } else {
                              _playbackSpeed = 1.0;
                            }
                          });
                          _videoController?.setPlaybackSpeed(_playbackSpeed);
                        },
                        child: Text(
                          '${_playbackSpeed}x',
                          style: TextStyle(
                            color: context.palette.onScrim,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Download Episode / Movie',
                        icon: Icon(
                          Icons.download_rounded,
                          color: context.palette.onScrim,
                        ),
                        onPressed: () async {
                          final customTitle = widget.movie.isSeries
                              ? '${widget.movie.title} - S${_currentSeasonNumber}E$_currentEpisodeNumber'
                              : widget.movie.title;
                          final activeSource = _currentSource;
                          final hasPerm = await PermissionService.instance
                              .hasStoragePermission();
                          if (!hasPerm) {
                            final granted = await PermissionService.instance
                                .requestStoragePermission();
                            if (!granted) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Storage permission required to download.',
                                    ),
                                  ),
                                );
                              }
                              return;
                            }
                          }

                          await DownloadManager.instance.startMovieDownload(
                            movie: widget.movie,
                            source: activeSource,
                            customTitle: customTitle,
                            seasonNumber: widget.movie.isSeries
                                ? _currentSeasonNumber
                                : null,
                          );

                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                backgroundColor: context.palette.card,
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                content: Row(
                                  children: [
                                    Icon(
                                      Icons.download_done_rounded,
                                      color: context.palette.primary,
                                      size: 24,
                                    ),
                                    SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        'Downloading "$customTitle" (${activeSource.resolution})',
                                        style: TextStyle(
                                          color: context.palette.textPrimary,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                        },
                      ),
                      IconButton(
                        tooltip: _isFullScreen
                            ? 'Exit Fullscreen'
                            : 'Enter Fullscreen',
                        icon: Icon(
                          _isFullScreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          color: context.palette.onScrim,
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
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.palette.shadowAt(0.7),
        shape: BoxShape.circle,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: context.palette.onScrim, size: 32),
          Text(
            label,
            style: TextStyle(
              color: context.palette.onScrim,
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: 170,
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: context.palette.shadowAt(0.75),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: context.palette.onScrim, size: 34),
              SizedBox(height: 10),
              Text(
                label,
                style: TextStyle(
                  color: context.palette.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 6),
              LinearProgressIndicator(
                value: value,
                backgroundColor: context.palette.tint(context.palette.onScrim, 0.12),
                valueColor: AlwaysStoppedAnimation(context.palette.primary),
                minHeight: 5,
                borderRadius: BorderRadius.circular(4),
              ),
              SizedBox(height: 8),
              Text(
                percentage,
                style: TextStyle(
                  color: context.palette.onScrim,
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

  // Pickers & Modals
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
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * .65,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              ListTile(title: Text('Available quality')),
              for (final source in sources)
                ListTile(
                  leading: Icon(Icons.hd_outlined),
                  title: Text(source.resolution),
                  subtitle: Text(
                    '${source.serverName} · ${source.format.toUpperCase()}',
                  ),
                  trailing:
                      (source.resolution == _currentSource.resolution &&
                          source.streamUrl == _currentSource.streamUrl &&
                          source.downloadUrl == _currentSource.downloadUrl)
                      ? Icon(Icons.check_rounded)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    _currentSource = source;
                    if (widget.isLiveTv) {
                      _connectLiveTv(resetFailures: true);
                    } else {
                      _initVideoPlayer();
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAudioAndSubtitlesPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.palette.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: EdgeInsets.all(20),
          child: ListView(
            shrinkWrap: true,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.record_voice_over_rounded,
                    color: context.palette.primary,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Audio Tracks & Subtitles',
                    style: TextStyle(
                      color: context.palette.onPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 14),
              Text(
                'Audio Language',
                style: TextStyle(
                  color: context.palette.textSecondary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              SizedBox(height: 6),
              ...widget.movie.audioTracks.map((track) {
                final isSelected = _currentAudioTrack == track;
                return ListTile(
                  dense: true,
                  title: Text(
                    track,
                    style: TextStyle(
                      color: isSelected ? context.palette.primary : context.palette.card,
                    ),
                  ),
                  trailing: isSelected
                      ? Icon(
                          Icons.check_circle_rounded,
                          color: context.palette.primary,
                        )
                      : null,
                  onTap: () {
                    setState(() => _currentAudioTrack = track);
                    Navigator.pop(ctx);
                  },
                );
              }),
              Divider(color: context.palette.tint(context.palette.onScrim, 0.12)),
              Text(
                'Subtitles / Closed Captions',
                style: TextStyle(
                  color: context.palette.textSecondary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              SizedBox(height: 6),
              ...widget.movie.subtitles.map((sub) {
                final isSelected = _currentSubtitle == sub;
                return ListTile(
                  dense: true,
                  title: Text(
                    sub,
                    style: TextStyle(
                      color: isSelected ? context.palette.success : context.palette.card,
                    ),
                  ),
                  trailing: isSelected
                      ? Icon(
                          Icons.check_circle_rounded,
                          color: context.palette.success,
                        )
                      : null,
                  onTap: () {
                    setState(() => _currentSubtitle = sub);
                    Navigator.pop(ctx);
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _showSeasonEpisodeDrawer() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.palette.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDrawerState) {
            final activeSeason = widget.movie.seasons.firstWhere(
              (s) => s.seasonNumber == _currentSeasonNumber,
              orElse: () => widget.movie.seasons.isNotEmpty
                  ? widget.movie.seasons.first
                  : MovieSeason(
                      seasonNumber: 1,
                      title: 'Season 1',
                      episodes: [],
                    ),
            );

            return Container(
              height: MediaQuery.of(context).size.height * 0.8,
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${widget.movie.title} • Episodes',
                        style: TextStyle(
                          color: context.palette.onScrim,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: context.palette.onScrim,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  SizedBox(height: 10),

                  // Season Selection Chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: widget.movie.seasons.map((s) {
                        final isSel = s.seasonNumber == _currentSeasonNumber;
                        return Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(s.title),
                            selected: isSel,
                            selectedColor: context.palette.secondary,
                            onSelected: (val) {
                              setDrawerState(() {
                                _currentSeasonNumber = s.seasonNumber;
                              });
                              setState(() {});
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  SizedBox(height: 14),

                  // Episode List
                  Expanded(
                    child: ListView.builder(
                      itemCount: activeSeason.episodes.length,
                      itemBuilder: (context, idx) {
                        final ep = activeSeason.episodes[idx];
                        final isSelected =
                            ep.episodeNumber == _currentEpisodeNumber;

                        return Container(
                          margin: EdgeInsets.only(bottom: 10),
                          child: Material(
                            color: isSelected
                                ? context.palette.secondary.withValues(alpha: 0.2)
                                : context.palette.tint(context.palette.border, 0.26),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              leading: Container(
                                width: 60,
                                height: 40,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  image: ep.thumbnailUrl.isNotEmpty
                                      ? DecorationImage(
                                          image: NetworkImage(ep.thumbnailUrl),
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                  color: context.palette.textSecondary,
                                ),
                                child: isSelected
                                    ? Center(
                                        child: Icon(
                                          Icons.play_arrow_rounded,
                                          color: context.palette.onScrim,
                                        ),
                                      )
                                    : null,
                              ),
                              title: Text(
                                'E${ep.episodeNumber}: ${ep.title}',
                                style: TextStyle(
                                  color: isSelected
                                      ? context.palette.secondary
                                      : context.palette.card,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: Text(
                                '${ep.duration} • ${ep.synopsis}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.palette.textSecondary,
                                ),
                              ),
                              onTap: () {
                                setState(() {
                                  _currentEpisodeNumber = ep.episodeNumber;
                                  _currentSeconds = 0;
                                  if (ep.sources.isNotEmpty) {
                                    _currentSource = ep.sources.first;
                                  }
                                });
                                _saveProgress();
                                Navigator.pop(ctx);
                                _initVideoPlayer();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Playing Season $_currentSeasonNumber Episode ${ep.episodeNumber}',
                                    ),
                                    behavior: SnackBarBehavior.floating,
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
    // Prefer the live multi-provider health report; fall back to the movie's
    // own server list before the first scan completes.
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

    showModalBottomSheet(
      context: context,
      backgroundColor: context.palette.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.hub_rounded, color: context.palette.success),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Providers / Servers (${reports.length} Found Across Installed Repos)',
                      style: TextStyle(
                        color: context.palette.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Re-scan & test all providers',
                    icon: Icon(
                      Icons.refresh_rounded,
                      color: context.palette.info,
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      if (widget.isLiveTv) {
                        _connectLiveTv(resetFailures: true);
                      } else {
                        _autoAnalyzeAndConnect(resetFailures: true);
                      }
                    },
                  ),
                ],
              ),
              SizedBox(height: 6),
              Text(
                'Green = stream verified • Grey = untested • Red = known dead',
                style: TextStyle(
                  color: context.palette.tint(context.palette.card, 0.5),
                  fontSize: 11,
                ),
              ),
              SizedBox(height: 10),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: reports.length,
                  separatorBuilder: (_, _) => SizedBox(height: 6),
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
                        ? context.palette.success
                        : (isDead ? context.palette.error : context.palette.textSecondary);

                    return Material(
                      color: isSelected
                          ? context.palette.tint(context.palette.success, 0.18)
                          : context.palette.tint(context.palette.card, 0.05),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        leading: Icon(
                          source.isFastBDIX
                              ? Icons.flash_on_rounded
                              : Icons.dns_rounded,
                          color: source.isFastBDIX
                              ? context.palette.info
                              : healthColor,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                source.serverName,
                                style: TextStyle(
                                  color: isSelected
                                      ? context.palette.success
                                      : context.palette.card,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            if (report.validStream)
                              Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: context.palette.tint(context.palette.success, 0.2,),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${report.latencyMs}ms',
                                  style: TextStyle(
                                    color: context.palette.success,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          '${source.providerName.isNotEmpty ? "${source.providerName} • " : ""}'
                          '${source.resolution} • ${source.fileSize}${report.statusText.isNotEmpty && !report.validStream ? " • ${report.statusText}" : ""}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDead
                                ? context.palette.tint(context.palette.error, 0.8)
                                : context.palette.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: context.palette.success,
                              )
                            : null,
                        onTap: () {
                          // Manual override: un-blacklist this server and switch to it.
                          _failedSourceKeys.remove(
                            StreamFallbackService.sourceKey(source),
                          );
                          setState(() {
                            _currentSource = source;
                            _currentQuality = source.resolution;
                          });
                          Navigator.pop(ctx);
                          _initVideoPlayer();
                          final providerTag = source.providerName.isNotEmpty
                              ? ' (${source.providerName})'
                              : '';
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Switched to ${source.serverName}$providerTag',
                              ),
                              behavior: SnackBarBehavior.floating,
                              backgroundColor: context.palette.primary,
                            ),
                          );
                        },
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
  }

  Future<void> _openAudioPlayer() async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    final url = controller.dataSourceType == DataSourceType.file
        ? Uri.parse(controller.dataSource).toFilePath()
        : controller.dataSource;
    final source = _currentSource;
    final player = PlayerService.instance;
    final itemId =
        'movie:${widget.movie.id}:$_currentSeasonNumber:$_currentEpisodeNumber';
    await controller.pause();
    if (!mounted || !identical(_videoController, controller)) return;
    if (player.isAudioView &&
        player.currentItem?.id == itemId &&
        player.currentItem?.videoUrl == url) {
      player.expand();
    } else {
      player.playVideoItem(
        VideoItem(
          id: itemId,
          title: widget.movie.title,
          author: '',
          thumbnailUrl: widget.movie.posterUrl,
          videoUrl: url,
          platform: 'Movies',
        ),
        audioOnly: true,
        headers: _headersFor(source, url),
        mimeType: switch (source.format.toLowerCase()) {
          'm3u8' => 'application/x-mpegURL',
          'mpd' => 'application/dash+xml',
          _ => null,
        },
        position: controller.value.position,
      );
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) => AudioPlayerScreen(
          returnToVideo: () {
            final position = Duration(
              milliseconds: (player.currentSeconds * 1000).round(),
            );
            player.close();
            Navigator.of(routeContext).pop();
            if (!mounted || !identical(_videoController, controller)) return;
            unawaited(_resumeVideo(controller, position));
          },
        ),
      ),
    );
  }

  Future<void> _resumeVideo(
    VideoPlayerController controller,
    Duration position,
  ) async {
    await controller.seekTo(position);
    if (mounted && identical(_videoController, controller))
      await controller.play();
  }

  void _launchSystemPlayer() {
    final url = _currentSource.streamUrl.isNotEmpty
        ? _currentSource.streamUrl
        : _currentSource.downloadUrl;
    if (url.isNotEmpty) {
      PlayerService.instance.launchSystemPlayer(url);
    }
  }
}
