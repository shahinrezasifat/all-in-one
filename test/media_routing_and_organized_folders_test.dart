import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/services/download_manager.dart';
import 'package:snaptube_pure/services/player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('DownloadTask correctly distinguishes Image, Audio, and Video tasks', () {
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
  });

  test('DownloadManager organizes completed tasks by Website and Channel', () async {
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
  });

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
