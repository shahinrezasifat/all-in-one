import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A track reported by libmpv's `track-list` property.
class MpvTrack {
  final int id;
  final String type;
  final String codec;
  final String language;
  final String title;
  final bool selected;
  final bool defaultTrack;
  final int width;
  final int height;

  const MpvTrack({
    required this.id,
    required this.type,
    this.codec = '',
    this.language = '',
    this.title = '',
    this.selected = false,
    this.defaultTrack = false,
    this.width = 0,
    this.height = 0,
  });

  factory MpvTrack.fromJson(Map<String, dynamic> json) {
    return MpvTrack(
      id: (json['id'] as num?)?.toInt() ?? 0,
      type: json['type']?.toString() ?? '',
      codec: json['codec']?.toString() ?? '',
      language: json['lang']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      selected: json['selected'] == true,
      defaultTrack: json['default'] == true,
      width: (json['w'] as num?)?.toInt() ?? 0,
      height: (json['h'] as num?)?.toInt() ?? 0,
    );
  }

  String get label {
    final name = title.isNotEmpty
        ? title
        : language.isNotEmpty
        ? language
        : codec.isNotEmpty
        ? codec.toUpperCase()
        : 'Track $id';
    return name;
  }
}

/// Dart side of the libmpv bridge.
///
/// Android only (mpvExtended is an Android player). On every other platform
/// this controller reports an explicit unsupported error instead of silently
/// pretending to play.
class MpvController extends ChangeNotifier {
  static const MethodChannel _method = MethodChannel('snaptube_pure/mpv');
  static const EventChannel _event = EventChannel('snaptube_pure/mpv_events');

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool _ready = false;
  bool get isReady => _ready;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  bool _isBuffering = true;
  bool get isBuffering => _isBuffering;

  bool _eof = false;
  bool get isCompleted => _eof;

  double _position = 0;
  double get position => _position;

  double _duration = 0;
  double get duration => _duration;

  double _speed = 1;
  double get speed => _speed;

  double _volume = 1;
  double get volume => _volume;

  int _width = 0;
  int get width => _width;

  int _height = 0;
  int get height => _height;

  double _aspect = 0;
  double get aspect => _aspect;

  List<MpvTrack> _tracks = const [];
  List<MpvTrack> get tracks => _tracks;

  List<MpvTrack> get audioTracks =>
      _tracks.where((t) => t.type == 'audio').toList();

  List<MpvTrack> get subtitleTracks =>
      _tracks.where((t) => t.type == 'sub').toList();

  List<MpvTrack> get videoTracks =>
      _tracks.where((t) => t.type == 'video').toList();

  String? _error;
  String? get error => _error;

  StreamSubscription<dynamic>? _events;
  VoidCallback? _pendingLoad;
  Timer? _notifyTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  bool _notifyScheduled = false;
  bool _disposed = false;

  MpvController() {
    if (supported) {
      _events = _event.receiveBroadcastStream().listen(
        _onEvent,
        onError: (Object error) {
          _error = error.toString();
          _notify();
        },
      );
    }
  }

  /// Called from AndroidView.onPlatformViewCreated.
  void markReady() {
    if (_disposed || _ready) return;
    _ready = true;
    final pending = _pendingLoad;
    _pendingLoad = null;
    if (pending != null) pending();
    unawaited(refresh());
  }

  Future<void> load({
    required String path,
    Map<String, String> headers = const {},
    double position = 0,
    bool isLive = false,
  }) async {
    if (!supported) {
      _error = 'libmpv playback is only available on Android.';
      _notify();
      return;
    }
    if (!_ready) {
      _pendingLoad = () => unawaited(
        load(path: path, headers: headers, position: position, isLive: isLive),
      );
      return;
    }
    _error = null;
    _isBuffering = true;
    _eof = false;
    _position = position;
    _notify();
    try {
      final ok = await _method.invokeMethod<bool>('load', {
        'path': path,
        'headers': headers,
        'position': position,
        'isLive': isLive,
      });
      if (ok != true) throw StateError('libmpv rejected the stream');
    } catch (e) {
      _error = 'Could not open this stream: $e';
      _isBuffering = false;
      _notify();
    }
  }

  Future<void> refresh() async {
    if (!supported || !_ready) return;
    try {
      final state = await _method.invokeMethod<Map<dynamic, dynamic>>('getState');
      if (state == null) return;
      _applyState(state);
      _notify();
    } catch (_) {}
  }

