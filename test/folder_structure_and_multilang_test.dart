// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/services/download_manager.dart';
import 'package:snaptube_pure/services/extractor_service.dart';
import 'package:snaptube_pure/services/gallery_media_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});

  test('Automatic Folder Structure organizes by Website and Channel/Author', () async {
    final mgr = DownloadManager.instance;
    await mgr.ready;

    // 1. YouTube folder test
    final ytFolder = mgr.destinationFolder(
      platform: 'YouTube',
      url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      author: 'Rick Astley',
    );
    expect(ytFolder.contains('YouTube'), true);
    expect(ytFolder.contains('Rick Astley'), true);
    expect(Directory(ytFolder).existsSync(), true);

    // 2. Adult / other website folder test (e.g. Pornhub)
    final phFolder = mgr.destinationFolder(
      platform: 'Web Video',
      url: 'https://www.pornhub.com/view_video.php?viewkey=64f12345',
      author: 'SweetieFox',
    );
    expect(phFolder.contains('Pornhub'), true);
    expect(phFolder.contains('SweetieFox'), true);
    expect(Directory(phFolder).existsSync(), true);

    // 3. Facebook folder test
    final fbFolder = mgr.destinationFolder(
      platform: 'Facebook',
      url: 'https://www.facebook.com/watch/?v=123456',
      author: 'BBC News',
    );
    expect(fbFolder.contains('Facebook'), true);
    expect(fbFolder.contains('BBC News'), true);
    expect(Directory(fbFolder).existsSync(), true);

    // 4. Fallback when author is empty/unknown
    final fallbackFolder = mgr.destinationFolder(
      platform: 'TikTok',
      url: 'https://www.tiktok.com/@creator/video/123456',
      author: '',
    );
    expect(fallbackFolder.contains('TikTok'), true);
    expect(fallbackFolder.contains('Unknown'), true);
    expect(Directory(fallbackFolder).existsSync(), true);
  });

  test('Thumbnail download saves genuine file directly into Channel folder', () async {
    final mgr = DownloadManager.instance;
    await mgr.ready;

    final folder = mgr.destinationFolder(
      platform: 'YouTube',
      url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      author: 'Rick Astley',
    );

    const testThumbUrl = 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg';
    final savedPath = await GalleryMediaService.instance.saveThumbnail(
      testThumbUrl,
      'Never Gonna Give You Up',
      folder: folder,
    );

    expect(savedPath, isNotNull);
    final file = File(savedPath!);
    expect(file.existsSync(), true);
    expect(file.lengthSync() > 1000, true);
    print('Saved Thumbnail on Disk: ${file.path} (${file.lengthSync()} bytes)');

    // Add completed image task to DownloadManager
    final task = await mgr.addCompletedImageTask(
      title: 'Never Gonna Give You Up',
      author: 'Rick Astley',
      platform: 'YouTube',
      originalUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      filePath: savedPath,
      thumbnailUrl: testThumbUrl,
    );
    expect(task.status, DownloadStatus.completed);
    expect(task.category, 'image');
    expect(task.totalBytes, file.lengthSync());
    expect(mgr.completedTasks.any((t) => t.id == task.id), true);

    // Clean up test file
    try {
      file.deleteSync();
    } catch (_) {}
  });

  test('Multi-language audio extraction and companion resolution preserves tracks', () async {
    // Test extraction on a known multi-audio video (MrBeast: 0e3GPea1Tyg or Costa Rica 4K)
    final result = await ExtractorService.instance.extract('https://www.youtube.com/watch?v=LXb3EKWsInQ');
    expect(result, isNotNull);

    // Check resolveLiveVideoWithAudio works with preferredFormatId and optional audioTrackId
    final streamPair = await ExtractorService.instance.resolveLiveVideoWithAudio(
      'https://www.youtube.com/watch?v=LXb3EKWsInQ',
      preferredFormatId: 'yt_v_2160p',
      preferredLabel: '4K Ultra HD (2160p)',
    );
    expect(streamPair, isNotNull);
    expect(streamPair!.videoUrl.isNotEmpty, true);
    expect(streamPair.audioUrl != null && streamPair.audioUrl!.isNotEmpty, true);
    print('Resolved 4K Video: ${streamPair.videoUrl.substring(0, 50)}...');
    print('Resolved Companion Audio: ${streamPair.audioUrl!.substring(0, 50)}...');
  });
}
