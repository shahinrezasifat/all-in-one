import 'package:flutter/material.dart';
import '../services/player_service.dart';
import '../theme/app_palette.dart';
import 'remote_image.dart';

class MiniPlayerBar extends StatelessWidget {
  MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PlayerService.instance,
      builder: (context, _) {
        final player = PlayerService.instance;
        if (!player.hasMedia) return SizedBox.shrink();

        final isDark = Theme.of(context).brightness == Brightness.dark;
        final progress = (player.currentSeconds / player.totalSeconds).clamp(0.0, 1.0);

        return Container(
          margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: context.palette.card,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: context.palette.shadowAt(isDark ? 0.35 : 0.08),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(8),
                child: Row(
                  children: [
                    // Media thumbnail
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: player.thumbnailUrl.isNotEmpty
                          ? SmartNetworkImage(
                              url: player.thumbnailUrl,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                            )
                          : _buildPlaceholder(player.isAudio),
                    ),
                    SizedBox(width: 12),

                    // Title & duration
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            player.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          SizedBox(height: 2),
                          Text(
                            '${player.positionFormatted} / ${player.durationFormatted} • ${player.author}',
                            style: TextStyle(
                              color: context.palette.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Open external player button
                    IconButton(
                      icon: Icon(Icons.open_in_new_rounded, size: 20),
                      tooltip: 'Open in System Player',
                      onPressed: () {
                        player.launchSystemPlayer(player.filePath);
                      },
                    ),

                    // Play/Pause
                    IconButton(
                      icon: Icon(
                        player.isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                        color: context.palette.primary,
                        size: 32,
                      ),
                      onPressed: player.togglePlay,
                    ),

                    // Close
                    IconButton(
                      icon: Icon(Icons.close_rounded, size: 20, color: context.palette.onPrimary),
                      onPressed: player.close,
                    ),
                  ],
                ),
              ),

              // Progress bar line
              ClipRRect(
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(context.palette.primary),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaceholder(bool isAudio) {
    return Container(
      width: 48,
      height: 48,
      color: AppPalette.current.surface,
      child: Icon(
        isAudio ? Icons.music_note_rounded : Icons.videocam_rounded,
        color: isAudio ? AppPalette.current.info : AppPalette.current.primary,
        size: 24,
      ),
    );
  }
}
