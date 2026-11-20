import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../models/download_task.dart';
import '../models/video_item.dart';
import 'extractor_service.dart';
import 'stream_fallback_service.dart';

enum PlayerViewState {
  hidden,
  minimized,
  expanded,
}

class PlayerService extends ChangeNotifier {
  static final PlayerService instance = PlayerService._();
  PlayerService._();

  PlayerViewState _viewState = PlayerViewState.hidden;
  bool _isPlaying = false;
  String _title = '';
  String _author = '';
  String _thumbnailUrl = '';
  String _filePath = '';
  bool _isAudio = false;
  VideoItem? _currentItem;
  String _selectedQuality = '1080p';
  bool _isLooping = false;
  bool _isAudioOnly = false;
  String _aspectRatio = 'Fit'; // 'Fit', '16:9', 'Zoom', 'Fill'
  int? _sleepTimerMinutes;
  Timer? _sleepTimer;
  bool _isLocked = false;
  double _brightness = 0.75;

  double _currentSeconds = 0;
  double _totalSeconds = 210; // Default 3m30s
  double _playbackSpeed = 1.0;
  double _volume = 0.8;
  Timer? _playbackTimer;

  // Real playback engine. video_player decodes audio-only streams too, so the
  // same controller drives music playback. The Timer simulation below is kept
  // ONLY as a fallback for platforms/streams where no native engine exists
  // (e.g. Linux desktop, where initialize() throws UnimplementedError).
  VideoPlayerController? _engine;
  bool _engineActive = false;
  int _lastNotifiedSecond = -1; // Throttle engine-driven rebuilds to ~1/s.

  // True while a genuine full-length audio stream is being resolved (YouTube
  // search + manifest) instead of the short source-app preview.
  bool _isResolving = false;
  bool get isResolving => _isResolving;

  // True when full-length audio could not be resolved (e.g. the source is
  // unreachable or rate-limited). We surface a retry rather than pretend to
  // play the 30-second store preview.
  bool _resolveError = false;
  bool get resolveError => _resolveError;

  // Sequential / shuffled playback queue (used by Home & artist "Play All" and
  // "Shuffle All"). When a track finishes, the engine auto-advances the queue.
  final List<VideoItem> _queue = [];
  int _queueIndex = -1;
  bool get hasQueue => _queue.length > 1;
  int get queueIndex => _queueIndex;
  int get queueLength => _queue.length;

  PlayerViewState get viewState => _viewState;
  bool get isExpanded => _viewState == PlayerViewState.expanded;
  bool get isMinimized => _viewState == PlayerViewState.minimized;
  bool get isHidden => _viewState == PlayerViewState.hidden;
  bool get hasMedia => _title.isNotEmpty;
  bool get isPlaying => _isPlaying;
  String get title => _title;
  String get author => _author;
  String get thumbnailUrl => _thumbnailUrl;
  String get filePath => _filePath;
  bool get isAudio => _isAudio;
  VideoItem? get currentItem => _currentItem;
  String get selectedQuality => _selectedQuality;
  double get currentSeconds => _currentSeconds;
  double get totalSeconds => _totalSeconds;
  double get playbackSpeed => _playbackSpeed;
  double get volume => _volume;
  bool get isAdFree => true; // 100% Ad-Free Pure Experience
  VideoPlayerController? get engine => _engine;
  bool get isEngineActive => _engineActive && _engine != null && _engine!.value.isInitialized;
  bool get isLooping => _isLooping;
  bool get isAudioOnly => _isAudioOnly;
  String get aspectRatio => _aspectRatio;
  int? get sleepTimerMinutes => _sleepTimerMinutes;
  bool get isLocked => _isLocked;
  double get brightness => _brightness;

