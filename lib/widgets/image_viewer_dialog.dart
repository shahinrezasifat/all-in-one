import 'dart:io';
import 'package:flutter/material.dart';
import '../models/download_task.dart';
import '../services/player_service.dart';
import '../theme/app_palette.dart';

class ImageViewerDialog extends StatelessWidget {
  final DownloadTask task;

  ImageViewerDialog({super.key, required this.task});

  static Future<void> show(BuildContext context, DownloadTask task) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ImageViewerDialog(task: task),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final savePath = task.savePath;
    final file = (savePath != null && savePath.isNotEmpty) ? File(savePath) : null;
    final fileExists = file != null && file.existsSync();
    final fileSize = fileExists ? file.lengthSync() : task.totalBytes;

    return Scaffold(
      backgroundColor: context.palette.background,
      appBar: AppBar(
        backgroundColor: context.palette.textPrimary,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.palette.onPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.title,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.palette.onPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              task.author.isNotEmpty ? task.author : 'Cover Thumbnail',
              style: TextStyle(fontSize: 12, color: context.palette.onPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          if (fileExists)
            IconButton(
              icon: Icon(Icons.open_in_new_rounded, color: context.palette.onPrimary),
              tooltip: 'Open in System Gallery',
              onPressed: () {
                PlayerService.instance.launchSystemPlayer(file.path);
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: InteractiveViewer(
                  panEnabled: true,
                  boundaryMargin: EdgeInsets.all(20),
                  minScale: 0.8,
                  maxScale: 5.0,
                  child: fileExists
                      ? Image.file(
                          file,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => _buildFallbackImage(),
                        )
                      : _buildFallbackImage(),
                ),
              ),
            ),

            // Bottom Information Bar
            Container(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              color: context.palette.textPrimary,
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: context.palette.tint(context.palette.primary, 0.25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      task.ext.toUpperCase(),
                      style: TextStyle(
                        color: context.palette.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (fileSize > 0) ...[
                    SizedBox(width: 10),
                    Text(
                      _formatSize(fileSize),
                      style: TextStyle(color: context.palette.onPrimary, fontSize: 12),
                    ),
                  ],
                  Spacer(),
                  if (fileExists)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.palette.primary,
                        foregroundColor: context.palette.card,
                        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        PlayerService.instance.launchSystemPlayer(file.path);
                      },
                      icon: Icon(Icons.photo_library_rounded, size: 16),
                      label: Text('Open in Gallery', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFallbackImage() {
    if (task.thumbnailUrl.isNotEmpty && task.thumbnailUrl.startsWith('http')) {
      return Image.network(
        task.thumbnailUrl,
        fit: BoxFit.contain,
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return Center(child: CircularProgressIndicator(color: AppPalette.current.primary));
        },
        errorBuilder: (_, __, ___) => _buildPlaceholder(),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_rounded, size: 64, color: AppPalette.current.onPrimary),
          SizedBox(height: 12),
          Text('Could not load image', style: TextStyle(color: AppPalette.current.textSecondary)),
        ],
      ),
    );
  }
}
