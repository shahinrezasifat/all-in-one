import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/download_task.dart';
import 'image_cache_service.dart';

/// Saves a real copy of every download's thumbnail/poster into the public
/// Download folder AND registers it with the Android media scanner, so the
/// picture shows up in the Gallery and in the file manager automatically —
/// the moment the video, song or movie finishes.
///
/// The finished media file itself is scanned too (a video download should be
/// visible in the gallery without rebooting), and on desktop the thumbnail
/// simply lands next to the media in the same Download tree.
class GalleryMediaService {
  GalleryMediaService._();

  static final GalleryMediaService instance = GalleryMediaService._();

  /// Native MediaScanner bridge (Android only; silently skipped elsewhere).
  static const MethodChannel _channel =
      MethodChannel('snaptube_pure/media_scan');

  /// Fire-and-forget: called for every completed download task.
  void archiveCompletedTask(DownloadTask task, String downloadDirectory) {
    unawaited(_archive(task, downloadDirectory));
  }

  Future<void> _archive(DownloadTask task, String downloadDirectory) async {
    // 1. The media file itself → gallery / file manager index.
    final mediaPath = task.savePath;
    if (mediaPath != null && mediaPath.isNotEmpty) {
      await scanFile(mediaPath);
    }

    // 2. Its thumbnail/poster as a standalone image next to it.
    final url = task.thumbnailUrl;
    if (url.isEmpty) return;
    await saveThumbnail(
      url,
      task.title,
      folder: thumbnailFolderFor(
        downloadDirectory,
        isAudio: task.isAudio,
        category: task.category,
      ),
    );
  }

  /// Where the saved cover picture of a download lives (per category).
  static String thumbnailFolderFor(
    String downloadDirectory, {
    required bool isAudio,
    required String category,
  }) {
    if (isAudio) return '$downloadDirectory/Music/Thumbnails';
    if (category == 'movie') return '$downloadDirectory/Movies/Thumbnails';
    return '$downloadDirectory/Videos/Thumbnails';
  }

  /// Deletes the saved cover picture of [title] when its media is locked into
  /// the Secret Vault — an unhidden poster would defeat the whole lock.
  void removeThumbnailFor(
    String title, {
    required String downloadDirectory,
    required bool isAudio,
    required String category,
  }) {
    final safe = _safeName(title);
    final dir = Directory(
      thumbnailFolderFor(
        downloadDirectory,
        isAudio: isAudio,
        category: category,
      ),
    );
    try {
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.split(Platform.pathSeparator).last.startsWith('${safe}_thumb')) {
          continue;
        }
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Downloads (or re-uses the instant-load cache of) [url] and stores it as
  /// `<safe title>_thumb.jpg` inside [folder]. Returns the image path, or null
  /// when nothing could be saved. Never throws — a missing poster must not
  /// break an otherwise-successful download.
  Future<String?> saveThumbnail(
    String url,
    String title, {
    required String folder,
  }) async {
    if (url.isEmpty) return null;
    try {
      // 1. Try memory/disk image cache first
      Uint8List? bytes = await ImageCacheService.instance.getBytes(url);
      
      // 2. Fall back to direct resilient network fetch with full browser headers
      if (bytes == null || bytes.isEmpty) {
        try {
          final res = await http.get(Uri.parse(url), headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
            'Accept': 'image/avif,image/webp,image/apng,image/png,image/*;q=0.8,*/*;q=0.5',
          }).timeout(const Duration(seconds: 15));
          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            bytes = res.bodyBytes;
          }
        } catch (netErr) {
          debugPrint('GalleryMediaService: network thumbnail fetch failed: $netErr');
        }
      }
      if (bytes == null || bytes.isEmpty) return null;

      final safe = _safeName(title);
      final ext = _extFor(url, bytes);
      final dir = Directory(folder);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final file = File('$folder/${safe}_thumb.$ext');
      if (file.existsSync() && file.lengthSync() == bytes.length) {
        await scanFile(file.path);
        return file.path;
      }
      await file.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      await scanFile(file.path);
      return file.path;
    } catch (e) {
      debugPrint('GalleryMediaService: thumbnail save failed: $e');
      return null;
    }
  }

  /// Asks the system to index [path] (gallery / file manager / music apps).
  Future<void> scanFile(String path) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('scanFile', {'path': path});
    } catch (_) {
      // Scanner unavailable (channel missing / permission oddity): the file
      // is still on disk and visible in any file manager.
    }
  }

  static String _safeName(String title) {
    final clean = title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return 'cover';
    return clean.length > 60 ? clean.substring(0, 60).trim() : clean;
  }

  /// Trust the URL first, then the actual magic bytes — a poster served as
  /// .jpg URL but really PNG still opens correctly everywhere.
  static String _extFor(String url, List<int> bytes) {
    final lower = url.toLowerCase();
    if (lower.contains('.png')) return 'png';
    if (lower.contains('.webp')) return 'webp';
    if (bytes.length >= 3 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E) {
      return 'png';
    }
    return 'jpg';
  }
}
