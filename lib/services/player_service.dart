import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/download_task.dart';
import '../models/extract_result.dart';
import '../models/video_item.dart';
import 'extractor_service.dart';
import 'media_mux_service.dart';
import 'mpv_controller.dart';
import 'playback_controls.dart';
import 'stream_fallback_service.dart';

enum PlayerViewState { hidden, minimized, expanded }

class PlayerService extends ChangeNotifier {
  static final PlayerService instance = PlayerService._();

  /// The one and only playback engine: libmpv (mpvExtended's engine).
  final MpvController mpv = MpvController();

  PlayerService._() {
    mpv.addListener(_engineListener);
  }

  PlayerViewState _viewState = PlayerViewState.hidden;
  bool _isPlaying = false;
  String _title = '';
  String _author = '';
  String _thumbnailUrl = '';
  String _filePath = '';
  String _originalMediaUrl = '';
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

  // libmpv drives all video playback. The Timer simulation below is kept ONLY
  // as a fallback for platforms with no native engine (desktop), and Android
  // audio-only playback still uses its dedicated background service.
  bool _engineActive = false;
  final _playbackControls = PlaybackControls();
  static const _background = MethodChannel('snaptube_pure/background');
  int _playbackRequest = 0;
  Timer? _audioUpdates;
  bool _nativeAudio = false;
  bool _audioStarted = false;
  bool _audioReadInProgress = false;
  Map<String, String> _sourceHeaders = const {};
  String? _sourceMimeType;
  bool _privateMedia = false;
  int _lastNotifiedSecond = -1; // Throttle engine-driven rebuilds to ~1/s.

  // Real, discovered playback options for the current YouTube video. Quality
  // and spoken-audio changes use these rather than just relabelling the UI.
  List<MediaFormat> _availableQualities = const [];
  List<AudioLanguageOption> _audioLanguages = const [];
  String? _selectedAudioTrackId;
  bool _isSwitchingSource = false;
  double _switchProgress = 0;
  String? _switchingError;
  final List<Directory> _playbackTempDirs = [];

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

  /// The public source for format discovery, independent of the decoder URL.
  String? get downloadSourceUrl {
    final url = _originalMediaUrl.trim();
    final uri = Uri.tryParse(url);
    if (_privateMedia ||
        uri == null ||
        uri.host.isEmpty ||
        !const {'http', 'https'}.contains(uri.scheme)) {
      return null;
    }
    return url;
  }

  bool get isAudio => _isAudio;
  VideoItem? get currentItem => _currentItem;
  String get selectedQuality => _selectedQuality;

  /// Qualities the source actually publishes for this video.
  List<MediaFormat> get availableQualities =>
      List.unmodifiable(_availableQualities);

  /// Dubbed/original spoken tracks (empty for single-audio videos).
  List<AudioLanguageOption> get audioLanguages =>
      List.unmodifiable(_audioLanguages);
  String? get selectedAudioTrackId => _selectedAudioTrackId;
  bool get hasMultipleAudioTracks => _audioLanguages.length > 1;
  bool get isSwitchingSource => _isSwitchingSource;
  double get switchProgress => _switchProgress;
  String? get switchingError => _switchingError;
  double get currentSeconds => _currentSeconds;
  double get totalSeconds => _totalSeconds;
  double get playbackSpeed => _playbackSpeed;
  double get volume => _volume;
  bool get isAdFree => true; // 100% Ad-Free Pure Experience
  bool get isEngineActive => _engineActive;
  bool get isLooping => _isLooping;
  bool get isAudioOnly => _isAudioOnly;
  bool get isAudioView => _isAudio || _isAudioOnly;
  bool get canReturnToVideo => _isAudioOnly && !_isAudio;
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

  void playVideoItem(
    VideoItem video, {
    bool isAudio = false,
    bool audioOnly = false,
    Map<String, String> headers = const {},
    String? mimeType,
    Duration position = Duration.zero,
  }) {
    final request = ++_playbackRequest;
    _playbackTimer?.cancel();
    unawaited(_disposeEngine());
    _isResolving = false;
    _resolveError = false;
    _isAudioOnly = audioOnly;
    _sourceHeaders = headers;
    _sourceMimeType = mimeType;
    _privateMedia = video.platform == 'Vault';
    _currentItem = video;
    _title = video.title;
    _author = video.author;
    _thumbnailUrl = video.thumbnailUrl;
    _originalMediaUrl = video.videoUrl;
    _filePath = video.videoUrl;
    _isAudio = isAudio;
    _currentSeconds = position.inMilliseconds / 1000;
    _totalSeconds = _parseDuration(video.duration) ?? 213;
    _isPlaying = true;
    _viewState = PlayerViewState.expanded; // Open YouTube-style popup
    notifyListeners();
    unawaited(_beginPlaybackFor(video.videoUrl, request: request));
  }

