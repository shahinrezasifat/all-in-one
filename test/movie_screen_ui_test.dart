import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/movie_model.dart';
import 'package:snaptube_pure/screens/movie_screen.dart';
import 'package:snaptube_pure/widgets/home_banner.dart';
import 'package:snaptube_pure/widgets/looping_control_content.dart';

MovieItem _movie(String title) => MovieItem(
  id: title,
  title: title,
  posterUrl: '',
  backdropUrl: '',
  year: 2024,
  rating: 0,
  quality: '',
  genres: const [],
  type: 'movie',
  synopsis: '',
  duration: '',
  repoId: '',
  repoName: '',
  sources: const [],
);

void main() {
  testWidgets('control contents loop without moving the button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () {},
              child: const LoopingControlContent(
                interval: Duration(seconds: 10),
                child: Text('Watch'),
              ),
            ),
          ),
        ),
      ),
    );
    final button = find.byType(FilledButton);
    final contents = find.descendant(
      of: find.byType(LoopingControlContent),
      matching: find.byType(Transform),
    );
    final bounds = tester.getRect(button);
    await tester.pump(const Duration(seconds: 9));
    expect(tester.widget<Transform>(contents).transform.getTranslation().y, 0);
    for (final wait in [1000, 9820]) {
      await tester.pump(Duration(milliseconds: wait));
      await tester.pump(const Duration(milliseconds: 180));
      expect(tester.getRect(button), bounds);
      expect(
        tester.widget<Transform>(contents).transform.getTranslation().y,
        isNegative,
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Watch motion runs once per settled-slide trigger', (
    tester,
  ) async {
    Future<void> render(int slide) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: LoopingControlContent(
            trigger: slide,
            child: const Text('Watch'),
          ),
        ),
      ),
    );
    final motion = find.descendant(
      of: find.byType(LoopingControlContent),
      matching: find.byType(Transform),
    );
    double offset() =>
        tester.widget<Transform>(motion).transform.getTranslation().y;

    await render(1);
    await tester.pump(const Duration(seconds: 10));
    expect(offset(), 0);
    await render(2);
    await tester.pump(const Duration(milliseconds: 180));
    expect(offset(), isNegative);
    await tester.pump(const Duration(seconds: 12));
    await render(2);
    expect(offset(), 0);
  });

  testWidgets('featured carousel advances and wraps symmetrically', (
    tester,
  ) async {
    String? opened;
    final movies = [
      'First feature',
      'Second feature',
      'Third feature',
    ].map(_movie).toList();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeBanner(
            movies: movies,
            style: 'poster',
            autoPlay: true,
            onOpen: (movie) => opened = movie.title,
          ),
        ),
      ),
    );
    for (final title in [
      'First feature',
      'Second feature',
      'Third feature',
      'First feature',
    ]) {
      await tester.tap(find.text('Watch'));
      expect(opened, title);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('long press removes a title and persists the edit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'movie_banner_autoplay': false,
      'snaptube_watch_history_v1': jsonEncode([
        {'movieId': 'fixture', 'title': 'Watch history fixture'},
        {'movieId': 'other', 'title': 'Second history title'},
      ]),
    });
    await tester.pumpWidget(const MaterialApp(home: MovieScreen()));
    await tester.pumpAndSettle();
    final tile = find.text('Watch history fixture');
    await tester.scrollUntilVisible(
      tile.hitTestable(),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.longPress(tile);
    await tester.pumpAndSettle();
    expect(find.text('Remove from Continue Watching?'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(tile, findsNothing);
    final prefs = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(prefs.getString('snaptube_watch_history_v1')!) as List;
    expect(saved.map((item) => item['movieId']), ['other']);
  });
}
