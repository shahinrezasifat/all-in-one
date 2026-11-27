import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/services/player_service.dart';
import 'package:snaptube_pure/services/download_manager.dart';
import 'package:snaptube_pure/widgets/youtube_popup_player.dart';

void main() {
  testWidgets('player keeps the public download URL separate from local playback', (
    tester,
  ) async {
    final player = PlayerService.instance;
    addTearDown(player.close);
    const sourceUrl = 'https://youtu.be/aqz-KE-bpKQ';
    void play(String url) => player.playDownloadTask(
      DownloadTask(
        id: 'saved-video',
        title: 'Saved video',
        author: '',
        thumbnailUrl: '',
        formatLabel: 'MP4',
        ext: 'mp4',
        isAudio: false,
        category: 'video',
        originalUrl: url,
        savePath: '/fixtures/saved-video.mp4',
      ),
    );

    play(sourceUrl);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [YouTubePopupPlayer()])),
      ),
    );
    expect(player.filePath, '/fixtures/saved-video.mp4');
    expect(player.downloadSourceUrl, sourceUrl);
    expect(find.text('Download'), findsOneWidget);

    play('');
    await tester.pump();
    expect(player.downloadSourceUrl, isNull);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('downloaded audio opens the dedicated audio player', (tester) async {
    final player = PlayerService.instance;
    addTearDown(player.close);
    player.playDownloadTask(
      DownloadTask(
        id: 'saved-audio',
        title: 'Downloaded song',
        author: 'Artist',
        thumbnailUrl: '',
        formatLabel: 'MP3',
        ext: 'mp3',
        isAudio: true,
        category: 'audio',
        originalUrl: '',
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [YouTubePopupPlayer()])),
      ),
    );

    expect(find.text('Audio player'), findsOneWidget);
    expect(find.text('Downloaded song'), findsOneWidget);
    expect(player.isAudioView, isTrue);
    expect(find.byKey(const ValueKey('video-player-surface')), findsNothing);
    expect(find.byTooltip('Return to video'), findsNothing);
    await tester.tap(find.byTooltip('Close audio'));
    await tester.pump();
    expect(player.isHidden, isTrue);
  });

  testWidgets('player previews horizontal scrubs and seeks on release', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final orientations = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const playbackControls = MethodChannel('snaptube_pure/playback_controls');
    final playbackCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(playbackControls, (call) async {
      playbackCalls.add(call);
      return call.method == 'brightness' ? 0.65 : 0.4;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(playbackControls, null),
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        orientations.add(call.arguments);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    // Null from platform-view create selects hybrid composition, which keeps
    // pointer events flowing to Flutter's gesture Listener over the mpv view.
    const platformViews = MethodChannel('flutter/platform_views');
    messenger.setMockMethodCallHandler(platformViews, (call) async => null);
    addTearDown(
      () => messenger.setMockMethodCallHandler(platformViews, null),
    );
    const mpvChannel = MethodChannel('snaptube_pure/mpv');
    messenger.setMockMethodCallHandler(mpvChannel, (call) async {
      if (call.method == 'getState') {
        return {
          'position': 0.0,
          'duration': 0.0,
          'playing': true,
          'tracks': '[]',
        };
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(mpvChannel, null));

    final player = PlayerService.instance;
    addTearDown(player.close);
    player.playDownloadTask(
      DownloadTask(
        id: 'preview',
        title: 'Gesture test video',
        author: 'Test channel',
        thumbnailUrl: '',
        formatLabel: 'MP4',
        ext: 'mp4',
        isAudio: false,
        category: 'video',
        originalUrl: '',
      ),
    );
    DownloadManager.instance.addCompletedTaskForTesting(
      DownloadTask(
        id: 'offline-fixture',
        title: 'Another downloaded video',
        author: '',
        thumbnailUrl: '',
        formatLabel: 'MP4',
        ext: 'mp4',
        isAudio: false,
        category: 'video',
        originalUrl: '',
        savePath: '/offline/next.mp4',
        status: DownloadStatus.completed,
      ),
    );
    player.seek(60);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [YouTubePopupPlayer()])),
      ),
    );
    await tester.pump();

    expect(find.text('Offline videos'), findsOneWidget);
    expect(find.text('Another downloaded video'), findsOneWidget);
    expect(find.text('Up next'), findsNothing);
    expect(
      tester.getCenter(find.byType(Slider)).dy,
      lessThan(tester.getCenter(find.byTooltip('Playback speed')).dy),
    );

    final y = tester.getCenter(find.byTooltip('Play')).dy;
    for (final (x, method) in [(345.0, 'brightness'), (45.0, 'volume')]) {
      final gesture = await tester.startGesture(Offset(x, y));
      await gesture.moveBy(const Offset(0, -25));
      await gesture.moveBy(const Offset(0, -25));
      await gesture.up();
      await tester.pump();
      expect(playbackCalls.last.method, method);
      expect(playbackCalls.last.arguments['delta'], greaterThan(0));
    }
    final right = await tester.startGesture(Offset(45, y));
    await right.moveBy(const Offset(28, 0));
    await right.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(player.currentSeconds, 60);
    expect(find.byTooltip('Pause'), findsNothing);
    await right.up();
    await tester.pump();
    final advanced = player.currentSeconds;
    expect(advanced, greaterThanOrEqualTo(60));

    final left = await tester.startGesture(Offset(345, y));
    await left.moveBy(const Offset(-28, 0));
    await left.moveBy(const Offset(-70, 0));
    await left.up();
    await tester.pump();
    expect(player.currentSeconds, lessThanOrEqualTo(advanced));

    expect(find.byTooltip('Repeat video'), findsNothing);
    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.byTooltip('Repeat video'), findsOneWidget);
    await tester.tap(find.byTooltip('Repeat video'));
    expect(player.isLooping, isTrue);
    await tester.tap(find.byTooltip('Close playback settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.byTooltip('Repeat video'), findsNothing);
    await tester.tap(find.byTooltip('Lock player'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.byTooltip('Unlock player'), findsOneWidget);
    await tester.tap(find.byTooltip('Unlock player'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.byTooltip('Audio only'), findsOneWidget);

    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pump();
    expect(find.text('Now playing'), findsNothing);
    expect(orientations.last, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    tester.view.physicalSize = const Size(850, 390);
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('video-player-surface'))),
      const Size(850, 390),
    );
    await tester.tap(find.byTooltip('Exit fullscreen').first);
    await tester.pump();
    expect(find.text('Now playing'), findsOneWidget);
    expect(orientations.last, ['DeviceOrientation.portraitUp']);
    await tester.tap(find.byTooltip('Audio only'));
    await tester.pump();
    expect(find.text('Audio player'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-player-surface')), findsNothing);
    await tester.tap(find.byTooltip('Return to video'));
    await tester.pump();
    expect(find.byKey(const ValueKey('video-player-surface')), findsOneWidget);
    expect(tester.takeException(), isNull);
    player.toggleLoop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
    expect(playbackCalls.last.method, 'restoreBrightness');
  });
}
