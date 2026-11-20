import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlaybackControls {
  static const _channel = MethodChannel('snaptube_pure/playback_controls');
  bool _adjustedBrightness = false;

  Future<double?> adjust({
    required bool brightness,
    required double delta,
    required bool first,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    if (!delta.isFinite) return null;
    if (brightness) _adjustedBrightness = true;
    try {
      return await _channel.invokeMethod<double>(
        brightness ? 'brightness' : 'volume',
        {'owner': identityHashCode(this), 'delta': delta, 'first': first},
      );
    } on Exception {
      return null;
    }
  }

  Future<void> restoreBrightness() async {
    if (!_adjustedBrightness) return;
    _adjustedBrightness = false;
    try {
      await _channel.invokeMethod<void>('restoreBrightness', {
        'owner': identityHashCode(this),
      });
    } on Exception {
      // Older platform implementations have no window override to restore.
    }
  }
}