  /// Feed the decoder something it can genuinely play. Search/feed items carry
  /// the WATCH PAGE url (`youtube.com/watch?v=…`), which ExoPlayer cannot open
  /// — that failure used to leave the timer faking progress while nothing
  /// moved ("it plays like audio, but nothing actually runs"). Mint a real
  /// muxed stream first, and on mobile surface an honest error instead of
  /// simulated playback when nothing playable exists.
  Future<void> _beginPlaybackFor(
    String originalUrl, {
    required int request,
  }) async {
    var url = originalUrl;
    final isWatchPage =
        url.contains('youtube.com/watch') || url.contains('youtu.be/');
    if (isWatchPage) {
      _isResolving = true;
      notifyListeners();
      try {
        url = await ExtractorService.instance.resolvePlayableStream(url) ?? '';
      } on Exception {
        url = '';
      }
      if (request != _playbackRequest) return;
      _isResolving = false;
      if (url.isNotEmpty) _filePath = url;
      // Discover the formats and spoken languages this video really offers so
      // the quality/audio menus can offer working switches, not dummy labels.
      unawaited(_loadPlaybackOptions(originalUrl, request));
    }

    var started = await _startEngine(url, request);
    if (!started &&
        isWatchPage &&
        _hasNativeEngine &&
        request == _playbackRequest) {
      try {
        final fresh = await ExtractorService.instance.resolvePlayableStream(
          originalUrl,
        );
        if (request != _playbackRequest) return;
        if (fresh != null && fresh.isNotEmpty) {
          _filePath = fresh;
          started = await _startEngine(fresh, request);
        }
      } on Exception catch (error) {
        debugPrint('Playback retry failed: $error');
      }
    }
    if (!started && request == _playbackRequest && _hasNativeEngine) {
      _isPlaying = false;
      _resolveError = true;
      notifyListeners();
    }
  }

  /// Plays a queue of items (album / artist / shuffle). Tapping a track sets the
  /// whole list as the queue so play/pause, next/prev and auto-advance work.
  void playQueue(
    List<VideoItem> items, {
    int startIndex = 0,
    bool shuffle = false,
  }) {
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

    final request = ++_playbackRequest;
    _queue.clear();
    _queueIndex = -1;
    _playbackTimer?.cancel();
    unawaited(_disposeEngine());
    _sourceHeaders = const {};
    _sourceMimeType = null;
    _privateMedia = false;
    _isAudioOnly = false;
    _currentItem = null;
    _title = task.title;
    _author = task.author;
    _thumbnailUrl = task.thumbnailUrl;
    _originalMediaUrl = task.originalUrl;
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
    if (!_isAudio &&
        Platform.isLinux &&
        _filePath.isNotEmpty &&
        File(_filePath).existsSync()) {
      launchSystemPlayer(_filePath);
    }
    unawaited(_beginPlaybackFor(_filePath, request: request));
  }

  /// Starts real decoding/playback for the current media URL or file path.
  /// Returns true only when the native engine actually initialized and began
  /// playing. On platforms that have no decoder at all (Linux/Windows desktop)
  /// the Timer simulation keeps the UI alive; on Android/iOS a failure is
  /// surfaced to the caller instead of masquerading as playback (which used to
  /// advance the timer while producing zero sound).
  Future<bool> _startEngine(String pathOrUrl, int request) async {
    final media = pathOrUrl.trim();
    if (request != _playbackRequest || media.isEmpty) return false;
    final headers = {
      ...StreamFallbackService.streamHeadersFor(media),
      ..._sourceHeaders,
    };
    if (Platform.isAndroid && isAudioView) {
      return _startBackgroundAudio(media, headers, request);
    }
    if (!_hasNativeEngine) return false;

    // libmpv detects HLS/DASH/progressive files itself, so no format hint or
    // pre-initialisation is needed. It also receives the provider's headers.
    _engineActive = false;
    await mpv.load(
      path: media,
      headers: headers,
      position: _currentSeconds,
      isLive: false,
    );
    if (request != _playbackRequest) return false;
    await mpv.setVolume(_volume);
    await mpv.setSpeed(_playbackSpeed);
    await mpv.setOption('loop-file', _isLooping ? 'inf' : 'no');
    _engineActive = true;
    _lastNotifiedSecond = -1;
    _playbackTimer?.cancel();
    notifyListeners();
    return true;
  }

