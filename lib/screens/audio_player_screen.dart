import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import '../theme/app_palette.dart';

import '../services/player_service.dart';
import '../widgets/remote_image.dart';

class AudioPlayerScreen extends StatelessWidget {
  AudioPlayerScreen({super.key, this.returnToVideo});

  final VoidCallback? returnToVideo;

  @override
  Widget build(BuildContext context) {
    final player = PlayerService.instance;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && player.hasMedia && player.isAudioView) player.minimize();
      },
      child: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          if (!player.hasMedia) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted &&
                  ModalRoute.of(context)?.isCurrent == true) {
                Navigator.of(context).pop();
              }
            });
            return SizedBox.shrink();
          }
          return AudioPlayerView(
            player: player,
            onMinimize: () => Navigator.of(context).pop(),
            onClose: () {
              player.close();
              Navigator.of(context).pop();
            },
            onVideo: returnToVideo,
          );
        },
      ),
    );
  }
}

class AudioPlayerView extends StatelessWidget {
  AudioPlayerView({
    super.key,
    required this.player,
    required this.onMinimize,
    required this.onClose,
    this.onVideo,
  });

  final PlayerService player;
  final VoidCallback onMinimize;
  final VoidCallback onClose;
  final VoidCallback? onVideo;

  static final _background = AppPalette.current.background;
  static final _artBackground = AppPalette.current.background;
  static final _foreground = AppPalette.current.textPrimary;
  static final _muted = AppPalette.current.textSecondary;
  static final _accent = AppPalette.current.textSecondary;
  static final _outline = AppPalette.current.textSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        colorScheme: ColorScheme.dark(
          primary: _accent,
          onPrimary: _background,
          surface: _background,
          onSurface: _foreground,
        ),
        iconTheme: IconThemeData(color: _foreground),
      ),
      child: Scaffold(
        backgroundColor: _background,
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-0.65, -0.85),
              radius: 1.25,
              colors: [context.palette.tint(context.palette.primary, 0.10), context.palette.tint(context.palette.primary, 0.04), _background],
              stops: [0, 0.45, 1],
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final horizontal =
                    constraints.maxWidth >= 640 &&
                    constraints.maxWidth > constraints.maxHeight;
                final artworkSize = horizontal
                    ? (constraints.maxHeight - 104).clamp(152.0, 342.0)
                    : (constraints.maxHeight * .42).clamp(152.0, 342.0);
                final artwork = _buildArtwork(artworkSize);
                final controls = _buildControls(context);
                return Column(
                  children: [
                    _buildHeader(context),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, body) => SingleChildScrollView(
                          padding: EdgeInsets.fromLTRB(24, 16, 24, 24),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: (body.maxHeight - 40).clamp(
                                0.0,
                                double.infinity,
                              ),
                            ),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: horizontal ? 840 : 400,
                                ),
                                child: horizontal
                                    ? Row(
                                        children: [
                                          artwork,
                                          SizedBox(width: 40),
                                          Expanded(child: controls),
                                        ],
                                      )
                                    : Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          artwork,
                                          SizedBox(height: 28),
                                          controls,
                                        ],
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Row(
        children: [
          _headerButton(
            tooltip: 'Minimize audio',
            icon: Icons.keyboard_arrow_down_rounded,
            onPressed: onMinimize,
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Audio player',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(color: _foreground, fontWeight: FontWeight.w700),
            ),
          ),
          if (onVideo != null) ...[
            _headerButton(
              tooltip: 'Return to video',
              icon: Icons.videocam_outlined,
              onPressed: player.isResolving ? null : onVideo,
            ),
            SizedBox(width: 8),
          ],
          _headerButton(
            tooltip: 'Close audio',
            icon: Icons.close_rounded,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  Widget _headerButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: Size.square(48),
        foregroundColor: _foreground,
        backgroundColor: AppPalette.current.tint(AppPalette.current.card, 0.078),
        side: BorderSide(color: AppPalette.current.tint(AppPalette.current.card, 0.125)),
      ),
    );
  }

  Widget _buildArtwork(double size) {
    final borderRadius = BorderRadius.all(Radius.circular(28));
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: AppPalette.current.scrimAt(0.565),
            blurRadius: 32,
            offset: Offset(0, 14),
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(color: AppPalette.current.tint(AppPalette.current.card, 0.188)),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: SizedBox.square(
          dimension: size,
          child: SmartNetworkImage(
            url: player.thumbnailUrl,
            fit: BoxFit.cover,
            placeholder: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppPalette.current.primary, _artBackground],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Center(
                child: Icon(Icons.headphones_rounded, size: 80, color: _accent),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final duration = player.totalSeconds;
    final unavailable = player.isResolving || player.resolveError;
    final timeStyle = text.labelMedium?.copyWith(
      color: _muted,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          player.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: text.headlineSmall?.copyWith(
            color: _foreground,
            fontWeight: FontWeight.w700,
            height: 1.16,
          ),
        ),
        if (player.author.isNotEmpty) ...[
          SizedBox(height: 8),
          Text(
            player.author,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(color: _muted),
          ),
        ],
        SizedBox(height: 20),
        if (player.resolveError)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: player.retryAudio,
              icon: Icon(Icons.refresh_rounded),
              label: Text('Could not play this audio. Retry'),
            ),
          )
        else if (player.isResolving)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: LinearProgressIndicator(
              borderRadius: BorderRadius.all(Radius.circular(4)),
              semanticsLabel: 'Loading audio',
            ),
          )
        else
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: _accent,
              inactiveTrackColor: _outline,
              thumbColor: _accent,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
              padding: EdgeInsets.zero,
            ),
            child: Slider(
              value: player.currentSeconds.clamp(0.0, duration),
              max: duration > 0 ? duration : 1,
              onChanged: duration > 0 ? player.seek : null,
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(player.positionFormatted, style: timeStyle),
            Text(player.durationFormatted, style: timeStyle),
          ],
        ),
        SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: 'Back 10 seconds',
              onPressed: unavailable ? null : () => player.skip(-10),
              icon: Icon(Icons.replay_10_rounded),
            ),
            IconButton.filled(
              tooltip: player.isPlaying ? 'Pause audio' : 'Play audio',
              onPressed: unavailable ? null : player.togglePlay,
              style: IconButton.styleFrom(
                minimumSize: Size.square(72),
                backgroundColor: _accent,
                foregroundColor: _background,
              ),
              iconSize: 38,
              icon: Icon(
                player.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
            IconButton(
              tooltip: 'Forward 10 seconds',
              onPressed: unavailable ? null : () => player.skip(10),
              icon: Icon(Icons.forward_10_rounded),
            ),
            IconButton(
              tooltip: 'Repeat audio',
              onPressed: player.toggleLoop,
              isSelected: player.isLooping,
              style: IconButton.styleFrom(
                foregroundColor: player.isLooping ? _accent : _muted,
                backgroundColor: player.isLooping
                    ? context.palette.tint(context.palette.primary, 0.15)
                    : Colors.transparent,
              ),
              icon: Icon(Icons.repeat_rounded),
              selectedIcon: Icon(Icons.repeat_one_rounded),
            ),
          ],
        ),
      ],
    );
  }
}
