import 'dart:io';

import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../screens/audio_player_screen.dart';
import '../screens/vault_screen.dart';
import '../services/download_manager.dart';
import '../services/gallery_media_service.dart';
import '../services/player_service.dart';
import '../services/vault_service.dart';
import '../services/virtual_folder_service.dart';
import '../theme/app_colors.dart';
import 'image_viewer_dialog.dart';
import 'remote_image.dart';

class DownloadItemTile extends StatelessWidget {
  final DownloadTask task;

  const DownloadItemTile({super.key, required this.task});

  void _play(BuildContext context) {
    PlayerService.instance.playDownloadTask(task);
    if (task.isAudioTask && ModalRoute.of(context)?.isFirst == false) {
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const AudioPlayerScreen()),
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
              title: const Row(
                children: [
                  Icon(Icons.folder_special_rounded, color: AppColors.primary),
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
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 10),
                    ...folders.map((f) {
                      final isInFolder = f.taskIds.contains(task.id);
                      return CheckboxListTile(
                        dense: true,
                        title: Text(
                          f.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          '${f.taskIds.length} items',
                          style: const TextStyle(fontSize: 11),
                        ),
                        value: isInFolder,
                        activeColor: AppColors.primary,
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
                  child: const Text(
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
    final dark = isDarkSafe(context);
    final vault = VaultService.instance;
    await vault.ready;

    if (!vault.isUnlocked) {
      await navigator.push(
        MaterialPageRoute(builder: (_) => const VaultScreen()),
      );
    }

    if (!vault.isUnlocked) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Vault stayed locked — nothing was moved.'),
          backgroundColor: dark ? AppColors.darkCard : Colors.grey.shade800,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final path = task.savePath;
    final file = (path == null || path.isEmpty) ? null : File(path);
    if (file == null || !file.existsSync()) {
      await DownloadManager.instance.removeTaskOnly(task);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('The file was already gone — removed from the list.'),
        ),
      );
      return;
    }

    try {
      await vault.moveToVault(task);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Could not move the file to Vault")),
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
        backgroundColor: AppColors.accentPurple,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Row(
          children: [
            const Icon(Icons.lock_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "\"${task.title}\" is now locked in the Secret Vault — it no longer appears in Downloads.",
                style: const TextStyle(
                  color: Colors.white,
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
          color: isDark ? AppColors.darkSurface : const Color(0xFFF2F2F7),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4.5,
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkBorder : Colors.black26,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 10),
              child: Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
                ),
              ),
            ),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkCard : Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  _sheetAction(
                    icon: Icons.lock_rounded,
                    color: AppColors.accentPurple,
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
                    color: AppColors.primary,
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
                        ? const Color(0xFFE91E63)
                        : (task.isAudioTask
                              ? const Color(0xFF1DB954)
                              : AppColors.accentBlue),
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
                    color: AppColors.accentRed,
                    title: 'Delete File',
                    subtitle: 'Remove it from this device',
                    isDark: isDark,
                    onTap: () {
                      Navigator.pop(ctx);
                      DownloadManager.instance.deleteTask(task);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: isDark ? AppColors.darkCard : Colors.white,
                  foregroundColor: isDark ? Colors.white70 : Colors.black87,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? AppColors.darkTextSecondary
                          : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: isDark ? AppColors.darkTextTertiary : Colors.grey.shade400,
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
      color: isDark ? Colors.white12 : Colors.black12,
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
      startColor = const Color(0xFFFFB300);
      endColor = const Color(0xFFFF6D00);
      label = '4K UHD';
    } else if (lower.contains('1080') || lower.contains('fhd')) {
      startColor = const Color(0xFF00E676);
      endColor = const Color(0xFF00B0FF);
      label = '1080p FHD';
    } else if (lower.contains('720') || lower.contains('hd')) {
      startColor = const Color(0xFF4FC3F7);
      endColor = const Color(0xFF0288D1);
      label = '720p HD';
    } else if (lower.contains('480') || lower.contains('sd')) {
      startColor = const Color(0xFFBA68C8);
      endColor = const Color(0xFF7B1FA2);
      label = '480p SD';
    } else if (isAudio) {
      startColor = const Color(0xFF1DB954);
      endColor = const Color(0xFF1ED760);
      label = task.ext.isNotEmpty ? task.ext.toUpperCase() : 'AUDIO';
    } else {
      startColor = AppColors.primary;
      endColor = const Color(0xFF26E6A2);
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
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 15),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
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
    required Color color,
    required Color hoverColor,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white10
                  : Colors.black.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 16),
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

    // Card border color based on status

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: isDownloading
                ? AppColors.primary.withValues(alpha: isDark ? 0.15 : 0.08)
                : Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: isDownloading ? 16 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
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
                // Top Row: Thumbnail + Title + Metadata Badges
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Modern Poster / Thumbnail
                    Stack(
                      children: [
                        Container(
                          width: task.isAudio ? 72 : 64,
                          height: task.isAudio ? 72 : 92,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 6,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: task.thumbnailUrl.isNotEmpty
                                ? SmartNetworkImage(
                                    url: task.thumbnailUrl,
                                    width: task.isAudio ? 72 : 64,
                                    height: task.isAudio ? 72 : 92,
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
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: task.isImageTask
                                  ? const Color(0xFFE91E63)
                                  : (task.isAudioTask
                                        ? const Color(0xFF1DB954)
                                        : AppColors.primary),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                            child: Icon(
                              task.isImageTask
                                  ? Icons.image_rounded
                                  : (task.isAudioTask
                                        ? Icons.music_note_rounded
                                        : Icons.videocam_rounded),
                              color: Colors.white,
                              size: 11,
                            ),
                          ),
                        ),

                        // Live status badge on poster
                        if (isDownloading)
                          Positioned(
                            top: 4,
                            left: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 5,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      color: isPreparing
                                          ? AppColors.accentGold
                                          : AppColors.accentGreen,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    isPreparing ? 'WAIT' : 'ACTIVE',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 7.5,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(width: 12),

                    // Title & Info Details
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              height: 1.25,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF1E293B),
                            ),
                          ),
                          const SizedBox(height: 6),

                          // Badges: Quality + Type + Extension
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _buildQualityBadge(
                                task.formatLabel,
                                task.isAudio,
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white12
                                      : Colors.black.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  task.isAudio
                                      ? 'AUDIO'
                                      : (task.category.toUpperCase().isNotEmpty
                                            ? task.category.toUpperCase()
                                            : 'MOVIE'),
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: isDark
                                        ? Colors.white70
                                        : Colors.black87,
                                  ),
                                ),
                              ),
                              if (task.ext.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? Colors.white10
                                        : Colors.black.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Text(
                                    task.ext.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? Colors.white54
                                          : Colors.black54,
                                    ),
                                  ),
                                ),
                            ],
                          ),

