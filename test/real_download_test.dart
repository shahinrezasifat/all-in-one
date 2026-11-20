// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/services/download_manager.dart';
import 'package:snaptube_pure/services/extractor_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('YouTube Extractor extracts real streams with valid URLs and byte sizes', () async {
    final result = await ExtractorService.instance.extract('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    expect(result, isNotNull);
    expect(result!.title.isNotEmpty, true);
    expect(result.videoFormats.isNotEmpty, true);
    expect(result.audioFormats.isNotEmpty, true);

    print('Title: ${result.title}');
    print('Author: ${result.author}');
    print('Video formats: ${result.videoFormats.length}');
    print('Audio formats: ${result.audioFormats.length}');

    final firstAudio = result.audioFormats.firstWhere((a) => a.url != null && a.url!.isNotEmpty);
    expect(firstAudio.url, isNotNull);
    expect(firstAudio.fileSize, isNotNull);
    expect(firstAudio.fileSize! > 100000, true);
    print('First Audio Stream: ${firstAudio.label} | Size: ${firstAudio.fileSize} bytes | URL: ${firstAudio.url!.substring(0, 50)}...');

    // Test real download
    final downloadMgr = DownloadManager.instance;
    final task = await downloadMgr.startDownload(video: result, format: firstAudio);
    expect(task.status, DownloadStatus.downloading);

    // Wait up to 15 seconds for download to progress or complete
    int ticks = 0;
    while (task.status == DownloadStatus.downloading && ticks < 30) {
      await Future.delayed(const Duration(milliseconds: 500));
      ticks++;
      print('Progress: ${(task.progress * 100).toStringAsFixed(1)}% | Bytes: ${task.downloadedBytes} | Speed: ${task.speedFormatted}');
    }

    expect(task.downloadedBytes > 0, true);
    print('Task Final Status: ${task.status} | Final Downloaded Bytes: ${task.downloadedBytes}');
    if (task.savePath != null) {
      final f = File(task.savePath!);
      if (f.existsSync()) {
        print('Downloaded File on Disk: ${f.path} (${f.lengthSync()} bytes)');
        expect(f.lengthSync() > 100000, true);
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
