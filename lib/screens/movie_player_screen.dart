import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/movie_model.dart';
import '../services/download_manager.dart';
import '../services/extractor_service.dart';
import '../services/permission_service.dart';
import '../services/player_service.dart';
import '../services/preference_service.dart';
import '../services/stream_fallback_service.dart';
import '../services/watch_history_service.dart';
import '../theme/app_colors.dart';
import '../widgets/remote_image.dart';

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

  const MoviePlayerScreen({
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
  final Set<String> _failedSourceKeys = {};
  List<ProviderStreamReport> _lastProviderReports = const [];

  // Gesture Controls (MX Player Style)
  double _brightness = 0.75;
  double _volume = 0.80;
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

    // Automatically analyze servers and select the fastest playable server!
    if (widget.trailerOnly) {
      _playTrailer();
    } else if (widget.isLiveTv) {
      unawaited(_connectLiveTv());
    } else {
      _autoAnalyzeAndConnect();
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
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(liveUrl),
        httpHeaders: StreamFallbackService.streamHeadersFor(liveUrl),
      );
      _videoController = controller;
      await controller.initialize().timeout(const Duration(seconds: 15));
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
            !const ['http', 'https'].contains(uri.scheme)) {
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
          await controller.initialize().timeout(const Duration(seconds: 18));
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
    _analysisInFlight = true;
    if (resetFailures) _failedSourceKeys.clear();

    try {
      if (!mounted) return;
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
        reports = const [];
      }
      if (!mounted) return;
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
        if (!mounted) return;
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
              ? const Duration(seconds: 20)
              : const Duration(seconds: 16);
          await controller.initialize().timeout(initTimeout);
          if (!mounted) return;

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
                      const Icon(
                        Icons.check_circle_rounded,
                        color: Colors.greenAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Playing via ${candidate.serverName}'
                          '${candidate.providerName.isNotEmpty ? ' (${candidate.providerName})' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  duration: const Duration(seconds: 3),
                  backgroundColor: const Color(0xFF1E2235),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
            return;
          }
          throw Exception('Player reported an unusable stream');
        } catch (e) {
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
      if (!mounted) return;

      // There is deliberately NO silent fallback to a YouTube trailer / sample
      // clip here — the user must only ever watch the REAL movie. If none of
      // the provider's actual streams played, report the failure honestly.
      setState(() {
        _isAnalyzingServers = false;
        _isBuffering = false;
        _isVideoInitialized = false;
        _videoErrorMessage =
            'Tested ${_failedSourceKeys.length} server(s) for "${widget.movie.title}" — none responded.\nThe real movie is unavailable from the provider right now. Tap "Re-Scan All Providers" to try again.';
      });
    } finally {
      _analysisInFlight = false;
    }
  }

  /// Initialize video player for a specific chosen source
  Future<void> _initVideoPlayer() async {
    final streamUrl = _currentSource.streamUrl.isNotEmpty
        ? _currentSource.streamUrl
        : _currentSource.downloadUrl;

    if (streamUrl.isEmpty) {
      _videoErrorMessage = 'No valid stream URL found for this server.';
      setState(() => _isBuffering = false);
      return;
    }

    setState(() {
      _isBuffering = true;
      _videoErrorMessage = null;
    });

    final oldController = _videoController;
    _videoController = null;
    oldController?.removeListener(_videoListener);
    await oldController?.dispose();

    try {
      final controller = streamUrl.startsWith('http')
          ? VideoPlayerController.networkUrl(
              Uri.parse(streamUrl),
              httpHeaders: _headersFor(_currentSource, streamUrl),
              formatHint: _currentSource.format == 'm3u8'
                  ? VideoFormat.hls
                  : null,
            )
          : VideoPlayerController.file(File(streamUrl));
      _videoController = controller;

      await controller.initialize().timeout(const Duration(seconds: 10));
      if (!mounted) return;

      if (controller.value.isInitialized && !controller.value.hasError) {
        await controller.setVolume(_volume);
        await controller.setPlaybackSpeed(_playbackSpeed);

        if (_currentSeconds > 0) {
          await controller.seekTo(Duration(seconds: _currentSeconds.toInt()));
        }

        controller.addListener(_videoListener);

        setState(() {
          _isVideoInitialized = true;
          _isBuffering = false;
          final dur = controller.value.duration.inSeconds.toDouble();
          if (dur > 0) {
            _totalSeconds = dur;
          }
        });

        if (_isPlaying) {
          await controller.play();
        }
      } else {
        throw Exception('Failed to initialize stream');
      }
    } catch (e) {
      debugPrint('VideoPlayer single init notice: $e');
      if (mounted) {
        // Mark the chosen server dead, then automatically fall through to the
        // next healthy provider across the entire installed provider pool.
        _failedSourceKeys.add(StreamFallbackService.sourceKey(_currentSource));
        _autoAnalyzeAndConnect();
      }
    }
  }

  void _videoListener() {
    if (!mounted || _videoController == null) return;
    final val = _videoController!.value;

    if (val.hasError) {
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
          : const MovieSeason(seasonNumber: 1, title: '', episodes: []),
    );
    final ep = season.episodes.firstWhere(
      (e) => e.episodeNumber == _currentEpisodeNumber,
      orElse: () => season.episodes.isNotEmpty
          ? season.episodes.first
          : const MovieEpisode(episodeNumber: 1, title: ''),
    );
    return ep.title;
  }

  void _togglePlay() {
    if (_videoController != null && _isVideoInitialized) {
      if (_videoController!.value.isPlaying) {
        _videoController!.pause();
        setState(() => _isPlaying = false);
      } else {
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
      _controlsDismissTimer = Timer(const Duration(seconds: 4), () {
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
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showLeftDoubleTap = false);
    });
  }

  void _onDoubleTapRight() {
    _skip(10);
    setState(() {
      _showRightDoubleTap = true;
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showRightDoubleTap = false);
    });
  }

  // MX Player Vertical Swipe Gestures
  void _onVerticalDragUpdate(DragUpdateDetails details, double screenWidth) {
    if (_isLocked) return;

    final isRightSide = details.globalPosition.dx > (screenWidth / 2);
    final delta = -details.primaryDelta! / 250;

    if (isRightSide) {
      // Right side: Brightness
      setState(() {
        _brightness = (_brightness + delta).clamp(0.05, 1.0);
        _showBrightnessHud = true;
        _showVolumeHud = false;
        _showSeekHud = false;
      });
    } else {
      // Left side: Volume
      setState(() {
        _volume = (_volume + delta).clamp(0.0, 1.0);
        _showVolumeHud = true;
        _showBrightnessHud = false;
        _showSeekHud = false;
      });
      _videoController?.setVolume(_volume);
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

  // Horizontal Drag Timeline Scrubbing
  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_isLocked) return;

    setState(() {
      _seekDeltaSeconds += details.primaryDelta! * 1.5;
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

    _hudDismissTimer = Timer(const Duration(milliseconds: 1000), () {
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
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Real Video Player Canvas
          _buildVideoCanvas(size),

          // 2. Gesture Detector Layer (MX Player Swipe Controls)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _toggleControls,
              onVerticalDragUpdate: (details) =>
                  _onVerticalDragUpdate(details, size.width),
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
                  const SizedBox(width: 60),
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
                icon: _volume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                label: 'Volume',
                value: _volume,
                percentage: '${(_volume * 100).toInt()}%',
              ),
            ),
          if (_showSeekHud)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _seekDeltaSeconds >= 0
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      color: AppColors.primary,
                      size: 28,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${_seekDeltaSeconds >= 0 ? '+' : ''}${_seekDeltaSeconds.toInt()}s (${_formatTime(_currentSeconds + _seekDeltaSeconds)})',
                      style: const TextStyle(
                        color: Colors.white,
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
                icon: const Icon(
                  Icons.lock_rounded,
                  color: AppColors.accentGold,
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
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  shape: BoxShape.circle,
                ),
                child: const CircularProgressIndicator(
                  color: AppColors.primary,
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
              placeholderColor: const Color(0xFF0F172A),
              placeholderIcon: Icons.movie_rounded,
              accentColor: Colors.white24,
            ),
            Container(color: Colors.black.withValues(alpha: 0.82)),
            Center(
              child: SingleChildScrollView(
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131622).withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFF4D57).withValues(alpha: 0.2),
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
                          color: const Color(0xFFFF4D57)
                              .withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Color(0xFFFF4D57),
                              strokeWidth: 3,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Auto Server Analyzer',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Analyzing and testing servers for optimal playback...',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 10),
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
                            backgroundColor: Colors.white12,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFFFF4D57),
                            ),
                            minHeight: 5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _analyzingStatus,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFFF4D57),
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _isAnalyzingServers = false;
                          });
                          _showServerPicker();
                        },
                        icon: const Icon(
                          Icons.tune_rounded,
                          size: 15,
                          color: Colors.grey,
                        ),
                        label: const Text(
                          'Select Server Manually',
                          style: TextStyle(color: Colors.grey, fontSize: 11),
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
            placeholderColor: const Color(0xFF0F172A),
            placeholderIcon: Icons.movie_rounded,
            accentColor: Colors.white24,
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.black.withValues(alpha: 0.3),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.5),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          if (_videoErrorMessage != null)
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.90),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: Colors.redAccent,
                      size: 36,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _videoErrorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => widget.isLiveTv
                              ? _connectLiveTv(resetFailures: true)
                              : _autoAnalyzeAndConnect(resetFailures: true),
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: Text(
                            widget.isLiveTv
                                ? 'Retry Channel'
                                : 'Re-Scan All Providers',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _launchSystemPlayer,
                          icon: const Icon(
                            Icons.play_circle_fill_rounded,
                            size: 16,
                          ),
                          label: const Text('Open in VLC / MPV'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _showServerPicker,
                          icon: const Icon(
                            Icons.dns_rounded,
                            size: 16,
                            color: Colors.white70,
                          ),
                          label: const Text(
                            'Choose Server',
                            style: TextStyle(color: Colors.white70),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      color: AppColors.primary,
                      strokeWidth: 3,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Connecting to Stream...',
                      style: TextStyle(
                        color: Colors.white,
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
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.pause_rounded,
                  color: Colors.white,
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.black.withValues(alpha: 0.85), Colors.transparent],
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
              icon: const Icon(
                Icons.arrow_back_rounded,
                color: Colors.white,
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
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  if (widget.movie.isSeries)
                    Text(
                      'Season $_currentSeasonNumber • Episode $_currentEpisodeNumber: ${_getCurrentEpisodeTitle()}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
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
                        color: AppColors.accentGreen,
                        onTap: _showServerPicker,
                      ),

                    // Quality Badge Button
                    _buildHeaderAction(
                      icon: Icons.hd_rounded,
                      label: _currentQuality,
                      color: AppColors.accentGold,
                      onTap: _showQualityPicker,
                    ),

                    // Audio & Subs Picker
                    _buildHeaderAction(
                      icon: Icons.audiotrack_rounded,
                      label: 'Audio/Subs',
                      color: AppColors.accentPurple,
                      onTap: _showAudioAndSubtitlesPicker,
                    ),

                    // Seasons & Episodes (if series)
                    if (widget.movie.isSeries)
                      _buildHeaderAction(
                        icon: Icons.video_library_rounded,
                        label: 'Episodes',
                        color: const Color(0xFF00ADB5),
                        onTap: _showSeasonEpisodeDrawer,
                      ),

                    // External System Player Launch
                    IconButton(
                      tooltip: 'Play in External Player (VLC / MPV / MX)',
                      onPressed: _launchSystemPlayer,
                      icon: const Icon(
                        Icons.open_in_new_rounded,
                        color: Colors.white70,
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
                      icon: const Icon(
                        Icons.lock_open_rounded,
                        color: Colors.white70,
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
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.9)],
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
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3.5,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      activeTrackColor: AppColors.primary,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: AppColors.primary,
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
                const SizedBox(width: 8),
                Text(
                  _formatTime(_totalSeconds),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
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
                    icon: const Icon(
                      Icons.aspect_ratio_rounded,
                      color: Colors.white70,
                      size: 18,
                    ),
                    label: Text(
                      _aspectRatioMode,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),

                  // Center Playback Controls
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.replay_10_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                        onPressed: () => _skip(-10),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        decoration: const BoxDecoration(
                          gradient: AppColors.primaryGradient,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: Icon(
                            _isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                          onPressed: _togglePlay,
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: const Icon(
                          Icons.forward_10_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                        onPressed: () => _skip(10),
                      ),
                    ],
                  ),

                  const SizedBox(width: 8),

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
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Download Episode / Movie',
                        icon: const Icon(
                          Icons.download_rounded,
                          color: AppColors.primary,
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
                                  const SnackBar(
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
                          );

                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                backgroundColor: AppColors.darkCard,
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                content: Row(
                                  children: [
                                    const Icon(
                                      Icons.download_done_rounded,
                                      color: AppColors.primary,
                                      size: 24,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        'Downloading "$customTitle" (${activeSource.resolution})',
                                        style: const TextStyle(
                                          color: Colors.white,
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
                          color: Colors.white,
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        shape: BoxShape.circle,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.primary, size: 32),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 34),
              const SizedBox(height: 10),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: value,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                minHeight: 5,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Text(
                percentage,
                style: const TextStyle(
                  color: Colors.white,
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final qualities = [
          {'label': '4K Ultra HD (2160p)', 'badge': 'UHD', 'res': '4K UHD'},
          {'label': '1080p Full HD', 'badge': 'FHD', 'res': '1080p Full HD'},
          {'label': '720p HD', 'badge': 'HD', 'res': '720p HD'},
          {
            'label': '480p Standard Definition',
            'badge': 'SD',
            'res': '480p SD',
          },
          {
            'label': '360p Data Saver',
            'badge': 'Low',
            'res': '360p Data Saver',
          },
          {'label': 'Auto (Best for Network)', 'badge': 'Auto', 'res': 'Auto'},
        ];

        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.settings_suggest_rounded,
                    color: AppColors.accentGold,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Video Quality (YouTube Style)',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ...qualities.map((q) {
                      final isSelected =
                          _currentQuality.contains(q['res']!) ||
                          (_currentQuality == q['res']);
                      return ListTile(
                        dense: true,
                        leading: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.accentGold
                                : Colors.white12,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            q['badge']!,
                            style: TextStyle(
                              color: isSelected ? Colors.black : Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        title: Text(
                          q['label']!,
                          style: TextStyle(
                            color: isSelected
                                ? AppColors.accentGold
                                : Colors.white,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(
                                Icons.check_rounded,
                                color: AppColors.accentGold,
                              )
                            : null,
                        onTap: () {
                          setState(() {
                            _currentQuality = q['res']!;
                            if (q['res'] == 'Auto') {
                              // Auto = let the multi-provider analyzer pick the best server
                            } else {
                              // Search the cross-provider scan pool first, then the
                              // movie's own servers, for a matching resolution.
                              final resNeedle = q['res']!.toLowerCase();
                              final pool = _lastProviderReports.isNotEmpty
                                  ? _lastProviderReports
                                        .map((r) => r.source)
                                        .toList()
                                  : widget.movie.sources;
                              final matching = pool
                                  .where(
                                    (s) => s.resolution.toLowerCase().contains(
                                      resNeedle,
                                    ),
                                  )
                                  .toList();
                              if (matching.isNotEmpty) {
                                _currentSource = matching.first;
                              }
                            }
                          });
                          Navigator.pop(ctx);
                          if (widget.isLiveTv) {
                            _connectLiveTv(resetFailures: true);
                          } else if (q['res'] == 'Auto') {
                            _autoAnalyzeAndConnect(resetFailures: true);
                          } else {
                            _initVideoPlayer();
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Switched to ${q['label']}'),
                              duration: const Duration(seconds: 1),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAudioAndSubtitlesPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: ListView(
            shrinkWrap: true,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.record_voice_over_rounded,
                    color: AppColors.accentPurple,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Audio Tracks & Subtitles',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Audio Language',
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 6),
              ...widget.movie.audioTracks.map((track) {
                final isSelected = _currentAudioTrack == track;
                return ListTile(
                  dense: true,
                  title: Text(
                    track,
                    style: TextStyle(
                      color: isSelected ? AppColors.accentPurple : Colors.white,
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.accentPurple,
                        )
                      : null,
                  onTap: () {
                    setState(() => _currentAudioTrack = track);
                    Navigator.pop(ctx);
                  },
                );
              }),
              const Divider(color: Colors.white12),
              const Text(
                'Subtitles / Closed Captions',
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 6),
              ...widget.movie.subtitles.map((sub) {
                final isSelected = _currentSubtitle == sub;
                return ListTile(
                  dense: true,
                  title: Text(
                    sub,
                    style: TextStyle(
                      color: isSelected ? AppColors.accentGreen : Colors.white,
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.accentGreen,
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
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDrawerState) {
            final activeSeason = widget.movie.seasons.firstWhere(
              (s) => s.seasonNumber == _currentSeasonNumber,
              orElse: () => widget.movie.seasons.isNotEmpty
                  ? widget.movie.seasons.first
                  : const MovieSeason(
                      seasonNumber: 1,
                      title: 'Season 1',
                      episodes: [],
                    ),
            );

            return Container(
              height: MediaQuery.of(context).size.height * 0.8,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${widget.movie.title} • Episodes',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Season Selection Chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: widget.movie.seasons.map((s) {
                        final isSel = s.seasonNumber == _currentSeasonNumber;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(s.title),
                            selected: isSel,
                            selectedColor: const Color(0xFF00ADB5),
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
                  const SizedBox(height: 14),

                  // Episode List
                  Expanded(
                    child: ListView.builder(
                      itemCount: activeSeason.episodes.length,
                      itemBuilder: (context, idx) {
                        final ep = activeSeason.episodes[idx];
                        final isSelected =
                            ep.episodeNumber == _currentEpisodeNumber;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: Material(
                            color: isSelected
                                ? const Color(0xFF00ADB5).withValues(alpha: 0.2)
                                : Colors.black26,
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
                                  color: Colors.black38,
                                ),
                                child: isSelected
                                    ? const Center(
                                        child: Icon(
                                          Icons.play_arrow_rounded,
                                          color: Colors.white,
                                        ),
                                      )
                                    : null,
                              ),
                              title: Text(
                                'E${ep.episodeNumber}: ${ep.title}',
                                style: TextStyle(
                                  color: isSelected
                                      ? const Color(0xFF00ADB5)
                                      : Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: Text(
                                '${ep.duration} • ${ep.synopsis}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white70,
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
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.hub_rounded, color: AppColors.accentGreen),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Providers / Servers (${reports.length} Found Across Installed Repos)',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Re-scan & test all providers',
                    icon: const Icon(
                      Icons.refresh_rounded,
                      color: AppColors.accentGold,
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
              const SizedBox(height: 6),
              Text(
                'Green = stream verified • Grey = untested • Red = known dead',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: reports.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
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
                        ? AppColors.accentGreen
                        : (isDead ? Colors.redAccent : Colors.white70);

                    return Material(
                      color: isSelected
                          ? AppColors.accentGreen.withValues(alpha: 0.18)
                          : Colors.white.withValues(alpha: 0.05),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        leading: Icon(
                          source.isFastBDIX
                              ? Icons.flash_on_rounded
                              : Icons.dns_rounded,
                          color: source.isFastBDIX
                              ? AppColors.accentGold
                              : healthColor,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                source.serverName,
                                style: TextStyle(
                                  color: isSelected
                                      ? AppColors.accentGreen
                                      : Colors.white,
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
                                  color: AppColors.accentGreen.withValues(
                                    alpha: 0.2,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${report.latencyMs}ms',
                                  style: const TextStyle(
                                    color: AppColors.accentGreen,
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
                                ? Colors.redAccent.withValues(alpha: 0.8)
                                : Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(
                                Icons.check_circle_rounded,
                                color: AppColors.accentGreen,
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
                              backgroundColor: AppColors.primary,
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

  void _launchSystemPlayer() {
    final url = _currentSource.streamUrl.isNotEmpty
        ? _currentSource.streamUrl
        : _currentSource.downloadUrl;
    if (url.isNotEmpty) {
      PlayerService.instance.launchSystemPlayer(url);
    }
  }
}
