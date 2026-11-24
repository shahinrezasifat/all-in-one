import 'dart:io';

import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../models/movie_model.dart';
import '../screens/audio_player_screen.dart';
import '../screens/movie_player_screen.dart';
import '../screens/vault_screen.dart';
import '../services/download_manager.dart';
import '../services/gallery_media_service.dart';
import '../services/player_service.dart';
import '../services/watch_history_service.dart';
import '../services/vault_service.dart';
import '../services/virtual_folder_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_palette.dart';
import 'image_viewer_dialog.dart';
import 'remote_image.dart';

class DownloadItemTile extends StatelessWidget {
  final DownloadTask task;

  const DownloadItemTile({super.key, required this.task});

  void _play(BuildContext context) {
    final path = task.savePath ?? '';
    final isVideo = !task.isAudioTask && !task.isImageTask;
    if (isVideo && path.isNotEmpty && File(path).existsSync()) {
      // Downloaded movies/series always open in the app's cinema player, with
      // the exact position the user last left — including per-episode history.
      final history = WatchHistoryService.instance.getProgress(task.id);
      final season = history?.seasonNumber ??
          int.tryParse(
            RegExp(r'\d+').firstMatch(task.seriesSeason ?? '')?.group(0) ?? '',
          ) ??
          1;
      final episode = history?.episodeNumber ?? 1;
      final source = MovieSource(
        serverName: 'Downloaded',
        resolution: task.formatLabel.isNotEmpty ? task.formatLabel : 'Original',
        downloadUrl: path,
        streamUrl: path,
        fileSize: '',
        format: task.ext.toLowerCase(),
      );
      final series = task.series;
      final movie = series != null
          ? series.copyWith(
              sources: [source],
              detailUrl: path,
              episodeUrl: task.seriesEpisodeUrl ?? '',
            )
          : MovieItem(
              id: task.id,
              title: task.title,
              posterUrl: task.thumbnailUrl,
              backdropUrl: task.thumbnailUrl,
              year: 0,
              rating: 0,
              quality: task.formatLabel,
              genres: const ['Downloaded'],
              type: 'movie',
              synopsis: '',
              duration: '',
              repoId: '',
              repoName: 'Downloads',
              detailUrl: path,
              sources: [source],
            );
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MoviePlayerScreen(
            movie: movie,
            initialSource: source,
            initialSeason: season,
            initialEpisode: episode,
            initialPositionSeconds: history?.positionSeconds ?? 0,
            downloadTaskId: task.id,
            liveSources: [source],
          ),
        ),
      );
      return;
    }
    PlayerService.instance.playDownloadTask(task);
    if (task.isAudioTask && ModalRoute.of(context)?.isFirst == false) {
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => AudioPlayerScreen()),
      );
    }
  }

  void _showFolderAssignDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final folders = VirtualFolderService.instance.folders;

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  Icon(Icons.folder_special_rounded, color: context.palette.primary),
                  SizedBox(width: 8),
                  Text(
                    'Assign to Virtual Folder',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ],
              ),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Organize "${task.title}" into custom playlists or folders:',
                      style: TextStyle(fontSize: 12, color: context.palette.onPrimary),
                    ),
                    SizedBox(height: 10),
                    ...folders.map((f) {
                      final isInFolder = f.taskIds.contains(task.id);
                      return CheckboxListTile(
                        dense: true,
                        title: Text(
                          f.name,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          '${f.taskIds.length} items',
                          style: TextStyle(fontSize: 11),
                        ),
                        value: isInFolder,
                        activeColor: context.palette.primary,
                        onChanged: (val) {
                          VirtualFolderService.instance.toggleItemInFolder(
                            f.id,
                            task.id,
                          );
                          setDialogState(() {});
                        },
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'Done',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// The one-tap LOCK: hides this finished download inside the Secret Vault.
  Future<void> _handleLockTap(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final vault = VaultService.instance;
    await vault.ready;

    if (!vault.hasPin) {
      // No PIN yet — offer setup, but keep the back button fully functional.
      final setup = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Set up the Secret Vault'),
          content: const Text(
            'Create a PIN first, then this download can be locked with one tap.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Set up PIN'),
            ),
          ],
        ),
      );
      if (setup == true && context.mounted) {
        await navigator.push(
          MaterialPageRoute(builder: (_) => const VaultScreen(standalone: true)),
        );
      }
      return;
    }

    final path = task.savePath;
    final file = (path == null || path.isEmpty) ? null : File(path);
    if (file == null || !file.existsSync()) {
      await DownloadManager.instance.removeTaskOnly(task);
      messenger.showSnackBar(
        SnackBar(
          content: Text('The file was already gone — removed from the list.'),
        ),
      );
      return;
    }

    try {
      await vault.lockTaskDirectly(task);
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text("Could not move the file to Vault")),
      );
      return;
    }

    GalleryMediaService.instance.removeThumbnailFor(
      task.title,
      downloadDirectory: DownloadManager.instance.downloadDirectory,
      isAudio: task.isAudio,
      category: task.category,
    );

    messenger.showSnackBar(
      SnackBar(
        backgroundColor: context.palette.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Row(
          children: [
            Icon(Icons.lock_rounded, color: context.palette.onPrimary, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                "\"${task.title}\" is now locked in the Secret Vault — it no longer appears in Downloads.",
                style: TextStyle(
                  color: context.palette.onPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static bool isDarkSafe(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  void _showActionSheet(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? context.palette.surface : context.palette.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4.5,
                decoration: BoxDecoration(
                  color: isDark ? context.palette.border : context.palette.tint(context.palette.border, 0.26),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            SizedBox(height: 14),
            Padding(
              padding: EdgeInsets.only(left: 6, bottom: 10),
              child: Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
                ),
              ),
            ),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: context.palette.card,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  _sheetAction(
                    icon: Icons.lock_rounded,
                    color: context.palette.primary,
                    title: 'Lock into Secret Vault',
                    subtitle: 'Hide this file — it leaves Downloads entirely',
                    isDark: isDark,
                    onTap: () {
                      Navigator.pop(ctx);
                      _handleLockTap(context);
                    },
                  ),
                  _sheetDivider(isDark),
                  _sheetAction(
                    icon: Icons.folder_special_rounded,
                    color: context.palette.primary,
                    title: 'Add to Virtual Folder',
                    subtitle: 'Organize this file into one of your folders',
                    isDark: isDark,
                    onTap: () {
                      Navigator.pop(ctx);
                      _showFolderAssignDialog(context);
                    },
                  ),
                  _sheetDivider(isDark),
                  _sheetAction(
                    icon: task.isImageTask
                        ? Icons.image_rounded
                        : (task.isAudioTask
                              ? Icons.music_note_rounded
                              : Icons.play_circle_rounded),
                    color: task.isImageTask
                        ? context.palette.secondary
                        : (task.isAudioTask
                              ? context.palette.success
                              : context.palette.info),
                    title: task.isImageTask
                        ? 'View Image'
                        : (task.isAudioTask ? 'Play Music' : 'Play Video'),
                    subtitle: 'Full preview or system player',
                    isDark: isDark,
                    onTap: () {
                      Navigator.pop(ctx);
                      if (task.isImageTask) {
                        ImageViewerDialog.show(context, task);
                      } else {
                        _play(context);
                      }
                    },
                  ),
                  _sheetDivider(isDark),
                  _sheetAction(
                    icon: Icons.delete_outline_rounded,
                    color: context.palette.textSecondary,
                    title: 'Delete File',
                    subtitle: 'Remove it from this device',
                    isDark: isDark,
                    onTap: () async {
                      Navigator.pop(ctx);
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Delete download?'),
                          content: Text(task.title),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext, false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext, true),
                              style: TextButton.styleFrom(foregroundColor: context.palette.critical),
                              child: const Text('Delete file'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        DownloadManager.instance.deleteTask(task);
                      }
                    },
                  ),
                ],
              ),
            ),
            SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: context.palette.card,
                  foregroundColor: isDark ? context.palette.textSecondary : context.palette.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Cancel',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetAction({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: color, size: 19),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppPalette.current.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: AppPalette.current.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetDivider(bool isDark) {
    return Divider(
      height: 1,
      indent: 60,
      color: isDark ? AppPalette.current.tint(AppPalette.current.onScrim, 0.12) : AppPalette.current.tint(AppPalette.current.border, 0.12),
    );
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  /// Human-friendly source label instead of raw hex hashes
  String _cleanSourceLabel() {
    final raw = (task.streamUrl != null && task.streamUrl!.isNotEmpty)
        ? task.streamUrl!
        : task.originalUrl;

    if (task.author.isNotEmpty &&
        !task.author.contains('http') &&
        !task.author.contains('/') &&
        !task.author.contains('.com') &&
        task.author.length < 32) {
      return task.author.trim();
    }

    String host = '';
    try {
      if (raw.startsWith('http')) host = Uri.parse(raw).host.toLowerCase();
    } catch (_) {}

    if (host.contains('r2.cloudflarestorage.com') ||
        host.contains('r2.dev') ||
        host.contains('cloudflare')) {
      return 'Cloudflare Fast CDN';
    }
    if (host.contains('googlevideo') || host.contains('youtube')) {
      return 'YouTube Fast Video CDN';
    }
    if (host.contains('bdix') ||
        host.contains('circle') ||
        host.contains('samonline')) {
      return 'Bangla BDIX Direct';
    }
    if (host.contains('vegamovies') || host.contains('vega')) {
      return 'VegaMovies Direct CDN';
    }
    if (host.contains('hdhub') || host.contains('hub')) {
      return 'HDHub Fast Server';
    }
    if (host.contains('drive.google') || host.contains('gdrive')) {
      return 'Google Drive Server';
    }
    if (host.contains('mediafire')) {
      return 'MediaFire Storage';
    }
    if (RegExp(r'^[a-f0-9]{12,}').hasMatch(host) ||
        RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(host)) {
      return 'High-Speed Dedicated CDN';
    }
    if (host.isNotEmpty) {
      final parts = host.split('.');
      if (parts.length >= 2) {
        return '${parts[parts.length - 2]}.${parts.last}';
      }
      return host;
    }
    return 'High-Speed Direct Server';
  }

  Widget _buildQualityBadge(String formatLabel, bool isAudio) {
    final lower = formatLabel.toLowerCase();
    Color startColor;
    Color endColor;
    String label = formatLabel;

    if (lower.contains('4k') || lower.contains('2160')) {
      startColor = const Color(0xFF8B5CF6);
      endColor = const Color(0xFF6366F1);
      label = '4K UHD';
    } else if (lower.contains('1080') || lower.contains('fhd')) {
      startColor = const Color(0xFF00E676);
      endColor = const Color(0xFF00B0FF);
      label = '1080p FHD';
    } else if (lower.contains('720') || lower.contains('hd')) {
      startColor = const Color(0xFF06B6D4);
      endColor = const Color(0xFF3B82F6);
      label = '720p HD';
    } else if (lower.contains('480') || lower.contains('sd')) {
      startColor = const Color(0xFF10B981);
      endColor = const Color(0xFF059669);
      label = '480p SD';
    } else if (isAudio) {
      startColor = const Color(0xFF10B981);
      endColor = const Color(0xFF06B6D4);
      label = task.ext.isNotEmpty ? task.ext.toUpperCase() : 'AUDIO';
    } else {
      startColor = const Color(0xFF10B981);
      endColor = const Color(0xFF00B0FF);
      label = formatLabel.isNotEmpty ? formatLabel : 'HD';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [startColor, endColor],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: startColor.withValues(alpha: 0.35),
            blurRadius: 4,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _actionPillButton({
    required bool isDark,
    required Color color,
    required Color bgColor,
    required Color borderColor,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final effectiveBg = isDark
        ? borderColor.withValues(alpha: 0.16)
        : borderColor.withValues(alpha: 0.10);
    final effectiveBorder = borderColor.withValues(alpha: isDark ? 0.38 : 0.28);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: effectiveBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: effectiveBorder, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: borderColor, size: 15),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: borderColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionIconButton({
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.14)
                    : Colors.black.withValues(alpha: 0.08),
                width: 1,
              ),
            ),
            child: Icon(
              icon,
              color: isDark
                  ? const Color(0xFFCBD5E1)
                  : const Color(0xFF64748B),
              size: 16,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDone = task.status == DownloadStatus.completed;
    final isFailed = task.status == DownloadStatus.failed;
    final isDownloading = task.status == DownloadStatus.downloading;
    final isPaused = task.status == DownloadStatus.paused;
    final isQueued = task.status == DownloadStatus.queued;
    final isPreparing = task.isPreparing;
    final total = task.displayTotalBytes;
    final approximate = total > 0 && task.totalBytesIsEstimate;
    final totalLabel = total > 0
        ? '${approximate ? '≈' : ''}${formatBytes(total)}'
        : 'Total unknown';
    final percentLabel = task.hasDownloadProgress
        ? '${approximate && !task.isConverting ? '≈' : ''}${(task.progress * 100).floor()}%'
        : '—';

    final isVideo = !task.isAudio && !task.isImageTask;
    final thumbWidth = isVideo ? 86.0 : 64.0;
    final thumbHeight = isVideo ? 58.0 : 64.0;

    Color statusDotColor = context.palette.success;
    String statusLabel = 'ACTIVE';
    if (isPreparing) {
      statusDotColor = context.palette.info;
      statusLabel = 'WAIT';
    } else if (isPaused) {
      statusDotColor = context.palette.textSecondary;
      statusLabel = 'PAUSED';
    } else if (isQueued) {
      statusDotColor = context.palette.info;
      statusLabel = 'QUEUED';
    } else if (isFailed) {
      statusDotColor = context.palette.critical;
      statusLabel = 'ERROR';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.09)
              : const Color(0xFFE2E8F0),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.35)
                : Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: isDone
              ? () {
                  if (task.isImageTask) {
                    ImageViewerDialog.show(context, task);
                  } else {
                    _play(context);
                  }
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Row: Thumbnail + Title + Badges
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Modern 16:9 widescreen or square media thumbnail
                    Stack(
                      children: [
                        Container(
                          width: thumbWidth,
                          height: thumbHeight,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: context.palette.shadowAt(0.25),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: task.thumbnailUrl.isNotEmpty
                                ? SmartNetworkImage(
                                    url: task.thumbnailUrl,
                                    width: thumbWidth,
                                    height: thumbHeight,
                                    fit: BoxFit.cover,
                                  )
                                : _buildPlaceholderIcon(),
                          ),
                        ),

                        // Corner Type Badge
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.all(3.5),
                            decoration: BoxDecoration(
                              color: task.isImageTask
                                  ? context.palette.secondary
                                  : (task.isAudioTask
                                        ? context.palette.success
                                        : context.palette.primary),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: context.palette.shadowAt(0.4),
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                            child: Icon(
                              task.isImageTask
                                  ? Icons.image_rounded
                                  : (task.isAudioTask
                                        ? Icons.music_note_rounded
                                        : Icons.videocam_rounded),
                              color: context.palette.textPrimary,
                              size: 10,
                            ),
                          ),
                        ),

                        // Sleek Glassmorphic Status Pill on Thumbnail
                        if (!isDone)
                          Positioned(
                            top: 4,
                            left: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2.5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.72),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.16),
                                  width: 0.5,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 5.5,
                                    height: 5.5,
                                    decoration: BoxDecoration(
                                      color: statusDotColor,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        if (isDownloading)
                                          BoxShadow(
                                            color: statusDotColor.withValues(
                                              alpha: 0.9,
                                            ),
                                            blurRadius: 4,
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    statusLabel,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),

                    SizedBox(width: 12),

                    // Title & Badges Details
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              height: 1.25,
                              color: context.palette.textPrimary,
                            ),
                          ),
                          SizedBox(height: 5),

                          // Badges: Quality + Category + Container Format
                          Wrap(
                            spacing: 5,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _buildQualityBadge(
                                task.formatLabel,
                                task.isAudio,
                              ),
                              Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? context.palette.tint(context.palette.card, 0.08)
                                      : context.palette.card,
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                    color: isDark
                                        ? context.palette.tint(context.palette.onScrim, 0.12)
                                        : context.palette.card,
                                    width: 0.8,
                                  ),
                                ),
                                child: Text(
                                  task.isAudio
                                      ? 'AUDIO'
                                      : (task.category.toUpperCase().isNotEmpty
                                            ? task.category.toUpperCase()
                                            : 'VIDEO'),
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: isDark
                                        ? context.palette.border
                                        : context.palette.textSecondary,
                                  ),
                                ),
                              ),
                              if (task.ext.isNotEmpty)
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? context.palette.tint(context.palette.card, 0.05)
                                        : context.palette.background,
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(
                                      color: isDark
                                          ? context.palette.tint(context.palette.onScrim, 0.10)
                                          : context.palette.card,
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    task.ext.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      color: context.palette.textSecondary,
                                    ),
                                  ),
                                ),
                            ],
                          ),

                          SizedBox(height: 4),

                          // Clean CDN / Channel Source
                          Row(
                            children: [
                              Icon(
                                Icons.cloud_outlined,
                                size: 12,
                                color: context.palette.textSecondary,
                              ),
                              SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  _cleanSourceLabel(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: context.palette.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Actions if completed
                    if (isDone) ...[
                      if (task.isImageTask)
                        IconButton(
                          tooltip: 'View Image',
                          icon: Icon(
                            Icons.image_rounded,
                            color: context.palette.secondary,
                            size: 32,
                          ),
                          onPressed: () {
                            ImageViewerDialog.show(context, task);
                          },
                        )
                      else if (task.isAudioTask)
                        IconButton(
                          tooltip: 'Play Music',
                          icon: Icon(
                            Icons.play_circle_fill_rounded,
                            color: context.palette.success,
                            size: 34,
                          ),
                          onPressed: () {
                            _play(context);
                          },
                        )
                      else
                        AnimatedBuilder(
                          animation: WatchHistoryService.instance,
                          builder: (context, child) {
                            final h = WatchHistoryService.instance
                                .getProgress(task.id);
                            final ratio = h == null || h.totalSeconds <= 0
                                ? 0.0
                                : (h.positionSeconds / h.totalSeconds).clamp(
                                    0.0,
                                    1.0,
                                  );
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Play Video',
                                  icon: Icon(
                                    Icons.play_circle_fill_rounded,
                                    color: context.palette.onAccent,
                                    size: 34,
                                  ),
                                  onPressed: () => _play(context),
                                ),
                                if (ratio > 0)
                                  Text(
                                    ratio >= 0.95
                                        ? 'Watched'
                                        : '${(ratio * 100).round()}%',
                                    style: TextStyle(
                                      color: ratio >= 0.95
                                          ? context.palette.success
                                          : context.palette.textSecondary,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      IconButton(
                        tooltip: 'Lock into Secret Vault',
                        icon: Icon(
                          Icons.lock_outline_rounded,
                          color: isDark
                              ? context.palette.primary
                              : context.palette.tint(context.palette.primary, 0.8),
                          size: 20,
                        ),
                        onPressed: () => _handleLockTap(context),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.more_vert_rounded,
                          color: context.palette.textSecondary,
                          size: 19,
                        ),
                        onPressed: () => _showActionSheet(context),
                      ),
                    ],
                  ],
                ),

                // Downloading Progress & Controls Section
                if (!isDone) ...[
                  const SizedBox(height: 12),

                  if (isPreparing)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: context.palette.primary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              task.statusNote == 'Starting download…'
                                  ? 'Starting download…'
                                  : task.isVideoTask
                                      ? 'Analyzing video…'
                                      : 'Preparing download…',
                              style: TextStyle(
                                color: context.palette.primary,
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5,
                              ),
                            ),
                            const Spacer(),
                            if (total > 0)
                              Text(
                                'Total $totalLabel · $percentLabel',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: context.palette.textSecondary,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          task.statusNote == 'Starting download…'
                              ? (total > 0
                                  ? 'Download size checked'
                                  : 'Total unknown')
                              : task.statusNote ??
                                  'Waiting for the download to start…',
                          style: TextStyle(
                            fontSize: 11,
                            color: context.palette.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _SmoothDownloadProgressSlider(
                          progress: null,
                          isPreparing: true,
                          primaryColor: context.palette.primary,
                          secondaryColor: context.palette.primary,
                        ),
                      ],
                    )
                  else ...[
                    // Live transfer stats row
                    Row(
                      children: [
                        // Dynamic Speed Badge
                        if (isDownloading &&
                            task.speedFormatted.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3.5,
                            ),
                            decoration: BoxDecoration(
                              color: context.palette.primary.withValues(alpha: isDark ? 0.16 : 0.10),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: context.palette.primary.withValues(alpha: isDark ? 0.35 : 0.25),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.arrow_downward_rounded,
                                  size: 13,
                                  color: context.palette.primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  task.speedFormatted,
                                  style: TextStyle(
                                    color: context.palette.textPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],

                        // ETA / Status
                        if (isDownloading && total > 0 &&
                            task.etaFormatted.isNotEmpty) ...[
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.schedule_rounded,
                                size: 13,
                                color: context.palette.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${task.etaFormatted} left',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: context.palette.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ] else if (isPaused || isQueued) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: isPaused
                                  ? (isDark
                                      ? const Color(0xFFD97706).withValues(alpha: 0.18)
                                      : const Color(0xFFFEF3C7))
                                  : context.palette.selectedBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isPaused
                                    ? (isDark
                                        ? const Color(0xFFD97706).withValues(alpha: 0.40)
                                        : const Color(0xFFF59E0B))
                                    : context.palette.primary.withValues(alpha: 0.3),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              isQueued ? 'Queued' : 'Paused',
                              style: TextStyle(
                                color: isPaused
                                    ? (isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309))
                                    : context.palette.textPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ] else if (isFailed) ...[
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? context.palette.error.withValues(alpha: 0.16)
                                    : context.palette.tint(context.palette.error, 0.08),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isDark
                                      ? context.palette.tint(context.palette.error, 0.35)
                                      : context.palette.error.withValues(alpha: 0.5),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                task.errorMessage ?? 'Download Failed',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.palette.error,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ] else if (task.isConverting) ...[
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? context.palette.secondary.withValues(alpha: 0.18)
                                    : context.palette.card,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: context.palette.info.withValues(alpha: 0.35),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                task.convertStage ?? 'Processing…',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.palette.info,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],

                        const SizedBox(width: 8),

                        // Downloaded / Total Bytes
                        Expanded(
                          child: Text(
                            isPaused
                                ? (total > 0
                                    ? '${formatBytes(task.downloadedBytes)} of $totalLabel'
                                    : '${formatBytes(task.downloadedBytes)} saved')
                                : '${formatBytes(task.downloadedBytes)} / $totalLabel',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: context.palette.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Bold Percentage Chip
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: (task.isAudio
                                    ? context.palette.success
                                    : context.palette.primary)
                                .withValues(alpha: isDark ? 0.20 : 0.12),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: (task.isAudio
                                      ? context.palette.success
                                      : context.palette.primary)
                                  .withValues(alpha: isDark ? 0.40 : 0.25),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            percentLabel,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: task.isAudio
                                  ? context.palette.success
                                  : (context.palette.primary),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 9),

                    // Ultra-Smooth UC Browser Slider with Lead Buffer & Flowing Shimmer
                    _SmoothDownloadProgressSlider(
                      progress: isDownloading && !task.hasDownloadProgress
                          ? null
                          : task.progress,
                      isPreparing: false,
                      isPaused: isPaused,
                      isDownloading: isDownloading,
                      isFailed: isFailed,
                      primaryColor: task.isAudio
                          ? context.palette.success
                          : context.palette.primary,
                      secondaryColor: task.isAudio
                          ? context.palette.success
                          : context.palette.primary,
                    ),
                  ],
                  const SizedBox(height: 12),

                  // Bottom Controls & Multi-Threads Row
                  Row(
                    children: [
                      if (task.threadsCount > 1)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.10)
                                  : Colors.black.withValues(alpha: 0.06),
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.bolt_rounded,
                                size: 14,
                                color: Color(0xFFFBBF24),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${task.threadsCount}x Multi-Threads',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: context.palette.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),

                      const Spacer(),

                      // Cohesive Pause / Resume / Retry Pill
                      _actionPillButton(
                        isDark: isDark,
                        color: Colors.white,
                        bgColor: isFailed
                            ? context.palette.error
                            : (isPaused
                                ? context.palette.success
                                : context.palette.primary),
                        borderColor: isFailed
                            ? context.palette.error
                            : (isPaused
                                ? context.palette.success
                                : context.palette.primary),
                        icon: isFailed
                            ? Icons.refresh_rounded
                            : (isPaused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded),
                        label: isFailed
                            ? 'Retry'
                            : (isPaused ? 'Resume' : 'Pause'),
                        onTap: isFailed
                            ? () => DownloadManager.instance.resumeTask(task)
                            : (isDownloading || isQueued
                                ? () => DownloadManager.instance.pauseTask(task)
                                : () => DownloadManager.instance.resumeTask(task)),
                      ),
                      const SizedBox(width: 8),

                      // Harmonized Cancel Button
                      _actionIconButton(
                        isDark: isDark,
                        icon: Icons.close_rounded,
                        tooltip: 'Cancel Download',
                        onTap: () => DownloadManager.instance.cancelTask(task),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholderIcon() {
    return Container(
      color: AppPalette.current.surface,
      child: Icon(
        task.isAudio ? Icons.music_note_rounded : Icons.videocam_rounded,
        color: task.isAudio ? AppPalette.current.success : AppPalette.current.primary,
        size: 30,
      ),
    );
  }
}

class _SmoothDownloadProgressSlider extends StatefulWidget {
  final double? progress;
  final bool isPreparing;
  final bool isPaused;
  final bool isDownloading;
  final bool isFailed;
  final Color? primaryColor;
  final Color? secondaryColor;

  const _SmoothDownloadProgressSlider({
    required this.progress,
    this.isPreparing = false,
    this.isPaused = false,
    this.isDownloading = false,
    this.isFailed = false,
    this.primaryColor,
    this.secondaryColor,
  });

  static double sliderHeight = 10.0;

  @override
  State<_SmoothDownloadProgressSlider> createState() =>
      _SmoothDownloadProgressSliderState();
}

class _SmoothDownloadProgressSliderState
    extends State<_SmoothDownloadProgressSlider>
    with TickerProviderStateMixin {
  late final AnimationController _animController;

  /// Sweeping highlight across the filled part while a transfer is running.
  late final AnimationController _shimmerController;

  /// Holds the currently rendered fraction and eases to each new target —
  /// unlike a restarting TweenAnimationBuilder, this never jumps back to 0.
  late final AnimationController _progressController;

  bool get _isDownloading =>
      widget.isDownloading &&
      !widget.isPaused &&
      !widget.isFailed &&
      !widget.isPreparing &&
      widget.progress != null;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1800),
    );
    _shimmerController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1400),
    );
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    )..value = (widget.progress ?? 0).clamp(0.0, 1.0);
    if (widget.isPreparing || widget.progress == null) {
      _animController.repeat();
    }
    if (_isDownloading) _shimmerController.repeat();
  }

  @override
  void didUpdateWidget(covariant _SmoothDownloadProgressSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.isPreparing || widget.progress == null) &&
        !_animController.isAnimating) {
      _animController.repeat();
    } else if (!widget.isPreparing &&
        widget.progress != null &&
        _animController.isAnimating) {
      _animController.stop();
    }
    if (_isDownloading && !_shimmerController.isAnimating) {
      _shimmerController.repeat();
    } else if (!_isDownloading && _shimmerController.isAnimating) {
      _shimmerController.stop();
    }

    final target = (widget.progress ?? 0).clamp(0.0, 1.0);
    final previous = (oldWidget.progress ?? 0).clamp(0.0, 1.0);
    if (target != previous) {
      if (widget.isPaused || widget.isFailed) {
        _progressController.value = target;
      } else {
        _progressController.animateTo(
          target,
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _shimmerController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trackColor = isDark
        ? const Color(0xFF1B2430)
        : const Color(0xFFE2E8F0);
    final trackBorder = isDark
        ? const Color(0xFF2A374A)
        : const Color(0xFFCBD5E1);

    final targetProgress = widget.progress?.clamp(0.0, 1.0);
    final isIndeterminate = widget.isPreparing || targetProgress == null;

    final primary = widget.isFailed
        ? context.palette.error
        : (widget.isPaused
            ? context.palette.info
            : (widget.primaryColor ?? context.palette.primary));
    final secondary = widget.secondaryColor ??
        (widget.isFailed
            ? const Color(0xFFEF4444)
            : (widget.isPaused
                ? const Color(0xFFF59E0B)
                : const Color(0xFF00E5FF)));

    final height = _SmoothDownloadProgressSlider.sliderHeight;

    final progressGradient = widget.isFailed
        ? const LinearGradient(
            colors: [Color(0xFFEF4444), Color(0xFFDC2626)],
          )
        : (widget.isPaused
            ? const LinearGradient(
                colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
              )
            : LinearGradient(
                colors: [
                  secondary,
                  primary,
                ],
              ));

    return Semantics(
      label: 'Download progress',
      value: targetProgress != null
          ? '${(targetProgress * 100).toInt()}%'
          : null,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          // Semantic & test integration
          SizedBox(
            width: 0,
            height: 0,
            child: Opacity(
              opacity: 0,
              child: LinearProgressIndicator(
                value: isIndeterminate ? null : targetProgress,
                color: AppColors.primary,
                backgroundColor: context.palette.tint(context.palette.primary, 0.14),
              ),
            ),
          ),

          // Custom High-End Smooth UC Browser Slider
          LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = constraints.maxWidth;

              if (isIndeterminate) {
                // Smooth traveling wave
                return AnimatedBuilder(
                  animation: _animController,
                  builder: (context, child) {
                    final t = _animController.value;
                    return Container(
                      height: height,
                      width: totalWidth,
                      decoration: BoxDecoration(
                        color: trackColor,
                        borderRadius: BorderRadius.circular(height / 2),
                        border: Border.all(color: trackBorder, width: 0.8),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        children: [
                          Positioned(
                            left: (t * (totalWidth + 140)) - 120,
                            top: 0,
                            bottom: 0,
                            child: Container(
                              width: 100,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    primary.withValues(alpha: 0.0),
                                    primary.withValues(alpha: 0.75),
                                    Colors.white.withValues(alpha: 0.9),
                                    primary.withValues(alpha: 0.75),
                                    primary.withValues(alpha: 0.0),
                                  ],
                                ),
                                borderRadius:
                                    BorderRadius.circular(height / 2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              }

              return AnimatedBuilder(
                animation: _progressController,
                builder: (context, child) {
                  final animatedValue =
                      _progressController.value.clamp(0.0, 1.0);
                  final filledWidth = totalWidth * animatedValue;
                  return Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // Track + filled segment, clipped to a clean pill.
                      Container(
                        height: height,
                        width: totalWidth,
                        decoration: BoxDecoration(
                          color: trackColor,
                          borderRadius: BorderRadius.circular(height / 2),
                          border: Border.all(color: trackBorder, width: 0.8),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          children: [
                            FractionallySizedBox(
                              widthFactor: animatedValue,
                              heightFactor: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: progressGradient,
                                ),
                              ),
                            ),
                            // Thin specular highlight along the top edge.
                            if (animatedValue > 0.01)
                              Positioned(
                                left: 0,
                                top: 0.8,
                                child: Container(
                                  width: filledWidth.clamp(0.0, totalWidth),
                                  height: height * 0.35,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(colors: [
                                      Colors.white.withValues(alpha: 0.05),
                                      Colors.white.withValues(alpha: 0.45),
                                      Colors.white.withValues(alpha: 0.05),
                                    ]),
                                    borderRadius: BorderRadius.circular(height),
                                  ),
                                ),
                              ),
                            // Fluid light sweep across filled bar
                            if (_isDownloading && filledWidth > 12)
                              AnimatedBuilder(
                                animation: _shimmerController,
                                builder: (context, _) {
                                  final t = _shimmerController.value;
                                  return Positioned(
                                    left: t * (filledWidth + 80) - 80,
                                    top: 0,
                                    bottom: 0,
                                    child: IgnorePointer(
                                      child: Container(
                                        width: 70,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(colors: [
                                            Colors.white.withValues(alpha: 0.0),
                                            Colors.white.withValues(alpha: 0.40),
                                            Colors.white.withValues(alpha: 0.0),
                                          ]),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      // Luminous pulse head at the leading edge of completed progress
                      if (_isDownloading && filledWidth > 2 && totalWidth >= 12)
                        Positioned(
                          left: (filledWidth - height / 2).clamp(0.0, totalWidth - height),
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: Container(
                              width: height,
                              height: height,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                    color: primary.withValues(alpha: 0.95),
                                    blurRadius: 8,
                                    spreadRadius: 2,
                                  ),
                                  BoxShadow(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    blurRadius: 3,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
