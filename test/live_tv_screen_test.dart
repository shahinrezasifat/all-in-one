import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/screens/movie_screen.dart';
import 'package:snaptube_pure/screens/movie_player_screen.dart';
import 'package:snaptube_pure/widgets/home_banner.dart';

// The video player plugin exposes its platform contract for test fakes.
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  testWidgets(
    'live sources autoplay and ambiguous sources honor both mode choices',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 880);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'movie_banner_autoplay': false,
        'snaptube_movie_repos_manual_install_v1': true,
        'infinity_loop_movie_repos_seeded_v13': true,
        'infinity_loop_movie_repos_catalog_v13': jsonEncode([
          {
            'id': 'fixture',
            'url': 'https://example.test/repo.json',
            'name': 'Fixture',
            'ecosystem': 'cloudstream',
            'isEnabled': true,
            'providers': [
              {
                'id': 'fixture-provider',
                'name': 'Fixture Provider',
                'cloudStreamUrl': 'https://example.test/fixture.cs3',
                'isEnabled': true,
                'isInstalled': true,
              },
            ],
          },
        ]),
      });
      const channel = MethodChannel('snaptube_pure/cloudstream');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      Map<String, Object> row(
        String title,
        String type,
        List<String> sections,
      ) => {
        'title': title,
        'type': type,
        'sections': sections,
        'apiName': 'Fixture',
        'url': 'https://example.test/$title.m3u8',
      };
      var mixedCatalog = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'catalog') return [];
        if (call.arguments['page'] != 1) return [];
        return [
          row('News One', 'Live', ['BD | Bangla']),
          if (mixedCatalog)
            row('Feature Two', 'Movie', ['Action'])
          else
            row('News Two', 'Live', ['IN | Hindi']),
        ];
      });

      final previousPlayer = VideoPlayerPlatform.instance;
      final player = _LiveVideoPlatform();
      VideoPlayerPlatform.instance = player;
      addTearDown(() => VideoPlayerPlatform.instance = previousPlayer);

      await tester.pumpWidget(const MaterialApp(home: MovieScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Live TV'), findsOneWidget);
      expect(find.text('IPTV · 2 channels loaded'), findsOneWidget);
      expect(find.byType(HomeBanner), findsNothing);
      expect(find.text('Genres'), findsNothing);
      expect(find.text('Hindi'), findsOneWidget);
      expect(find.text('India'), findsOneWidget);

      await tester.tap(find.text('Bangladesh'));
      await tester.pumpAndSettle();
      expect(find.text('News One'), findsOneWidget);
      expect(find.text('News Two'), findsNothing);
      await tester.tap(find.text('News One'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      // Live TV is routed through the shared player with isLiveTv enabled.
      expect(find.byType(MoviePlayerScreen), findsOneWidget);
      expect(
        tester
            .widget<MoviePlayerScreen>(find.byType(MoviePlayerScreen))
            .isLiveTv,
        isTrue,
      );
      expect(player.createRequests, 1);
      expect(player.playRequests, 1);
      expect(find.textContaining('Download'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      mixedCatalog = true;
      for (final mode in ['Movies', 'IPTV']) {
        await tester.pumpWidget(const MaterialApp(home: MovieScreen()));
        await tester.pumpAndSettle();
        final prompt = find.byType(AlertDialog);
        expect(find.text('Choose source type'), findsOneWidget);
        await tester.tap(
          find.descendant(of: prompt, matching: find.text(mode)),
        );
        await tester.pumpAndSettle();
        expect(prompt, findsNothing);
        if (mode == 'IPTV') {
          expect(find.text('Live TV'), findsOneWidget);
          expect(find.text('News One'), findsOneWidget);
          expect(find.text('Feature Two'), findsNothing);
          expect(find.text('Genres'), findsNothing);
        } else {
          expect(find.text('Live TV'), findsNothing);
          expect(find.text('Genres'), findsOneWidget);
          expect(find.text('News One'), findsNothing);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
  );
}

class _LiveVideoPlatform extends VideoPlayerPlatform {
  int playRequests = 0;
  int createRequests = 0;

  @override
  Future<void> init() async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async =>
      ++createRequests;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      size: const Size(640, 360),
      duration: Duration.zero,
    ),
  );

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> play(int playerId) async {
    playRequests++;
  }

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}
