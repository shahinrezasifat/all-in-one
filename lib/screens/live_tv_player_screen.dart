import 'dart:async';

import '../services/playback_controls.dart';

import 'package:flutter/material.dart';
import '../theme/app_palette.dart';
import 'package:video_player/video_player.dart';

import '../models/movie_model.dart';

class LiveTvPlayerScreen extends StatefulWidget {
  LiveTvPlayerScreen({
    super.key,
    required this.channel,
    required this.resolve,
  });

  final MovieItem channel;
  final Future<List<MovieSource>> Function() resolve;

  @override
  State<LiveTvPlayerScreen> createState() => _LiveTvPlayerScreenState();
}

class _LiveTvPlayerScreenState extends State<LiveTvPlayerScreen> {
  VideoPlayerController? _player;
  final _playbackControls = PlaybackControls();

  void _syncScreenAwake() {
    final value = _player?.value;
    unawaited(_playbackControls.keepScreenOn(
      value != null && value.isPlaying && !value.hasError,
    ));
  }
  bool _loading = true;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  @override
  void dispose() {
    final player = _player;
    _player = null;
    _syncScreenAwake();
    player?.removeListener(_syncScreenAwake);
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    final previous = _player;
    setState(() {
      _player = null;
      _loading = true;
    });
    _syncScreenAwake();
    previous?.removeListener(_syncScreenAwake);
    await previous?.dispose();

    try {
      List<MovieSource> sources;
      try {
        sources = await widget.resolve().timeout(Duration(seconds: 25));
      } catch (_) {
        sources = [];
      }
      for (final source in sources) {
        if (!mounted) return;
        final uri = Uri.tryParse(
          source.streamUrl.isNotEmpty ? source.streamUrl : source.downloadUrl,
        );
        if (uri == null ||
            uri.host.isEmpty ||
            !['http', 'https'].contains(uri.scheme))
          continue;
        final format = source.format.toLowerCase();
        final controller = VideoPlayerController.networkUrl(
          uri,
          httpHeaders: source.headers,
          formatHint: format == 'm3u8'
              ? VideoFormat.hls
              : format == 'mpd'
              ? VideoFormat.dash
              : null,
        );
        var retained = false;
        try {
          await controller.initialize().timeout(Duration(seconds: 15));
          if (!mounted) return;
          await controller.play();
          if (!mounted) return;
          setState(() => _player = controller);
          controller.addListener(_syncScreenAwake);
          _syncScreenAwake();
          retained = true;
          return;
        } catch (_) {
          // A failed stream can still have another link from the same channel.
        } finally {
          if (!retained) await controller.dispose();
        }
      }
    } finally {
      _connecting = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      backgroundColor: context.palette.background,
      appBar: AppBar(
        backgroundColor: context.palette.background,
        foregroundColor: context.palette.card,
        title: Text(
          widget.channel.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: Center(
          child: _loading
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text(
                      'Connecting to live TV…',
                      style: TextStyle(color: context.palette.onScrim),
                    ),
                  ],
                )
              : player == null
              ? _unavailable()
              : ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: player,
                  builder: (context, value, _) {
                    if (value.hasError) return _unavailable();
                    return AspectRatio(
                      aspectRatio: value.aspectRatio,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          VideoPlayer(player),
                          if (value.isBuffering)
                            Center(child: CircularProgressIndicator()),
                          Positioned(
                            top: 10,
                            left: 12,
                            child: Chip(
                              label: Text('LIVE'),
                              side: BorderSide.none,
                            ),
                          ),
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: IconButton.filled(
                              tooltip: value.isPlaying ? 'Pause' : 'Play',
                              onPressed: value.isPlaying
                                  ? player.pause
                                  : player.play,
                              icon: Icon(
                                value.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Widget _unavailable() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'This channel is unavailable right now.',
        style: TextStyle(color: context.palette.onScrim),
      ),
      SizedBox(height: 12),
      FilledButton(onPressed: _connect, child: Text('Retry')),
    ],
  );
}
