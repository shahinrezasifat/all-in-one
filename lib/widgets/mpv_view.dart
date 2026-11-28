import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/mpv_controller.dart';
import '../theme/app_palette.dart';

/// Hosts the libmpv native surface.
///
/// mpvExtended renders through libmpv's own `BaseMPVView`; on Flutter that view
/// is embedded as an Android platform view and all controls come from the
/// [MpvController] bridge.
class MpvVideoView extends StatefulWidget {
  const MpvVideoView({
    super.key,
    required this.controller,
    this.onCreated,
  });

  final MpvController controller;
  final VoidCallback? onCreated;

  @override
  State<MpvVideoView> createState() => _MpvVideoViewState();
}

class _MpvVideoViewState extends State<MpvVideoView> {
  /// Flutter recreates a platform view whenever `creationParams` changes.
  /// The player rebuilds on every mpv event (~12/s), so building a fresh map
  /// on each build destroyed and re-initialised libmpv continuously — the app
  /// hung and the surface kept detaching. Cache the params by palette key.
  Map<String, Object?>? _creationParams;
  String? _paletteKey;

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
    final p = context.palette;
    final key = '${p.videoScrim.toARGB32()}:${p.onVideoScrim.toARGB32()}';
    if (_creationParams == null || _paletteKey != key) {
      _paletteKey = key;
      _creationParams = <String, Object?>{
        'subBackColor':
            '#${p.videoScrim.withValues(alpha: .5).toARGB32().toRadixString(16).padLeft(8, '0')}',
        'subColor': '#${p.onVideoScrim.toARGB32().toRadixString(16).padLeft(8, '0')}',
        'fill': true,
      };
    }
    return AndroidView(
      viewType: 'snaptube_pure/mpv_view',
      creationParams: _creationParams,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (_) {
        widget.controller.markReady();
        widget.onCreated?.call();
      },
    );
  }
}
