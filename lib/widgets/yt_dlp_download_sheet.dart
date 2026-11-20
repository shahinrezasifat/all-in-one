import 'dart:io';
import 'package:flutter/material.dart';
import 'package:ytdlp_flutter/ytdlp_flutter.dart';
import '../services/download_manager.dart';
import '../services/gallery_media_service.dart';
import '../services/yt_dlp_service.dart';
import '../theme/app_colors.dart';
import 'remote_image.dart';

/// Clean quality picker + download progress for the on-device yt-dlp engine.
class YtDlpDownloadSheet extends StatefulWidget {
  final String url;
  final VideoInfo info;
  final List<YtDlpQuality> qualities;

  const YtDlpDownloadSheet({
    super.key,
    required this.url,
    required this.info,
    required this.qualities,
  });

  static Future<void> show(
    BuildContext context, {
    required String url,
    required VideoInfo info,
    required List<YtDlpQuality> qualities,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => YtDlpDownloadSheet(
        url: url,
        info: info,
        qualities: qualities,
      ),
    );
  }

  @override
  State<YtDlpDownloadSheet> createState() => _YtDlpDownloadSheetState();
}

class _YtDlpDownloadSheetState extends State<YtDlpDownloadSheet> {
  int _selected = 0;
  bool _downloading = false;
  bool _done = false;
  String? _error;
  double? _fraction;
  String? _taskId;

  Future<void> _start() async {
    if (_downloading || widget.qualities.isEmpty) return;
    final quality = widget.qualities[_selected];
    final taskId = 'yt-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _downloading = true;
      _error = null;
      _done = false;
      _fraction = 0;
      _taskId = taskId;
    });

    try {
      final dir = DownloadManager.instance.downloadDirectory;
      if (Platform.isAndroid) await Directory(dir).create(recursive: true);
      final path = await YtDlpService.instance.download(
        url: widget.url,
        quality: quality,
        outputDir: dir,
        taskId: taskId,
        onProgress: (YtdlpProgress p) {
          final f = p.fraction ??
              ((p.totalBytes != null && p.totalBytes! > 0 && p.downloadedBytes != null)
                  ? p.downloadedBytes! / p.totalBytes!
                  : null);
          if (f != null && mounted) setState(() => _fraction = f.clamp(0.0, 1.0));
        },
      );
      await GalleryMediaService.instance.scanFile(path);
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _cancel() async {
    final id = _taskId;
    if (id != null) await YtDlpService.instance.cancel(id);
    if (mounted) {
      setState(() {
        _downloading = false;
        _fraction = null;
        _taskId = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final q = widget.qualities.isEmpty ? null : widget.qualities[_selected];

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      margin: EdgeInsets.only(
        left: MediaQuery.of(context).size.width > 700
            ? (MediaQuery.of(context).size.width - 600) / 2
            : 0,
        right: MediaQuery.of(context).size.width > 700
            ? (MediaQuery.of(context).size.width - 600) / 2
            : 0,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBorder : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
            child: Row(
              children: [
                SmartNetworkImage(
                  url: widget.info.thumbnailUrl ?? '',
                  width: 52,
                  height: 52,
                  placeholderIcon: Icons.video_file_rounded,
                  fallbackInitials: SmartNetworkImage.initialsFor(widget.info.title),
                  accentColor: AppColors.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Download video',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(
                        widget.info.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark
                              ? AppColors.darkTextSecondary
                              : AppColors.lightTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: _downloading
                ? _buildProgress(isDark)
                : (widget.qualities.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(40),
                        child: Text('No formats reported by yt-dlp.',
                            textAlign: TextAlign.center),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        itemCount: widget.qualities.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (context, i) {
                          final item = widget.qualities[i];
                          final selected = i == _selected;
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => setState(() => _selected = i),
                              borderRadius: BorderRadius.circular(14),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 11),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? AppColors.primary.withValues(
                                          alpha: isDark ? 0.14 : 0.08)
                                      : (isDark
                                          ? AppColors.darkCard
                                          : Colors.white),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.label,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w800,
                                              color: selected
                                                  ? AppColors.primary
                                                  : null,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            item.subtitle,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: isDark
                                                  ? AppColors.darkTextTertiary
                                                  : AppColors.lightTextTertiary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      selected
                                          ? Icons.check_circle_rounded
                                          : Icons.circle_outlined,
                                      size: 18,
                                      color: selected
                                          ? AppColors.primary
                                          : (isDark
                                              ? Colors.white30
                                              : Colors.black26),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      )),
          ),
          if (!_downloading)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                border: Border(
                  top: BorderSide(
                    color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                child: FilledButton.icon(
                  onPressed: q == null ? null : _start,
                  icon: const Icon(Icons.download_rounded, size: 19),
                  label: Text(
                    q == null ? 'No format' : 'Download ${q.label}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    disabledBackgroundColor:
                        isDark ? Colors.white12 : Colors.grey.shade300,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProgress(bool isDark) {
    final pct = _fraction == null
        ? '…'
        : '${(_fraction! * 100).toStringAsFixed(0)}%';
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_done)
            const Icon(Icons.download_done_rounded,
                size: 52, color: AppColors.primary)
          else if (_error != null)
            Icon(Icons.error_outline_rounded,
                size: 52, color: AppColors.accentRed)
          else
            const SizedBox(
              width: 46,
              height: 46,
              child: CircularProgressIndicator(
                  strokeWidth: 3, color: AppColors.primary),
            ),
          const SizedBox(height: 18),
          Text(
            _done
                ? 'Download complete'
                : (_error != null ? 'Download failed' : 'Downloading with yt-dlp'),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          if (_error == null && !_done)
            Text(pct,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary)),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    color: isDark ? Colors.white60 : Colors.black54),
              ),
            ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_downloading)
                OutlinedButton.icon(
                  onPressed: _cancel,
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Cancel'),
                ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () => Navigator.pop(context, _done),
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: Text(_done ? 'Done' : 'Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
