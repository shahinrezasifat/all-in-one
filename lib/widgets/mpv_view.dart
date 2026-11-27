import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/mpv_controller.dart';

/// Hosts the libmpv native surface.
///
/// mpvExtended renders through libmpv's own `BaseMPVView`; on Flutter that view
/// is embedded as an Android platform view and all controls come from the
/// [MpvController] bridge.
class MpvVideoView extends StatelessWidget {
  final MpvController controller;
  final VoidCallback? onCreated;

  const MpvVideoView({
    super.key,
    required this.controller,
    this.onCreated,
  });

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'libmpv playback is only available on Android.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return AndroidView(
      viewType: 'snaptube_pure/mpv_view',
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (_) {
        controller.markReady();
        onCreated?.call();
      },
    );
  }
}
