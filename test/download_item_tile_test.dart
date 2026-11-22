import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/theme/app_colors.dart';
import 'package:snaptube_pure/widgets/download_item_tile.dart';

void main() {
  testWidgets('download card animates until the transfer begins', (
    tester,
  ) async {
    final task = DownloadTask(
      id: 'fixture',
      title: 'Video',
      author: 'Creator',
      thumbnailUrl: '',
      formatLabel: '1080p',
      ext: 'mp4',
      isAudio: false,
      category: 'video',
      originalUrl: 'https://example.test/video',
      status: DownloadStatus.downloading,
      totalBytes: 4096,
      statusNote: 'Checking download size…',
    );
    Future<void> render() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DownloadItemTile(task: task)),
      ),
    );

    await render();
    expect(find.text('Analyzing video…'), findsOneWidget);
    expect(find.text('0 KB/s'), findsNothing);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, isNull);
    await tester.pump(const Duration(milliseconds: 500));

    task.downloadedBytes = 1024;
    task.speedBytesPerSec = 4096;
    await render();
    expect(find.text('Analyzing video…'), findsNothing);
    final active = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(active.value, .25);
    expect(active.color, AppColors.primary);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('4 KB/s'), findsOneWidget);

    task.totalBytesIsEstimate = true;
    await render();
    expect(find.text('≈25%'), findsOneWidget);

    task.totalBytes = 0;
    await render();
    expect(find.textContaining('Total unknown'), findsOneWidget);
    expect(
      tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      ).value,
      isNull,
    );

    task.downloadedBytes = 0;
    task.status = DownloadStatus.paused;
    await render();
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Analyzing video…'), findsNothing);

    task.status = DownloadStatus.failed;
    await render();
    expect(find.text('Download Failed'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .color,
      AppColors.primary,
    );
  });
}
