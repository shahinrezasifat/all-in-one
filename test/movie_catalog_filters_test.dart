import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/screens/movie_screen.dart';
import 'package:snaptube_pure/services/movie_repository_service.dart';
import 'package:snaptube_pure/widgets/movie_card.dart';

void main() {
  testWidgets('catalog filters work and selected source stays pinned', (
    tester,
  ) async {
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
            {
              'id': 'second',
              'name': 'Second Provider',
              'cloudStreamUrl': 'https://example.test/second.cs3',
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
    Map<String, Object> row(String title, String type, List<String> sections) =>
        {
          'title': title,
          'type': type,
          'sections': sections,
          'apiName': 'Fixture',
          'url': 'https://example.test/$title',
        };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'genres') {
        return (call.arguments['url'] as String).contains('Feature')
            ? ['Family', 'Germany']
            : <String>[];
      }
      if (call.method != 'catalog') return null;
      if (call.arguments['providerId'] == 'second') {
        return call.arguments['page'] == 1
            ? [
                row('Second source feature', 'Movie', ['Action']),
              ]
            : [];
      }
      return switch (call.arguments['page']) {
        1 => [
          row('Feature one', 'Movie', ['Sci-Fi Movies']),
          row('Feature one', 'Movie', ['Action']),
          row('Series one', 'TvSeries', ['Crime Series']),
        ],
        2 => [
          row('Anime one', 'Anime', ['Recent Episodes']),
        ],
        _ => [],
      };
    });

    await tester.pumpWidget(const MaterialApp(home: MovieScreen()));
    await tester.pumpAndSettle();
    Iterable<String> titles() => tester
        .widgetList<MovieCard>(find.byType(MovieCard))
        .map((card) => card.movie.title);

    await tester.tap(find.text('Movies').last);
    await tester.pumpAndSettle();
    expect(titles(), ['Feature one']);

    await tester.tap(find.text('Series').first);
    await tester.pumpAndSettle();
    expect(titles(), ['Series one']);

    await tester.tap(find.text('Anime').first);
    await tester.pumpAndSettle();
    expect(titles(), ['Anime one']);

    await tester.tap(find.text('Genres'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Science Fiction'));
    await tester.pumpAndSettle();
    expect(titles(), ['Feature one']);

    await tester.tap(find.text('Genres'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find more genres'));
    await tester.pumpAndSettle();
    expect(find.text('Germany'), findsNothing);
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    expect(titles(), ['Feature one']);

    await tester.tap(find.byTooltip('Change movie source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Provider'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('movie_selected_source'), ['fixture', 'second']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(home: MovieScreen()));
    await tester.pumpAndSettle();
    expect(titles(), ['Second source feature']);

    final service = MovieRepositoryService.instance;
    await service.toggleExtension('fixture', 'second', false);
    await tester.pumpAndSettle();
    expect(find.text('Source unavailable · Choose source'), findsOneWidget);
    expect(titles(), isEmpty);
    expect(service.repositories.single.providers.last.isInstalled, isTrue);

    await service.toggleExtension('fixture', 'second', true);
    await tester.pumpAndSettle();
    expect(titles(), ['Second source feature']);
  });
}