  Future<bool> _startBackgroundAudio(
    String media,
    Map<String, String> headers,
    int request,
  ) async {
    _nativeAudio = true;
    _audioStarted = false;
    _isResolving = true;
    notifyListeners();
    try {
      await _background.invokeMethod<void>('audioOpen', {
        'path': media,
        'headers': headers,
        'mimeType': _sourceMimeType,
        'title': _privateMedia ? 'Private audio' : _title,
        'token': request,
        'position': (_currentSeconds * 1000).round(),
        'speed': _playbackSpeed,
        'volume': _volume,
        'loop': _isLooping,
        'play': _isPlaying,
      });
      if (request != _playbackRequest) return false;
      final opened = DateTime.now();
      _audioUpdates = Timer.periodic(const Duration(milliseconds: 500), (_) {
        unawaited(_readBackgroundAudio(request, opened));
      });
      return true;
    } on Exception catch (error) {
      if (request != _playbackRequest) return false;
      debugPrint('Background audio could not start: $error');
      _nativeAudio = false;
      _isResolving = false;
      return false;
    }
  }

  Future<void> _readBackgroundAudio(int request, DateTime opened) async {
    if (_audioReadInProgress) return;
    _audioReadInProgress = true;
    try {
      final state = await _background.invokeMapMethod<String, Object?>(
        'audioState',
      );
      if (request != _playbackRequest) return;
      if (state == null || state['token'] != request) {
        if (_audioStarted) {
          close();
        } else if (DateTime.now().difference(opened) >
            const Duration(seconds: 10)) {
          await _disposeEngine();
          if (request != _playbackRequest) return;
          _isResolving = false;
          _isPlaying = false;
          _resolveError = true;
          notifyListeners();
        }
        return;
      }
      final newlyEnded = state['ended'] == true && _isPlaying;
      _audioStarted = true;
      _isResolving = state['buffering'] == true;
      _resolveError = state['error'] != null;
      _isPlaying = state['playing'] == true;
      final duration = (state['duration'] as num? ?? 0) / 1000;
      if (duration > 0) _totalSeconds = duration;
      _currentSeconds = (state['position'] as num? ?? 0) / 1000;
      notifyListeners();
      if (newlyEnded && _queue.length > 1) playNext();
    } on Exception catch (error) {
      debugPrint('Could not read background audio state: $error');
    } finally {
      _audioReadInProgress = false;
    }
  }

  Future<void> _controlBackgroundAudio(String control, num value) async {
    try {
      await _background.invokeMethod<void>('audioControl', {
        'control': control,
        'value': value,
      });
    } on Exception catch (error) {
      debugPrint('Could not control background audio: $error');
    }
  }

