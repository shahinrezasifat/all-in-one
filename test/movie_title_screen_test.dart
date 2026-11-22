import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/movie_model.dart';
import 'package:snaptube_pure/screens/movie_title_screen.dart';

void main() {
  testWidgets('series details fit a narrow screen and expose episode actions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'episodes' => [
          {'url': 'first', 'title': 'The opening episode', 'number': 1},
          {'url': 'second', 'title': 'The next episode', 'number': 2},
        ],
        'resolve' => [
          {
            'url': 'https://example.test/episode.mp4',
            'name': 'Fixture server',
            'quality': 720,
            'headers': <String, String>{},
          },
          if ((call.arguments as Map)['episodeData'] == 'first')
            {
              'url': 'https://example.test/first-fhd.mp4',
              'name': 'Fixture server',
              'quality': 1080,
              'headers': <String, String>{},
            },
        ],
        _ => null,
      };
    });

    final movie = MovieItem(
      id: 'fixture-title',
      title: 'A series with a long title',
      posterUrl: '',
      backdropUrl: '',
      year: 2025,
      rating: 0,
      quality: '',
      genres: const [],
      type: 'series',
      synopsis: '',
      duration: '',
      repoId: 'fixture',
      repoName: 'Fixture',
      providerId: 'series',
      providerName: 'Series source',
      detailUrl: 'https://example.test/series',
      sources: const [],
    );
    for (final theme in [ThemeData.light(), ThemeData.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: MovieTitleScreen(movie: movie),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Series details'), findsOneWidget);
      expect(find.text('2 episodes'), findsOneWidget);
      final appBar = tester.getRect(find.byType(AppBar));
      final backdrop = tester.getRect(find.byType(ListView).first);
      expect(backdrop.top, appBar.bottom);

      await tester.tap(find.text('Full season'));
      await tester.pumpAndSettle();
      expect(find.text('Choose language'), findsOneWidget);
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(find.text('Choose resolution'), findsOneWidget);
      expect(find.text('720p'), findsOneWidget);
      expect(find.text('1080p'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.text('The opening episode'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Play 720p from Fixture server'), findsOneWidget);
      expect(
        find.byTooltip('Download 720p from Fixture server'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