  void _applyState(Map<dynamic, dynamic> state) {
    _position = (state['position'] as num?)?.toDouble() ?? _position;
    final duration = (state['duration'] as num?)?.toDouble() ?? 0;
    if (duration > 0) _duration = duration;
    _isPlaying = state['playing'] == true;
    _isBuffering = state['pausedForCache'] == true || state['seeking'] == true;
    _eof = state['eof'] == true;
    _speed = (state['speed'] as num?)?.toDouble() ?? _speed;
    _volume = (state['volume'] as num?)?.toDouble() ?? _volume;
    _width = (state['width'] as num?)?.toInt() ?? _width;
    _height = (state['height'] as num?)?.toInt() ?? _height;
    final aspect = (state['aspect'] as num?)?.toDouble() ?? 0;
    if (aspect > 0) _aspect = aspect;
    _parseTracks(state['tracks']);
  }

  void _onEvent(dynamic event) {
    if (_disposed || event is! Map) return;
    final type = event['type'];
    if (type == 'event') {
      // MPV_EVENT_END_FILE = 7. libmpv reports load failures here.
      if (event['id'] == 7) {
        final raw = event['value']?.toString();
        if (raw != null && raw.isNotEmpty) {
          try {
            final data = jsonDecode(raw) as Map<String, dynamic>;
            final error = data['error']?.toString();
            if (error != null &&
                error.isNotEmpty &&
                error.toLowerCase() != 'success') {
              _error = 'Stream failed: $error';
              _isBuffering = false;
            }
          } catch (_) {}
        }
      }
      unawaited(refresh());
      _notify();
      return;
    }
    if (type != 'property') return;

    final name = event['name']?.toString();
    final value = event['value'];
    switch (name) {
      case 'time-pos':
        _position = (value as num?)?.toDouble() ?? 0;
        break;
      case 'duration':
        final d = (value as num?)?.toDouble() ?? 0;
        if (d > 0) _duration = d;
        break;
      case 'pause':
        _isPlaying = value != true;
        break;
      case 'paused-for-cache':
      case 'seeking':
        _isBuffering = value == true;
        break;
      case 'eof-reached':
        _eof = value == true;
        break;
      case 'speed':
        _speed = (value as num?)?.toDouble() ?? _speed;
        break;
      case 'volume':
        _volume = (value as num?)?.toDouble() ?? _volume;
        break;
      case 'width':
        _width = (value as num?)?.toInt() ?? _width;
        break;
      case 'height':
        _height = (value as num?)?.toInt() ?? _height;
        break;
      case 'video-params/aspect':
        final a = (value as num?)?.toDouble() ?? 0;
        if (a > 0) _aspect = a;
        break;
      case 'track-list':
        _parseTracks(value);
        break;
      default:
        return;
    }
    _notify();
  }

  void _parseTracks(dynamic raw) {
    if (raw == null) return;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! List) return;
      _tracks = decoded
          .whereType<Map>()
          .map((e) => MpvTrack.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {}
  }

  void _notify() {
    if (_disposed) return;
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 80) {
      if (_notifyScheduled) return;
      _notifyScheduled = true;
      _notifyTimer?.cancel();
      _notifyTimer = Timer(const Duration(milliseconds: 90), () {
        if (_disposed) return;
        _notifyScheduled = false;
        _lastNotify = DateTime.now();
        notifyListeners();
      });
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }

  Future<void> play() => _call('play');
  Future<void> pause() => _call('pause');

  Future<void> togglePlay() async {
    if (!supported || !_ready) {
      _isPlaying = !_isPlaying;
      _notify();
      return;
    }
    try {
      final playing = await _method.invokeMethod<bool>('togglePause');
      if (playing != null) {
        _isPlaying = playing;
        _notify();
      }
    } catch (_) {}
  }

  Future<void> seek(double seconds, {bool absolute = true}) =>
      _call('seek', {'seconds': seconds, 'absolute': absolute});

  Future<void> skip(double delta) => seek(_position + delta);

  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.25, 4.0);
    _notify();
    await _call('setSpeed', {'speed': _speed});
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.5);
    _notify();
    await _call('setVolume', {'volume': _volume});
  }

  Future<void> selectTrack(String type, int id) =>
      _call('selectTrack', {'type': type, 'id': id});

  Future<void> setOption(String name, String value) =>
      _call('setOption', {'name': name, 'value': value});

  /// Fills the player surface edge-to-edge (no letterbox) and applies [zoom]
  /// (1.0 = fill, up to 3.0) on top of that baseline.
  Future<void> setZoom(double zoom) =>
      _call('setZoom', {'zoom': zoom.clamp(1.0, 3.0)});

  Future<void> screenshot() => _call('screenshot');

  /// Cancels the throttled rebuild timer. Useful when the owning service is
  /// closed (and in widget tests) so no timer outlives the player.
  void cancelPendingNotifications() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _notifyScheduled = false;
  }

  Future<void> _call(String method, [Map<String, Object>? args]) async {
    if (!supported || !_ready) return;
    try {
      await _method.invokeMethod<bool>(method, args);
    } catch (e) {
      _error = e.toString();
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingLoad = null;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _events?.cancel();
    _events = null;
    super.dispose();
  }
}
