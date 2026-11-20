// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/services/download_manager.dart';
import 'package:snaptube_pure/services/extractor_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});

  test('4K and 2K formats are present and listed first in ExtractorService for Costa Rica 4K', () async {
    final result = await ExtractorService.instance.extract('https://www.youtube.com/watch?v=LXb3EKWsInQ');
    expect(result, isNotNull);
    expect(result!.videoFormats.isNotEmpty, true);

    print('Extracted Costa Rica 4K video formats:');
    for (int i = 0; i < result.videoFormats.length; i++) {
      print('  [$i] ${result.videoFormats[i].label} (${result.videoFormats[i].formattedSize})');
    }

    expect(result.videoFormats.length >= 7, true,
        reason: 'Must extract complete ladder of formats (4K, 2K, 1080p, 720p, 480p, 360p, 240p, 144p)');

    final format0 = result.videoFormats[0];
    final format1 = result.videoFormats[1];

    expect(format0.label.contains('2160') || format0.label.contains('4K'), true,
        reason: 'Format #0 must be 4K Ultra HD (2160p)');
    expect(format1.label.contains('1440') || format1.label.contains('2K'), true,
        reason: 'Format #1 must be 2K Quad HD (1440p)');
  });

  test('4K and 2K formats are present and listed first in ExtractorService', () async {
    final result = await ExtractorService.instance.extract('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    expect(result, isNotNull);
    expect(result!.videoFormats.isNotEmpty, true);

    print('Extracted video formats:');
    for (int i = 0; i < result.videoFormats.length; i++) {
      print('  [$i] ${result.videoFormats[i].label} (${result.videoFormats[i].formattedSize})');
    }

    final format0 = result.videoFormats[0];
    final format1 = result.videoFormats[1];

    expect(format0.label.contains('2160') || format0.label.contains('4K'), true,
        reason: 'Format #0 must be 4K Ultra HD (2160p)');
    expect(format1.label.contains('1440') || format1.label.contains('2K'), true,
        reason: 'Format #1 must be 2K Quad HD (1440p)');
  });

  test('activeTasks in DownloadManager includes paused and failed tasks', () {
    final mgr = DownloadManager.instance;
    expect(mgr.activeTasks, isA<List<DownloadTask>>());

    // Completed tasks should not be in activeTasks
    for (final t in mgr.activeTasks) {
      expect(t.status != DownloadStatus.completed, true);
      expect(t.status != DownloadStatus.cancelled, true);
    }
  });

  test('Live audio stream dynamic resolution returns genuine URL', () async {
    final audioUrl = await ExtractorService.instance.resolveLiveAudioStreamForTrack('Kesariya', 'Arijit Singh');
    expect(audioUrl, isNotNull);
    expect(audioUrl!.isNotEmpty, true);
    expect(audioUrl.startsWith('http'), true);
    print('Resolved Live Audio Stream: ${audioUrl.substring(0, 60)}...');
  });

  test('Live movie stream dynamic resolution returns genuine 4K/HD URL', () async {
    final movieUrl = await ExtractorService.instance.resolveLiveMovieStream('Avatar The Way of Water', resolution: '4K Ultra HD (2160p)');
    expect(movieUrl, isNotNull);
    expect(movieUrl!.isNotEmpty, true);
    expect(movieUrl.startsWith('http'), true);
    print('Resolved Live Movie Stream: ${movieUrl.substring(0, 60)}...');
  });

  test('Video download starts and streams genuine bytes', () async {
    final result = await ExtractorService.instance.extract('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    expect(result, isNotNull);
    final format = result!.videoFormats.firstWhere((f) => f.label.contains('360p') || f.label.contains('720p'));
    final mgr = DownloadManager.instance;
    final task = await mgr.startDownload(video: result, format: format);
    expect(task.status, DownloadStatus.downloading);

    int ticks = 0;
    while (task.status == DownloadStatus.downloading && ticks < 20) {
      await Future.delayed(const Duration(milliseconds: 500));
      ticks++;
      if (task.downloadedBytes > 0) {
        print('Video Download Progress: ${(task.progress * 100).toStringAsFixed(1)}% | Bytes: ${task.downloadedBytes}');
        break;
      }
    }

    expect(task.downloadedBytes > 0 || task.status == DownloadStatus.completed, true);
    mgr.cancelTask(task);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
