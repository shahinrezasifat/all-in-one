import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/models/movie_model.dart';
import 'package:snaptube_pure/screens/downloads_screen.dart';
import 'package:snaptube_pure/services/download_manager.dart';
import 'package:snaptube_pure/services/player_service.dart';
import 'package:snaptube_pure/widgets/movie_card.dart';
import 'package:snaptube_pure/widgets/remote_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  testWidgets(
    'Completed films and series use poster cards beside website folders',
    (tester) async {
      final manager = DownloadManager.instance;
      await tester.runAsync(() => manager.ready);
      const poster = 'https://example.com/drama.jpg';
      const series = MovieItem(
        id: 'fixture-series',
        title: 'Fixture Series',
        posterUrl: poster,
        backdropUrl: '',
        year: 2026,
        rating: 0,
        quality: '',
        genres: [],
        type: 'series',
        synopsis: '',
        duration: '',
        repoId: '',
        repoName: '',
        sources: [],
      );
      DownloadTask completed(
        String title, {
        String category = 'movie',
        MovieItem? series,
        String? season,
        String? episodeUrl,
        String? savePath,
      }) => DownloadTask(
        id: title,
        title: title,
        author: 'Fixture Channel',
        thumbnailUrl: category == 'movie' ? poster : '',
        formatLabel: '720p',
        ext: 'mp4',
        isAudio: false,
        category: category,
        originalUrl: category == 'movie'
            ? 'https://movie-source.example/video.mp4'
            : 'https://www.youtube.com/watch?v=fixture',
        status: DownloadStatus.completed,
        series: series,
        seriesSeason: season,
        seriesEpisodeUrl: episodeUrl,
        savePath: savePath,
      );
      final tasks = [
        completed('Fixture Film'),
        completed('Episode 01', series: series, season: 'Season 2'),
        completed(
          'Episode 02',
          series: series,
          episodeUrl: 'legacy-episode',
          savePath: 'Downloads/Fixture Series/Season 5/Episode 02.mp4',
        ),
        completed('Fixture Series - S5E3'),
        completed('Website Clip', category: 'video'),
      ];
      for (final task in tasks) {
        manager.addCompletedTaskForTesting(task);
      }
      addTearDown(() {
        for (final task in tasks) {
          manager.deleteTask(task);
        }
      });

      await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
      await tester.tap(find.text('Downloaded'));
      await tester.pumpAndSettle();

      expect(find.text('Fixture Film'), findsOneWidget);
      expect(find.text('Fixture Series'), findsOneWidget);
      expect(find.text('YouTube'), findsOneWidget);
      expect(find.text('Website Clip'), findsNothing);
      final grid = tester.widgetList<GridView>(find.byType(GridView)).first;
      expect(grid.gridDelegate, MovieCard.catalogGrid);
      expect(
        tester
            .widgetList<SmartNetworkImage>(find.byType(SmartNetworkImage))
            .map((image) => image.url),
        [poster, poster],
      );

      await tester.tap(find.byTooltip('Episodes'));
      await tester.pumpAndSettle();
      expect(find.text('Downloaded seasons'), findsOneWidget);
      expect(find.text('Season 2'), findsOneWidget);
      expect(find.text('Season 5'), findsOneWidget);
      expect(find.text('Season 2 · 1 downloaded'), findsOneWidget);
      expect(find.text('Episode 01'), findsOneWidget);
      await tester.tap(find.text('Season 5'));
      await tester.pumpAndSettle();
      expect(find.text('Season 5 · 2 downloaded'), findsOneWidget);
      expect(find.text('Episode 01'), findsNothing);
      expect(find.text('Episode 02'), findsOneWidget);

      Navigator.of(tester.element(find.text('Downloaded seasons'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture Film'));
      await tester.pump();
      expect(PlayerService.instance.title, 'Fixture Film');
      expect(find.byType(BottomSheet), findsNothing);
    },
  );

  test(
    'DownloadTask correctly distinguishes Image, Audio, and Video tasks',
    () {
      final imageTask = DownloadTask(
        id: 'img_1',
        title: 'Cover Image',
        author: 'MrBeast',
        thumbnailUrl: 'https://example.com/thumb.jpg',
        formatLabel: 'Cover Thumbnail (JPG)',
        ext: 'jpg',
        isAudio: false,
        category: 'image',
        originalUrl: 'https://www.youtube.com/watch?v=123',
      );
      expect(imageTask.isImageTask, isTrue);
      expect(imageTask.isAudioTask, isFalse);
      expect(imageTask.isVideoTask, isFalse);

      final audioTask = DownloadTask(
        id: 'aud_1',
        title: 'Hit Song',
        author: 'Rick Astley',
        thumbnailUrl: 'https://example.com/audio.jpg',
        formatLabel: '320 kbps MP3',
        ext: 'mp3',
        isAudio: true,
        category: 'audio',
        originalUrl: 'https://www.youtube.com/watch?v=456',
      );
      expect(audioTask.isImageTask, isFalse);
      expect(audioTask.isAudioTask, isTrue);
      expect(audioTask.isVideoTask, isFalse);

      final videoTask = DownloadTask(
        id: 'vid_1',
        title: 'Epic Video',
        author: 'MrBeast',
        thumbnailUrl: 'https://example.com/video.jpg',
        formatLabel: '1080p Full HD',
        ext: 'mp4',
        isAudio: false,
        category: 'video',
        originalUrl: 'https://www.youtube.com/watch?v=789',
      );
      expect(videoTask.isImageTask, isFalse);
      expect(videoTask.isAudioTask, isFalse);
      expect(videoTask.isVideoTask, isTrue);
    },
  );

  test(
    'DownloadManager organizes completed tasks by Website and Channel',
    () async {
      final manager = DownloadManager.instance;
      await manager.ready;

      // Simulate completed tasks from multiple websites and channels
      final t1 = DownloadTask(
        id: 'test_yt_mrbeast_video',
        title: 'How I Get 100M Views',
        author: 'MrBeast',
        thumbnailUrl: 'https://example.com/thumb1.jpg',
        formatLabel: '1080p MP4',
        ext: 'mp4',
        isAudio: false,
        category: 'video',
        originalUrl: 'https://www.youtube.com/watch?v=test1',
        status: DownloadStatus.completed,
      );

      final t2 = DownloadTask(
        id: 'test_yt_mrbeast_thumb',
        title: 'How I Get 100M Views - Cover',
        author: 'MrBeast',
        thumbnailUrl: 'https://example.com/thumb2.jpg',
        formatLabel: 'Thumbnail JPG',
        ext: 'jpg',
        isAudio: false,
        category: 'image',
        originalUrl: 'https://www.youtube.com/watch?v=test1',
        status: DownloadStatus.completed,
      );

      final t3 = DownloadTask(
        id: 'test_yt_rick_audio',
        title: 'Never Gonna Give You Up',
        author: 'Rick Astley',
        thumbnailUrl: 'https://example.com/thumb3.jpg',
        formatLabel: '320kbps MP3',
        ext: 'mp3',
        isAudio: true,
        category: 'audio',
        originalUrl: 'https://www.youtube.com/watch?v=test2',
        status: DownloadStatus.completed,
      );

      final t4 = DownloadTask(
        id: 'test_ph_video',
        title: 'Model Clip',
        author: 'TopModel',
        thumbnailUrl: 'https://example.com/thumb4.jpg',
        formatLabel: '720p MP4',
        ext: 'mp4',
        isAudio: false,
        category: 'video',
        originalUrl: 'https://www.pornhub.com/view_video.php?viewkey=ph123',
        status: DownloadStatus.completed,
      );

      // Inject into manager completed list for testing
      manager.addCompletedTaskForTesting(t1);
      manager.addCompletedTaskForTesting(t2);
      manager.addCompletedTaskForTesting(t3);
      manager.addCompletedTaskForTesting(t4);

      final websiteMap = manager.organizedWebsiteFolders;

      // Verify YouTube website folder exists
      expect(websiteMap.containsKey('YouTube'), isTrue);
      final ytChannels = websiteMap['YouTube']!;
      expect(ytChannels.containsKey('MrBeast'), isTrue);
      expect(ytChannels.containsKey('Rick Astley'), isTrue);

      // Verify MrBeast channel contains both video and thumbnail
      final mrBeastTasks = ytChannels['MrBeast']!;
      expect(mrBeastTasks.any((t) => t.id == 'test_yt_mrbeast_video'), isTrue);
      expect(mrBeastTasks.any((t) => t.id == 'test_yt_mrbeast_thumb'), isTrue);

      // Verify Pornhub website folder exists with TopModel channel
      expect(websiteMap.containsKey('Pornhub'), isTrue);
      final phChannels = websiteMap['Pornhub']!;
      expect(phChannels.containsKey('TopModel'), isTrue);

      // Clean up test tasks
      manager.deleteTask(t1);
      manager.deleteTask(t2);
      manager.deleteTask(t3);
      manager.deleteTask(t4);
    },
  );

  test('PlayerService does not play images in video player', () {
    final player = PlayerService.instance;
    final imageTask = DownloadTask(
      id: 'img_test_play',
      title: 'Image Test',
      author: 'Author',
      thumbnailUrl: 'https://example.com/test.jpg',
      formatLabel: 'Cover JPG',
      ext: 'jpg',
      isAudio: false,
      category: 'image',
      originalUrl: 'https://example.com',
      savePath: 'C:/dummy/test.jpg',
    );

    // Calling playDownloadTask on image should not throw or set video engine running
    player.playDownloadTask(imageTask);
  });
}
