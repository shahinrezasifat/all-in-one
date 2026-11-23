import 'package:flutter/material.dart';
import '../models/video_item.dart';
import '../services/channel_avatar_service.dart';
import '../services/player_service.dart';
import '../theme/app_palette.dart';
import 'analyze_download_flow.dart';
import 'remote_image.dart';

class VideoCard extends StatelessWidget {
  final VideoItem video;
  final bool isCompact;
  final bool isMultiSelect;
  final bool isSelected;
  final VoidCallback? onSelectToggle;
  final VoidCallback? onLongPress;

  VideoCard({
    super.key,
    required this.video,
    this.isCompact = false,
    this.isMultiSelect = false,
    this.isSelected = false,
    this.onSelectToggle,
    this.onLongPress,
  });

  Future<void> _handleDownload(BuildContext context) =>
      analyzeAndPickFormat(context, url: video.videoUrl);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isCompact) {
      return _buildCompact(context, isDark);
    }


    return Container(
      margin: EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: isSelected
            ? context.palette.tint(context.palette.primary, isDark ? 0.15 : 0.08)
            : (context.palette.card),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: isSelected
                ? context.palette.tint(context.palette.primary, 0.25)
                : context.palette.shadowAt(isDark ? 0.25 : 0.05),
            blurRadius: isSelected ? 16 : 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            if (isMultiSelect) {
              onSelectToggle?.call();
            } else {
              PlayerService.instance.playVideoItem(video);
            }
          },
          onLongPress: onLongPress ?? onSelectToggle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 16:9 Thumbnail
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: SmartNetworkImage(
                        url: video.thumbnailUrl,
                        fit: BoxFit.cover,
                        placeholderColor: context.palette.surface,
                        placeholderIcon: Icons.movie,
                        accentColor: context.palette.primary,
                      ),
                    ),
                  ),

                  // Selection Checkbox Badge when in Multi-Select Mode
                  if (isMultiSelect)
                    Positioned(
                      top: 10,
                      left: 10,
                      child: GestureDetector(
                        onTap: onSelectToggle,
                        child: AnimatedContainer(
                          duration: Duration(milliseconds: 200),
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected ? context.palette.primary : context.palette.textSecondary,
                            boxShadow: [
                              BoxShadow(
                                color: context.palette.shadowAt(0.4),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: isSelected
                              ? Icon(Icons.check_rounded, color: context.palette.onScrim, size: 18)
                              : null,
                        ),
                      ),
                    )
                  else
                    // Top-left Quality Badge Tag (4K UHD)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.palette.shadowAt(0.80),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.hd_rounded, color: context.palette.info, size: 13),
                            SizedBox(width: 3),
                            Text(
                              '4K UHD',
                              style: TextStyle(
                                color: context.palette.onScrim,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Top-right Quick Download Badge Button on Thumbnail (only if not multi-selecting)
                  if (!isMultiSelect)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _handleDownload(context),
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              gradient: context.palette.primaryGradient,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: context.palette.tint(context.palette.primary, 0.5),
                                  blurRadius: 8,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.download_rounded, color: context.palette.onScrim, size: 14),
                                SizedBox(width: 4),
                                Text(
                                  'Download',
                                  style: TextStyle(
                                    color: context.palette.onScrim,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Duration badge
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: context.palette.shadowAt(0.85),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        video.duration,
                        style: TextStyle(
                          color: context.palette.onScrim,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  // Play overlay (if not in multi select)
                  if (!isMultiSelect)
                    Positioned.fill(
                      child: Center(
                        child: Container(
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: context.palette.shadowAt(0.4),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.play_arrow_rounded, color: context.palette.onScrim, size: 32),
                        ),
                      ),
                    ),
                ],
              ),

              // Title and Channel Information
              Padding(
                padding: EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _channelAvatar(context, video),
                    SizedBox(width: 12),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            video.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              height: 1.25,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '${video.author} • ${video.views}',
                            style: TextStyle(
                              color: context.palette.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),

                    SizedBox(width: 8),

                    // Quick Free Download Button (if not in multi select mode)
                    if (!isMultiSelect)
                      Container(
                        decoration: BoxDecoration(
                          gradient: context.palette.primaryGradient,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: context.palette.tint(context.palette.primary, 0.35),
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _handleDownload(context),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.download_rounded, color: context.palette.onScrim, size: 18),
                                  SizedBox(width: 4),
                                  Text(
                                    '4K / MP3',
                                    style: TextStyle(
                                      color: context.palette.onScrim,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context, bool isDark) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isSelected
            ? context.palette.tint(context.palette.primary, 0.15)
            : (context.palette.card),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        onTap: () {
          if (isMultiSelect) {
            onSelectToggle?.call();
          } else {
            PlayerService.instance.playVideoItem(video);
          }
        },
        borderRadius: BorderRadius.circular(16),
        child: Row(
          children: [
            if (isMultiSelect)
              Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  color: isSelected ? context.palette.primary : context.palette.textSecondary,
                  size: 22,
                ),
              ),
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SmartNetworkImage(
                    url: video.thumbnailUrl,
                    width: 110,
                    height: 68,
                    fit: BoxFit.cover,
                    placeholderColor: context.palette.surface,
                    placeholderIcon: Icons.movie,
                    accentColor: context.palette.primary,
                  ),
                ),
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: context.palette.shadowAt(0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      video.duration,
                      style: TextStyle(color: context.palette.onScrim, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  SizedBox(height: 4),
                  Row(
                    children: [
                      _channelAvatar(context, video, size: 20),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          video.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: context.palette.textSecondary, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            if (!isMultiSelect)
              Container(
                decoration: BoxDecoration(
                  gradient: context.palette.primaryGradient,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: context.palette.tint(context.palette.primary, 0.4),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: IconButton(
                  icon: Icon(Icons.download_rounded, color: context.palette.onScrim, size: 20),
                  tooltip: 'Download',
                  onPressed: () => _handleDownload(context),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Original channel logo when YouTube exposes it; a palette-tinted initial
  /// stays as the offline/cache fallback.
  Widget _channelAvatar(BuildContext context, VideoItem video, {double size = 36}) {
    final p = context.palette;
    final initial = CircleAvatar(
      radius: size / 2,
      backgroundColor: p.tint(p.primary, 0.2),
      child: Text(
        video.author.isNotEmpty ? video.author[0].toUpperCase() : 'Y',
        style: TextStyle(
          color: p.primary,
          fontWeight: FontWeight.bold,
          fontSize: size * .39,
        ),
      ),
    );
    final known = video.channelAvatarUrl;
    if (known != null && known.isNotEmpty) {
      return ClipOval(
        child: SmartNetworkImage(
          url: known,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: initial,
        ),
      );
    }
    final channelId = video.channelId;
    if (channelId == null || channelId.isEmpty) return initial;
    return FutureBuilder<String?>(
      future: ChannelAvatarService.instance.avatarFor(channelId),
      builder: (context, snapshot) {
        final logo = snapshot.data;
        if (logo == null || logo.isEmpty) return initial;
        return ClipOval(
          child: SmartNetworkImage(
            url: logo,
            width: size,
            height: size,
            fit: BoxFit.cover,
            placeholder: initial,
          ),
        );
      },
    );
  }
}