  String get positionFormatted {
    final s = _currentSeconds.toInt();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String get durationFormatted {
    final s = _totalSeconds.toInt();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void playVideoItem(VideoItem video, {bool isAudio = false}) {
    _currentItem = video;
    _title = video.title;
    _author = video.author;
    _thumbnailUrl = video.thumbnailUrl;
    _filePath = video.videoUrl;
    _isAudio = isAudio;
    _currentSeconds = 0;
    _totalSeconds = _parseDuration(video.duration) ?? 213;
    _isPlaying = true;
    _viewState = PlayerViewState.expanded; // Open YouTube-style popup
    notifyListeners();
    _beginPlaybackFor(video.videoUrl, originalUrl: video.videoUrl);
  }

  /// Feed the decoder something it can genuinely play. Search/feed items carry
  /// the WATCH PAGE url (`youtube.com/watch?v=…`), which ExoPlayer cannot open
  /// — that failure used to leave the timer faking progress while nothing
  /// moved ("it plays like audio, but nothing actually runs"). Mint a real
  /// muxed stream first, and on mobile surface an honest error instead of
  /// simulated playback when nothing playable exists.
  Future<void> _beginPlaybackFor(String media, {String? originalUrl}) async {
    var url = media;
    final isWatchPage = url.contains('youtube.com/watch') ||
        url.contains('youtu.be/');
    if (isWatchPage) {
      _isResolving = true;
      notifyListeners();
      String fresh = '';
      try {
        fresh =
            await ExtractorService.instance.resolvePlayableStream(url) ?? '';
      } catch (_) {}
      _isResolving = false;
      if (_currentItem?.videoUrl != originalUrl) return; // user switched
      if (fresh.isEmpty) {
        if (_hasNativeEngine) {
          _isPlaying = false;
          _resolveError = true;
          notifyListeners();
          return;
        }
      } else {
        _resolveError = false;
        _filePath = fresh;
        url = fresh;
        notifyListeners();
      }
    }
    final ok = await _startEngine(url);
    if (!ok &&
        isWatchPage &&
        _hasNativeEngine &&
        _isPlaying &&
        _currentItem?.videoUrl == originalUrl) {
      // Signed URLs can expire between mint and first byte — try once more
      // with a freshly minted stream.
      String fresh = '';
      try {
        fresh = await ExtractorService.instance
                .resolvePlayableStream(originalUrl!) ??
            '';
      } catch (_) {}
      if (fresh.isNotEmpty && _currentItem?.videoUrl == originalUrl) {
        _filePath = fresh;
        notifyListeners();
        await _startEngine(fresh);
      }
    }
  }

  /// Plays a queue of items (album / artist / shuffle). Tapping a track sets the
  /// whole list as the queue so play/pause, next/prev and auto-advance work.
  void playQueue(List<VideoItem> items, {int startIndex = 0, bool shuffle = false}) {
    if (items.isEmpty) return;
    _queue
      ..clear()
      ..addAll(items);
    if (shuffle) {
      _queue.shuffle();
      _queueIndex = 0;
    } else {
      _queueIndex = startIndex.clamp(0, items.length - 1);
    }
    playVideoItem(_queue[_queueIndex]);
  }

  void playNext() {
    if (_queue.isEmpty) return;
    _queueIndex = (_queueIndex + 1) % _queue.length;
    playVideoItem(_queue[_queueIndex]);
  }

  void playPrevious() {
    if (_queue.isEmpty) return;
    _queueIndex = (_queueIndex - 1 + _queue.length) % _queue.length;
    playVideoItem(_queue[_queueIndex]);
  }

  void playDownloadTask(DownloadTask task) {
    // Images must never be passed to the video playback engine
    if (task.isImageTask) {
      if (task.savePath != null && task.savePath!.isNotEmpty) {
        launchSystemPlayer(task.savePath!);
      }
      return;
    }

    _currentItem = null;
    _title = task.title;
    _author = task.author;
    _thumbnailUrl = task.thumbnailUrl;
    _filePath = task.savePath ?? '';
    _isAudio = task.isAudioTask;
    _currentSeconds = 0;
    _totalSeconds = 210;
    _isPlaying = true;
    _isResolving = false;
    _resolveError = false;
    _viewState = PlayerViewState.expanded;
    notifyListeners();

    // If file exists on Linux, offer direct external player launch
    if (Platform.isLinux && _filePath.isNotEmpty && File(_filePath).existsSync()) {
      launchSystemPlayer(_filePath);
    }
    _startEngine(_filePath);
  }

  /// Starts real decoding/playback for the current media URL or file path.
  /// Returns true only when the native engine actually initialized and began
  /// playing. On platforms that have no decoder at all (Linux/Windows desktop)
  /// the Timer simulation keeps the UI alive; on Android/iOS a failure is
  /// surfaced to the caller instead of masquerading as playback (which used to
  /// advance the timer while producing zero sound).
  Future<bool> _startEngine(String pathOrUrl) async {
    await _disposeEngine();
    final media = pathOrUrl.trim();
    if (media.isEmpty) return false;

    try {
      // streamHeadersFor already hands googlevideo URLs the exact minting
      // client UA (read off the URL), so no YouTube special-case is needed.
      final Map<String, String> headers =
          StreamFallbackService.streamHeadersFor(media);

      final controller = media.startsWith('http')
          ? VideoPlayerController.networkUrl(
              Uri.parse(media),
              httpHeaders: headers,
            )
          : VideoPlayerController.file(File(media));
      _engine = controller;
      await controller.initialize().timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException('Stream took too long'),
          );
      if (!identical(controller, _engine)) {
        // A newer track was selected while we were initializing.
        await controller.dispose();
        return false;
      }
      controller.setVolume(_volume);
      controller.setPlaybackSpeed(_playbackSpeed);
      final dur = controller.value.duration.inMilliseconds / 1000.0;
      if (dur > 0) _totalSeconds = dur;
      controller.addListener(_engineListener);
      await controller.play();
      _engineActive = true;
      _lastNotifiedSecond = -1; // Force first position update to repaint.
      _playbackTimer?.cancel(); // Engine drives progress now; stop simulation.
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('PlayerService engine init failed: $e');
      _engineActive = false;
      await _disposeEngine();
      // Only fall back to the Timer simulation where there is genuinely no
      // native decoder (desktop). On mobile the caller must handle the failure.
      if (!_hasNativeEngine && _isPlaying) _startTimer();
      notifyListeners();
      return false;
    }
  }

  /// True on platforms where video_player has a real engine (ExoPlayer /
  /// AVPlayer). Desktop has none, so playback there legitimately falls back.
  bool get _hasNativeEngine => Platform.isAndroid || Platform.isIOS;

  void _engineListener() {
    final controller = _engine;
    if (controller == null || !controller.value.isInitialized) return;

    _currentSeconds = controller.value.position.inMilliseconds / 1000.0;
    final dur = controller.value.duration.inMilliseconds / 1000.0;
    if (dur > 0) _totalSeconds = dur;

    bool playingChanged = false;
    if (!controller.value.isPlaying && _isPlaying && _currentSeconds >= _totalSeconds - 0.5) {
      if (_isLooping) {
        seek(0);
        controller.play();
        _isPlaying = true;
        notifyListeners();
        return;
      }
      _isPlaying = false; // Reached end of track.
      playingChanged = true;
      // Auto-advance a queued/shuffled playlist once the current item ends.
      if (_queue.length > 1) {
        Timer(const Duration(milliseconds: 200), playNext);
      }
    } else if (_isPlaying != controller.value.isPlaying) {
      _isPlaying = controller.value.isPlaying;
      playingChanged = true;
    }

    // video_player emits position updates far more often than the UI needs
    // (can be dozens of times per second). Rebuilding on every tick causes
    // heavy layout churn; only notify when the visible second or play state
    // actually changes (~1/s), which keeps the tree stable.
    final wholeSeconds = _currentSeconds ~/ 1;
    if (playingChanged || wholeSeconds != _lastNotifiedSecond) {
      _lastNotifiedSecond = wholeSeconds;
      notifyListeners();
    }
  }

  Future<void> _disposeEngine() async {
    _engineActive = false;
    final controller = _engine;
    _engine = null;
    if (controller != null) {
      controller.removeListener(_engineListener);
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  double? _parseDuration(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length < 2) return null;
    final nums = parts.map((p) => int.tryParse(p.trim())).toList();
    if (nums.any((n) => n == null)) return null;
    if (nums.length == 2) return (nums[0]! * 60 + nums[1]!).toDouble();
    if (nums.length == 3) return (nums[0]! * 3600 + nums[1]! * 60 + nums[2]!).toDouble();
    return null;
  }

  void minimize() {
    _viewState = PlayerViewState.minimized;
    notifyListeners();
  }

  void expand() {
    if (hasMedia) {
      _viewState = PlayerViewState.expanded;
      notifyListeners();
    }
  }

  void setQuality(String quality) {
    _selectedQuality = quality;
    notifyListeners();
  }

  void skip(double deltaSeconds) {
    seek(_currentSeconds + deltaSeconds);
  }

  void togglePlay() {
    _isPlaying = !_isPlaying;
    if (_engineActive && _engine != null && _engine!.value.isInitialized) {
      if (_isPlaying) {
        _engine!.play();
      } else {
        _engine!.pause();
      }
    } else {
      if (_isPlaying) {
        _startTimer();
      } else {
        _playbackTimer?.cancel();
      }
    }
    notifyListeners();
  }

  void seek(double seconds) {
    _currentSeconds = seconds.clamp(0.0, _totalSeconds);
    if (_engineActive && _engine != null && _engine!.value.isInitialized) {
      _engine!.seekTo(Duration(milliseconds: (_currentSeconds * 1000).toInt()));
    }
    notifyListeners();
  }

  void setSpeed(double speed) {
    _playbackSpeed = speed;
    if (_engineActive && _engine != null && _engine!.value.isInitialized) {
      _engine!.setPlaybackSpeed(speed);
    }
    notifyListeners();
  }

  void setVolume(double vol) {
    _volume = vol.clamp(0.0, 1.0);
    if (_engineActive && _engine != null && _engine!.value.isInitialized) {
      _engine!.setVolume(_volume);
    }
    notifyListeners();
  }

  void toggleLoop() {
    _isLooping = !_isLooping;
    if (_engineActive && _engine != null) {
      _engine!.setLooping(_isLooping);
    }
    notifyListeners();
  }

  void toggleAudioOnly() {
    _isAudioOnly = !_isAudioOnly;
    notifyListeners();
  }

  void setAspectRatio(String mode) {
    _aspectRatio = mode;
    notifyListeners();
  }

  void setSleepTimer(int? minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerMinutes = minutes;
    if (minutes != null && minutes > 0) {
      _sleepTimer = Timer(Duration(minutes: minutes), () {
        if (_isPlaying) togglePlay();
        _sleepTimerMinutes = null;
        _sleepTimer = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void toggleLock() {
    _isLocked = !_isLocked;
    notifyListeners();
  }

  void setBrightness(double b) {
    _brightness = b.clamp(0.0, 1.0);
    notifyListeners();
  }

  void close() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerMinutes = null;
    _isLocked = false;
    _isAudioOnly = false;
    _playbackTimer?.cancel();
    _disposeEngine();
    _queue.clear();
    _queueIndex = -1;
    _isPlaying = false;
    _isResolving = false;
    _resolveError = false;
    _title = '';
    _currentItem = null;
    _viewState = PlayerViewState.hidden;
    notifyListeners();
  }

  void _startTimer() {
    _playbackTimer?.cancel();
    if (_engineActive) return; // Real engine drives progress; no simulation needed.
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) {
      if (_isPlaying) {
        _currentSeconds += _playbackSpeed;
        if (_currentSeconds >= _totalSeconds) {
          if (_isLooping) {
            _currentSeconds = 0;
          } else {
            _currentSeconds = _totalSeconds;
            _isPlaying = false;
            timer.cancel();
          }
        }
        notifyListeners();
      }
    });
  }

  // Open with system media player (vlc, mpv, ffplay, xdg-open, default app)
  Future<void> launchSystemPlayer(String pathOrUrl) async {
    final url = pathOrUrl.trim();
    if (url.isEmpty) return;

    try {
      if (Platform.isLinux) {
        if (File('/usr/bin/vlc').existsSync()) {
          Process.start('/usr/bin/vlc', [url]);
          return;
        }
        if (File('/usr/bin/mpv').existsSync()) {
          Process.start('/usr/bin/mpv', ['--force-window=immediate', url]);
          return;
        }
        if (File('/usr/bin/ffplay').existsSync()) {
          Process.start('/usr/bin/ffplay', ['-autoexit', url]);
          return;
        }
        Process.start('xdg-open', [url]);
        return;
      }

      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(uri);
      }
    } catch (_) {
      try {
        final uri = Uri.parse(url);
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }
}