  /// libmpv is an Android player (mpvExtended is Android-only). On desktop the
  /// UI falls back to a timer, on iOS playback is explicitly unavailable.
  bool get _hasNativeEngine =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void _engineListener() {
    if (!_engineActive) return;
    final controller = mpv;

    unawaited(
      _playbackControls.keepScreenOn(
        !isAudioView && controller.error == null && controller.isPlaying,
      ),
    );
    _currentSeconds = controller.position;
    final dur = controller.duration;
    if (dur > 0) _totalSeconds = dur;
    if (controller.error != null) {
      _isPlaying = false;
      _resolveError = true;
      notifyListeners();
      return;
    }

    bool playingChanged = false;
    if (!controller.isPlaying &&
        _isPlaying &&
        _totalSeconds > 0 &&
        _currentSeconds >= _totalSeconds - 0.5) {
      if (_isLooping) {
        seek(0);
        unawaited(controller.play());
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
    } else if (_isPlaying != controller.isPlaying) {
      _isPlaying = controller.isPlaying;
      playingChanged = true;
    }

    // libmpv emits position updates far more often than the UI needs. Rebuild
    // only when the visible second or the play state actually changes.
    final wholeSeconds = _currentSeconds ~/ 1;
    if (playingChanged || wholeSeconds != _lastNotifiedSecond) {
      _lastNotifiedSecond = wholeSeconds;
      notifyListeners();
    }
  }

  Future<void> _disposeEngine() async {
    _engineActive = false;
    _audioUpdates?.cancel();
    _audioUpdates = null;
    if (_nativeAudio) {
      _nativeAudio = false;
      unawaited(_stopBackgroundAudio());
    }
    unawaited(_playbackControls.keepScreenOn(false));
    // The mpv controller is a singleton owned by PlayerService: pause it but
    // never dispose it here (the native surface is owned by the visible view).
    unawaited(mpv.pause());
  }

  Future<void> _stopBackgroundAudio() async {
    try {
      await _background.invokeMethod<Object?>('audioStop');
    } on Exception catch (error) {
      debugPrint('Could not stop background audio: $error');
    }
  }

  double? _parseDuration(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length < 2) return null;
    final nums = parts.map((p) => int.tryParse(p.trim())).toList();
    if (nums.any((n) => n == null)) return null;
    if (nums.length == 2) return (nums[0]! * 60 + nums[1]!).toDouble();
    if (nums.length == 3)
      return (nums[0]! * 3600 + nums[1]! * 60 + nums[2]!).toDouble();
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

  Future<void> _loadPlaybackOptions(String url, int request) async {
    try {
      final result = await ExtractorService.instance.extract(url);
      if (result == null ||
          request != _playbackRequest ||
          !result.platform.toLowerCase().contains('youtube')) {
        return;
      }
      final qualities = result.videoFormats
          .where((format) => format.type == MediaType.video)
          .toList();
      _availableQualities = qualities;
      _audioLanguages = result.audioLanguages;
      if (_selectedAudioTrackId == null) {
        _selectedAudioTrackId = result.audioLanguages
            .where((language) => language.isDefault)
            .map((language) => language.id)
            .firstOrNull;
      }
      notifyListeners();
    } catch (error) {
      debugPrint('Playback options unavailable: $error');
    }
  }

  /// Switch the actual stream, keeping the playback position. Returns false
  /// when the requested quality is not published for this video.
  Future<bool> setQuality(String label) async {
    if (_isSwitchingSource) return false;
    if (label == _selectedQuality && _engineActive) return true;
    return _switchSource(qualityLabel: label);
  }

  /// Change the spoken audio track while the video keeps playing.
  Future<bool> setAudioTrack(String trackId) async {
    if (_isSwitchingSource || trackId == _selectedAudioTrackId) return false;
    return _switchSource(audioTrackId: trackId);
  }

  Future<bool> _switchSource({
    String? qualityLabel,
    String? audioTrackId,
  }) async {
    final original = _originalMediaUrl;
    if (original.isEmpty || !_hasNativeEngine) return false;

    final request = ++_playbackRequest;
    final savedPosition = _currentSeconds;
    _isSwitchingSource = true;
    _switchProgress = 0;
    _switchingError = null;
    notifyListeners();

    try {
      final label = qualityLabel ?? _selectedQuality;
      late String media;
      if (label == 'Auto' && audioTrackId == null) {
        // Auto is the ready-to-play progressive stream — no download/merge.
        final progressive = await ExtractorService.instance
            .resolvePlayableStream(original);
        if (request != _playbackRequest) return false;
        if (progressive == null || progressive.isEmpty) {
          _switchingError = 'No playable stream is available for this video.';
          return false;
        }
        media = progressive;
      } else {
        final source = await ExtractorService.instance
            .resolveLiveVideoWithAudio(
              original,
              preferredLabel: label,
              audioTrackId: audioTrackId ?? _selectedAudioTrackId,
            );
        if (request != _playbackRequest) return false;
        if (source == null) {
          _switchingError = 'That quality is not available for this video.';
          return false;
        }
        media = source.videoUrl;
        if (source.needsMux) {
          final merged = await _muxForPlayback(source, request);
          if (merged == null) return false;
          media = merged;
        }
      }
      if (request != _playbackRequest) return false;

      if (qualityLabel != null) _selectedQuality = qualityLabel;
      if (audioTrackId != null) _selectedAudioTrackId = audioTrackId;
      _currentSeconds = savedPosition;
      _resolveError = false;
      _playbackTimer?.cancel();
      await _disposeEngine();
      _isSwitchingSource = false;
      _switchProgress = 1;
      notifyListeners();
      unawaited(_beginPlaybackFor(media, request: request));
      return true;
    } catch (error) {
      _switchingError = 'Could not switch the stream: $error';
      debugPrint('Playback source switch failed: $error');
      return false;
    } finally {
      _isSwitchingSource = false;
      notifyListeners();
    }
  }

  /// Adaptive video + a separate dub must be losslessly remuxed into one file
  /// before video_player can play them together with the chosen audio track.
  Future<String?> _muxForPlayback(LiveStreamSource source, int request) async {
    final audioUrl = source.audioUrl;
    if (audioUrl == null || audioUrl.isEmpty) return null;
    final dir = await Directory.systemTemp.createTemp('tub_playback_');
    _playbackTempDirs.add(dir);
    // Old muxed playback files are no longer needed once we switch again.
    for (final old
        in _playbackTempDirs.toList()
          ..removeWhere((element) => element.path == dir.path)) {
      try {
        old.deleteSync(recursive: true);
      } catch (_) {}
      _playbackTempDirs.remove(old);
    }
    final video = File('${dir.path}/video.${source.videoExt}');
    final audio = File('${dir.path}/audio.${source.audioExt ?? 'm4a'}');
    final output = File('${dir.path}/playback.mp4');
    final client = http.Client();
    try {
      for (final part in [(source.videoUrl, video), (audioUrl, audio)]) {
        final response = await client
            .get(Uri.parse(part.$1))
            .timeout(const Duration(seconds: 45));
        if (response.statusCode != 200) {
          throw StateError('Stream returned HTTP ${response.statusCode}');
        }
        await part.$2.writeAsBytes(response.bodyBytes);
        if (request != _playbackRequest) return null;
        _switchProgress = part.$1 == source.videoUrl ? .3 : .5;
        notifyListeners();
      }
      final result = await MediaMuxService.instance.merge(
        videoPath: video.path,
        audioPath: audio.path,
        outputPath: output.path,
        onProgress: (progress) {
          _switchProgress = .5 + (progress * .5);
          notifyListeners();
        },
      );
      if (!result.success) {
        _switchingError = result.error.isEmpty
            ? 'Could not prepare this stream.'
            : result.error;
        return null;
      }
      return output.path;
    } catch (error) {
      _switchingError = 'Could not prepare this stream: $error';
      return null;
    } finally {
      client.close();
    }
  }

  void skip(double deltaSeconds) {
    seek(_currentSeconds + deltaSeconds);
  }

  void togglePlay() {
    _isPlaying = !_isPlaying;
    if (_nativeAudio) {
      unawaited(_controlBackgroundAudio('play', _isPlaying ? 1 : 0));
    } else if (_engineActive) {
      if (_isPlaying) {
        unawaited(mpv.play());
      } else {
        unawaited(mpv.pause());
      }
    } else if (!_hasNativeEngine) {
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
    if (_nativeAudio) {
      unawaited(
        _controlBackgroundAudio('position', (_currentSeconds * 1000).round()),
      );
    } else if (_engineActive) {
      unawaited(mpv.seek(_currentSeconds));
    }
    notifyListeners();
  }

  void setSpeed(double speed) {
    _playbackSpeed = speed;
    if (_nativeAudio) {
      unawaited(_controlBackgroundAudio('speed', speed));
    } else if (_engineActive) {
      unawaited(mpv.setSpeed(speed));
    }
    notifyListeners();
  }

  void setVolume(double vol) {
    _volume = vol.clamp(0.0, 1.0);
    if (_nativeAudio) {
      unawaited(_controlBackgroundAudio('volume', _volume));
    } else if (_engineActive) {
      unawaited(mpv.setVolume(_volume));
    }
    notifyListeners();
  }

  void toggleLoop() {
    _isLooping = !_isLooping;
    if (_nativeAudio) {
      unawaited(_controlBackgroundAudio('loop', _isLooping ? 1 : 0));
    } else if (_engineActive) {
      unawaited(mpv.setOption('loop-file', _isLooping ? 'inf' : 'no'));
    }
    notifyListeners();
  }

  void toggleAudioOnly() {
    if (_isAudio || _isResolving) return;
    _isAudioOnly = !_isAudioOnly;
    // The current stream already carries the video's audio track. Switching
    // renderers keeps that source and its current position.
    _restartPlayback(_filePath);
  }

  void retryAudio() {
    if (!isAudioView || _isResolving) return;
    _isPlaying = true;
    _restartPlayback(_currentItem?.videoUrl ?? _filePath);
  }

  void _restartPlayback(String media) {
    _resolveError = false;
    final request = ++_playbackRequest;
    _playbackTimer?.cancel();
    unawaited(_disposeEngine());
    notifyListeners();
    unawaited(_beginPlaybackFor(media, request: request));
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
    _playbackRequest++;
    for (final dir in _playbackTempDirs) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
    _playbackTempDirs.clear();
    _availableQualities = const [];
    _audioLanguages = const [];
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerMinutes = null;
    _isLocked = false;
    _isAudio = false;
    _isAudioOnly = false;
    _playbackTimer?.cancel();
    _disposeEngine();
    _queue.clear();
    _queueIndex = -1;
    _isPlaying = false;
    _isResolving = false;
    _resolveError = false;
    mpv.cancelPendingNotifications();
    _title = '';
    _originalMediaUrl = '';
    _currentItem = null;
    _viewState = PlayerViewState.hidden;
    notifyListeners();
  }

  void _startTimer() {
    _playbackTimer?.cancel();
    if (_engineActive)
      return; // Real engine drives progress; no simulation needed.
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 1000), (
      timer,
    ) {
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
