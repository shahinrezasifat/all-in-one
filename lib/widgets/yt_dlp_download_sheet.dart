import 'dart:io';
import 'package:flutter/material.dart';
import 'package:ytdlp_flutter/ytdlp_flutter.dart';
import '../services/download_manager.dart';
import '../services/gallery_media_service.dart';
import '../services/yt_dlp_service.dart';
import '../theme/app_palette.dart';
import 'remote_image.dart';

/// Clean quality picker + download progress for the on-device yt-dlp engine.
class YtDlpDownloadSheet extends StatefulWidget {
  final String url;
  final VideoInfo info;
  final List<YtDlpQuality> qualities;

  YtDlpDownloadSheet({
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
        color: context.palette.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? context.palette.border : context.palette.textSecondary,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 16, 12),
            child: Row(
              children: [
                SmartNetworkImage(
                  url: widget.info.thumbnailUrl ?? '',
                  width: 52,
                  height: 52,
                  placeholderIcon: Icons.video_file_rounded,
                  fallbackInitials: SmartNetworkImage.initialsFor(widget.info.title),
                  accentColor: context.palette.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Download video',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                      SizedBox(height: 3),
                      Text(
                        widget.info.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: context.palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1),
          Flexible(
            child: _downloading
                ? _buildProgress(isDark)
                : (widget.qualities.isEmpty
                    ? Padding(
                        padding: EdgeInsets.all(40),
                        child: Text('No formats reported by yt-dlp.',
                            textAlign: TextAlign.center),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        itemCount: widget.qualities.length,
                        separatorBuilder: (_, _) => SizedBox(height: 6),
                        itemBuilder: (context, i) {
                          final item = widget.qualities[i];
                          final selected = i == _selected;
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => setState(() => _selected = i),
                              borderRadius: BorderRadius.circular(14),
                              child: AnimatedContainer(
                                duration: Duration(milliseconds: 180),
                                padding: EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 11),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? context.palette.tint(context.palette.primary, isDark ? 0.14 : 0.08)
                                      : (context.palette.card),
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
                                                  ? context.palette.primary
                                                  : null,
                                            ),
                                          ),
                                          SizedBox(height: 3),
                                          Text(
                                            item.subtitle,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: context.palette.textSecondary,
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
                                          ? context.palette.primary
                                          : (isDark
                                              ? context.palette.textSecondary
                                              : context.palette.tint(context.palette.border, 0.26)),
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
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.palette.surface,
                border: Border(
                  top: BorderSide(
                    color: context.palette.border,
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                child: FilledButton.icon(
                  onPressed: q == null ? null : _start,
                  icon: Icon(Icons.download_rounded, size: 19),
                  label: Text(
                    q == null ? 'No format' : 'Download ${q.label}',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: context.palette.primary,
                    disabledBackgroundColor:
                        isDark ? context.palette.tint(context.palette.onScrim, 0.12) : context.palette.textSecondary,
                    padding: EdgeInsets.symmetric(vertical: 14),
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
      padding: EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_done)
            Icon(Icons.download_done_rounded,
                size: 52, color: context.palette.primary)
          else if (_error != null)
            Icon(Icons.error_outline_rounded,
                size: 52, color: context.palette.error)
          else
            SizedBox(
              width: 46,
              height: 46,
              child: CircularProgressIndicator(
                  strokeWidth: 3, color: context.palette.primary),
            ),
          SizedBox(height: 18),
          Text(
            _done
                ? 'Download complete'
                : (_error != null ? 'Download failed' : 'Downloading with yt-dlp'),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 6),
          if (_error == null && !_done)
            Text(pct,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: context.palette.primary)),
          if (_error != null)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    color: context.palette.textSecondary),
              ),
            ),
          SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_downloading)
                OutlinedButton.icon(
                  onPressed: _cancel,
                  icon: Icon(Icons.close_rounded, size: 16),
                  label: Text('Cancel'),
                ),
              SizedBox(width: 10),
              FilledButton(
                onPressed: () => Navigator.pop(context, _done),
                style: FilledButton.styleFrom(
                    backgroundColor: context.palette.primary,
                    padding:
                        EdgeInsets.symmetric(horizontal: 28, vertical: 12),
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