                          const SizedBox(height: 5),

                          // Clean CDN / Server Line
                          Row(
                            children: [
                              Icon(
                                Icons.cloud_download_outlined,
                                size: 13,
                                color: isDark ? Colors.white38 : Colors.black38,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  _cleanSourceLabel(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark
                                        ? Colors.white54
                                        : Colors.black54,
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
                          icon: const Icon(
                            Icons.image_rounded,
                            color: Color(0xFFE91E63),
                            size: 34,
                          ),
                          onPressed: () {
                            ImageViewerDialog.show(context, task);
                          },
                        )
                      else if (task.isAudioTask)
                        IconButton(
                          tooltip: 'Play Music',
                          icon: const Icon(
                            Icons.play_circle_fill_rounded,
                            color: Color(0xFF1DB954),
                            size: 36,
                          ),
                          onPressed: () {
                            _play(context);
                          },
                        )
                      else
                        IconButton(
                          tooltip: 'Play Video',
                          icon: const Icon(
                            Icons.play_circle_fill_rounded,
                            color: AppColors.primary,
                            size: 36,
                          ),
                          onPressed: () {
                            _play(context);
                          },
                        ),
                      IconButton(
                        tooltip: 'Lock into Secret Vault',
                        icon: Icon(
                          Icons.lock_outline_rounded,
                          color: isDark
                              ? AppColors.accentPurple
                              : AppColors.accentPurple.withValues(alpha: 0.8),
                          size: 22,
                        ),
                        onPressed: () => _handleLockTap(context),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.more_vert_rounded,
                          color: isDark
                              ? AppColors.darkTextTertiary
                              : AppColors.lightTextTertiary,
                          size: 20,
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
                        Text(
                          task.statusNote == 'Starting download…'
                              ? 'Starting download'
                              : task.isVideoTask
                                  ? 'Analyzing video…'
                                  : 'Preparing download…',
                          style: TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          task.statusNote == 'Starting download…'
                              ? (total > 0 ? 'Download size checked' : 'Total unknown')
                              : task.statusNote ?? 'Waiting for the download to start',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (total > 0) ...[
                          const SizedBox(height: 4),
                          Text('Total $totalLabel · $percentLabel',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            minHeight: 6,
                            color: AppColors.primary,
                            backgroundColor: AppColors.primary.withValues(
                              alpha: .15,
                            ),
                            semanticsLabel: 'Preparing download',
                          ),
                        ),
                      ],
                    )
                  else ...[
                    // Live transfer stats
                    Row(
                      children: [
                        // Status & Speed Badges (Wrapped in Expanded to prevent horizontal overflow)
                        Expanded(
                          child: Row(
                            children: [
                              if (isDownloading &&
                                  task.speedFormatted.isNotEmpty) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withValues(
                                      alpha: 0.14,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.bolt_rounded,
                                        size: 14,
                                        color: AppColors.primary,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        task.speedFormatted,
                                        style: const TextStyle(
                                          color: AppColors.primary,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],

                              // ETA / Status
                              if (isDownloading &&
                                  task.etaFormatted.isNotEmpty) ...[
                                Icon(
                                  Icons.schedule_rounded,
                                  size: 13,
                                  color: isDark
                                      ? Colors.white54
                                      : Colors.black45,
                                ),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(
                                    '${task.etaFormatted} left',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black54,
                                    ),
                                  ),
                                ),
                              ] else if (isPaused || isQueued) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.accentGold.withValues(
                                      alpha: 0.15,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    isQueued ? 'Queued' : 'Paused',
                                    style: const TextStyle(
                                      color: AppColors.accentGold,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ] else if (isFailed) ...[
                                Flexible(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.accentRed.withValues(
                                        alpha: 0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      task.errorMessage ?? 'Download Failed',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.accentRed,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ] else if (task.isConverting) ...[
                                Flexible(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.accentGold.withValues(
                                        alpha: 0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      task.convertStage ?? 'Processing…',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.accentGold,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),

                        Flexible(
                          child: Text(
                            '${formatBytes(task.downloadedBytes)} / $totalLabel',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isDark ? Colors.white60 : Colors.black54,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),

                        // Bold Percentage
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            percentLabel,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w900,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    LinearProgressIndicator(
                      value: isDownloading && !task.hasDownloadProgress
                          ? null
                          : task.progress,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(8),
                      color: AppColors.primary,
                      backgroundColor: AppColors.primary.withValues(alpha: .14),
                      semanticsLabel: 'Download progress',
                    ),
                  ],
                  const SizedBox(height: 10),

                  // Bottom Controls & Threads Row
                  Row(
                    children: [
                      if (task.threadsCount > 1)
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3.5,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.07)
                                  : Colors.black.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.flash_on_rounded,
                                  size: 12,
                                  color: AppColors.primary,
                                ),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(
                                    '${task.threadsCount}x Multi-Threads',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      const Spacer(),

                      // Pause / Resume / Retry Button
                      _actionPillButton(
                        isDark: isDark,
                        color: isFailed
                            ? AppColors.accentRed
                            : (isPaused
                                  ? AppColors.primary
                                  : AppColors.accentGold),
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
                                  ? () =>
                                        DownloadManager.instance.pauseTask(task)
                                  : () => DownloadManager.instance.resumeTask(
                                      task,
                                    )),
                      ),
                      const SizedBox(width: 8),

                      // Cancel Button
                      _actionIconButton(
                        isDark: isDark,
                        color: isDark ? Colors.white54 : Colors.black45,
                        hoverColor: AppColors.accentRed,
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
      color: AppColors.darkSurface,
      child: Icon(
        task.isAudio ? Icons.music_note_rounded : Icons.videocam_rounded,
        color: task.isAudio ? const Color(0xFF1DB954) : AppColors.primary,
        size: 30,
      ),
    );
  }
}
