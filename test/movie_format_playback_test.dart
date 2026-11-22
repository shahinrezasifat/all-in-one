import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/movie_model.dart';
import 'package:snaptube_pure/screens/movie_title_screen.dart';
import 'package:snaptube_pure/services/provider_engine/provider_engine_service.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  testWidgets(
    'movie shows available formats while resolving and plays the selected source',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({
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
                'id': 'series',
                'name': 'Series source',
                'cloudStreamUrl': 'https://example.test/source.cs3',
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
      final remote = Completer<List<Map<String, Object?>>>();
      final calls = <String>[];
      int? requestId;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'resolve') {
          requestId = (call.arguments as Map)['requestId'] as int?;
          return remote.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final previous = VideoPlayerPlatform.instance;
      final player = _SelectedSourcePlayer();
      VideoPlayerPlatform.instance = player;
      addTearDown(() => VideoPlayerPlatform.instance = previous);

      const source = MovieSource(
        serverName: 'Direct',
        resolution: '1080p',
        downloadUrl: 'https://example.test/original.mp4',
        fileSize: '',
      );
      const movie = MovieItem(
        id: 'fixture-movie',
        title: 'Movie with several formats',
        posterUrl: '',
        backdropUrl: '',
        year: 2025,
        rating: 0,
        quality: '',
        genres: [],
        type: 'movie',
        synopsis: '',
        duration: '',
        repoId: 'fixture',
        repoName: 'Fixture',
        providerId: 'series',
        detailUrl: 'https://example.test/movie',
        sources: [source],
      );
      await tester.pumpWidget(
        const MaterialApp(home: MovieTitleScreen(movie: movie)),
      );
      await tester.pump();
      expect(find.text(movie.title), findsOneWidget);
      expect(find.byTooltip('Play 1080p from Direct'), findsOneWidget);
      for (var i = 0; i < 6 && calls.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(calls, ['resolve']);

      final format = {
        'url': 'https://example.test/selected.webm',
        'name': 'Fixture 4K',
        'quality': 0,
        'headers': <String, String>{},
      };
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('resolvedFormat', {
            'requestId': requestId,
            'format': format,
          }),
        ),
        (_) {},
      );
      await tester.pump();
      final play = find.byTooltip('Play 2160p from Fixture 4K');
      await tester.ensureVisible(play);
      await tester.tap(play);
      remote.complete([format]);
      await tester.pumpAndSettle();
      expect(player.opens, ['https://example.test/selected.webm']);
      expect(
        find.textContaining('2160p from Fixture 4K could not play'),
        findsOneWidget,
      );
      expect(calls, ['resolve']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('Hindi is selected and duplicate qualities share one row', (
    tester,
  ) async {
    const movie = MovieItem(
      id: 'language-fixture',
      title: 'Languages fixture',
      posterUrl: '',
      backdropUrl: '',
      year: 2025,
      rating: 0,
      quality: '',
      genres: [],
      type: 'movie',
      synopsis: '',
      duration: '',
      repoId: '',
      repoName: '',
      sources: [
        MovieSource(
          serverName: 'Player 1 - Tamil',
          resolution: '720p',
          downloadUrl: 'https://example.test/tamil.mp4',
          fileSize: '',
        ),
        MovieSource(
          serverName: 'Player 1 - Hindi',
          resolution: '1080p',
          downloadUrl: 'https://example.test/hindi.mp4',
          fileSize: '',
        ),
        MovieSource(
          serverName: 'Player 2 - Hindi',
          resolution: '1080p',
          downloadUrl: 'https://example.test/hindi-alternative.mp4',
          fileSize: '',
        ),
        MovieSource(
          serverName: 'Player 1 - Hindi',
          resolution: 'Auto',
          downloadUrl: 'https://example.test/hindi-auto-1.mp4',
          fileSize: '',
        ),
        MovieSource(
          serverName: 'Player 3 - Hindi',
          resolution: 'Auto',
          downloadUrl: 'https://example.test/hindi-auto-2.mp4',
          fileSize: '',
        ),
      ],
    );
    await tester.pumpWidget(
      const MaterialApp(home: MovieTitleScreen(movie: movie)),
    );
    await tester.pumpAndSettle();
    final hindi = find.widgetWithText(ChoiceChip, 'Hindi');
    final tamil = find.widgetWithText(ChoiceChip, 'Tamil');
    expect(tester.widget<ChoiceChip>(hindi).selected, isTrue);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('720p'), findsNothing);
    await tester.tap(find.text('MP4 · 2 sources').first);
    await tester.pumpAndSettle();
    expect(find.text('Player 2 - Hindi'), findsOneWidget);
    Navigator.of(tester.element(find.text('Player 2 - Hindi'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(tamil);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(tamil).selected, isTrue);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('1080p'), findsNothing);
  });

  test('adaptive format rows use resolutions from the master playlist', () async {
    final originalOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = originalOverrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..write('#EXTM3U\n')
        ..write(
          '#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=3840x1608,AUDIO="a"\nuhd.m3u8\n',
        )
        ..write(
          '#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080\nhd.m3u8\n',
        );
      request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/master.m3u8';
    final formats = await ProviderEngineService.instance.adaptiveMovieFormats(
      MovieSource(
        serverName: 'HLS',
        resolution: 'Auto',
        downloadUrl: url,
        fileSize: '',
        format: 'm3u8',
      ),
    );
    expect(formats.map((source) => source.resolution), ['2160p', '1080p']);
    expect(formats.every((source) => source.streamUrl == url), isTrue);
    expect(formats.every((source) => source.downloadUrl == url), isTrue);
    expect(formats.map((source) => source.hlsVariantResolution), [
      '3840x1608',
      '1920x1080',
    ]);
    expect(
      MovieSource.fromJson(formats.first.toJson()).hlsVariantResolution,
      '3840x1608',
    );
  });
}

class _SelectedSourcePlayer extends VideoPlayerPlatform {
  final opens = <String?>[];

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    opens.add(options.dataSource.uri);
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.error(
    PlatformException(code: 'test-source-unavailable', message: 'Unavailable'),
  );

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> dispose(int playerId) async {}
}
