import 'package:flutter/material.dart';
import '../services/player_service.dart';
import '../theme/app_colors.dart';
import 'remote_image.dart';

class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PlayerService.instance,
      builder: (context, _) {
        final player = PlayerService.instance;
        if (!player.hasMedia) return const SizedBox.shrink();

        final isDark = Theme.of(context).brightness == Brightness.dark;
        final progress = (player.currentSeconds / player.totalSeconds).clamp(0.0, 1.0);

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkCard : AppColors.lightCard,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
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
                    const SizedBox(width: 12),

                    // Title & duration
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            player.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${player.positionFormatted} / ${player.durationFormatted} • ${player.author}',
                            style: TextStyle(
                              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Open external player button
                    IconButton(
                      icon: const Icon(Icons.open_in_new_rounded, size: 20),
                      tooltip: 'Open in System Player',
                      onPressed: () {
                        player.launchSystemPlayer(player.filePath);
                      },
                    ),

                    // Play/Pause
                    IconButton(
                      icon: Icon(
                        player.isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                        color: AppColors.primary,
                        size: 32,
                      ),
                      onPressed: player.togglePlay,
                    ),

                    // Close
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20, color: Colors.grey),
                      onPressed: player.close,
                    ),
                  ],
                ),
              ),

              // Progress bar line
              ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
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
      color: AppColors.darkSurface,
      child: Icon(
        isAudio ? Icons.music_note_rounded : Icons.videocam_rounded,
        color: isAudio ? AppColors.accentGold : AppColors.primary,
        size: 24,
      ),
    );
  }
}
