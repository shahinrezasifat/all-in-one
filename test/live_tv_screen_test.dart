import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/screens/movie_screen.dart';
import 'package:snaptube_pure/screens/mpv_player_screen.dart';
import 'package:snaptube_pure/widgets/home_banner.dart';

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
      // Live TV is routed through the shared libmpv player with isLiveTv.
      expect(find.byType(MpvPlayerScreen), findsOneWidget);
      expect(
        tester.widget<MpvPlayerScreen>(find.byType(MpvPlayerScreen)).isLiveTv,
        isTrue,
      );
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
