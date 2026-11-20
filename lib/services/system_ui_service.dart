import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps the OS bottom navigation/gesture bar hidden so the app's own floating
/// navigation pill is the only bar at the bottom of the screen.
class SystemUiService with WidgetsBindingObserver {
  SystemUiService._();

  static final SystemUiService instance = SystemUiService._();

  static const MethodChannel _channel = MethodChannel(
    'snaptube_pure/system_ui',
  );

  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    hideBottomBar();
  }

  Future<void> hideBottomBar() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('hideNavigationBar');
    } catch (_) {
      // Older Android builds may not expose the channel — Flutter's
      // SystemUiMode.manual setting in main() is the fallback there.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(hideBottomBar());
  }
}
