import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/screens/movie_screen.dart';
import 'package:snaptube_pure/services/movie_repository_service.dart';
import 'package:snaptube_pure/services/provider_engine/provider_engine_service.dart';

void main() {
  testWidgets('legacy installs survive migration and repository refresh', (
    tester,
  ) async {
    const repoUrl = 'https://example.test/repo/index.json';
    SharedPreferences.setMockInitialValues({
      'infinity_loop_movie_repos_seeded_v12': true,
      'infinity_loop_movie_repos_v12_catalog35': jsonEncode([
        {
          'id': 'retained',
          'name': 'Retained repo',
          'url': repoUrl,
          'ecosystem': 'zangetsu',
          'providers': [
            {'id': 'old', 'name': 'Old', 'isInstalled': true},
          ],
        },
      ]),
    });

    final service = MovieRepositoryService.instance;
    final engine = ProviderEngineService.instance;
    await tester.runAsync(() => service.ready);
    expect(service.repositories.single.id, 'retained');
    expect(service.repositories.single.providers.single.isInstalled, isTrue);
    await tester.runAsync(() => service.uninstallExtension("retained", "old"));
    expect(engine.catalogSources, isEmpty);

    // CloudStream manifest URLs are resolved against the nested plugin list.
    const cloudRepo = 'https://example.test/cloud/repo.json';
    const packageUrl = 'https://example.test/cloud/build/Archive.cs3';
    final cloudClient = MockClient((request) async {
      final payload = switch (request.url.path) {
        '/cloud/repo.json' => {
          'name': 'Archive',
          'pluginLists': ['build/plugins.json'],
        },
        '/cloud/build/plugins.json' => [
          {
            'internalName': 'Archive',
            'url': 'Archive.cs3',
            'tvTypes': ['Movie'],
          },
          {
            'internalName': 'Adult',
            'url': 'Adult.cs3',
            'tvTypes': ['NSFW'],
          },
        ],
        _ => throw StateError('Unexpected repository URL'),
      };
      return http.Response(jsonEncode(payload), 200);
    });
    expect(
      await tester.runAsync(
        () => http.runWithClient(
          () => service.addCustomRepository(
            '',
            'cloudstreamrepo://example.test/cloud/repo.json',
          ),
          () => cloudClient,
        ),
      ),
      isTrue,
    );
    final cloud = service.repositories.firstWhere((r) => r.url == cloudRepo);
    expect(cloud.providers.first.cloudStreamUrl, packageUrl);
    expect(cloud.providers.last.isAdult, isTrue);
    expect(cloud.providers.every((provider) => !provider.isInstalled), isTrue);

    final calls = <String>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('snaptube_pure/cloudstream');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          expect(call.arguments['repoId'], cloud.id);
          switch (call.method) {
            case 'install':
              expect(call.arguments['url'], packageUrl);
              return null;
            case 'catalog':
              return [
                {
                  'title': 'Film',
                  'url': 'https://example.test/film',
                  'apiName': 'Archive',
                },
              ];
            case 'resolve':
              expect(call.arguments['apiName'], 'Archive');
              if (call.arguments['episodeData'] == 'episode-2') {
                return [
                  for (final height in [720, 1080])
                    {
                      'url': 'https://example.test/episode-2.webm',
                      'name': 'Archive',
                      'quality': height,
                      'headers': <String, String>{},
                    },
                ];
              }
              return [
                {
                  'url': 'https://example.test/film.m3u8',
                  'name': 'Archive HD',
                  'quality': 1080,
                  'hls': true,
                  'headers': {'Referer': 'https://example.test/'},
                },
              ];
            case 'episodes':
              return [
                {'url': 'episode-1', 'number': 1, 'season': 2},
                {'url': 'episode-2', 'number': 2, 'season': 2},
              ];
            case 'delete':
              return null;
          }
          throw MissingPluginException();
        });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    await tester.runAsync(() => engine.installExtension(cloud.id, 'Archive'));
    final movies = await tester.runAsync(
      () => engine.fetchCatalog(repoId: cloud.id, providerId: 'Archive'),
    );
    final streams = await tester.runAsync(
      () => engine.resolveStreams(movies!.single),
    );
    expect(streams!.single.format, 'm3u8');
    expect(streams.single.headers['Referer'], 'https://example.test/');
    final episodes = await tester.runAsync(
      () => engine.episodesFor(movies!.single),
    );
    expect(episodes!.map((episode) => episode.number), [1, 2]);
    expect(episodes.last.season, 2);
    final episodeFormats = await tester.runAsync(
      () => engine.resolveStreams(
        movies!.single,
        episode: episodes.last,
        keepAllFormats: true,
      ),
    );
    expect(episodeFormats!.map((source) => source.resolution), [
      '720p',
      '1080p',
    ]);
    expect(episodeFormats.every((source) => source.format == 'webm'), isTrue);
    await tester.runAsync(
      () => service.uninstallExtension(cloud.id, 'Archive'),
    );
    await tester.runAsync(() => service.deleteRepository(cloud.id));
    expect(engine.catalogSources, isEmpty);
    expect(calls, [
      'install',
      'catalog',
      'resolve',
      'episodes',
      'resolve',
      'delete',
      'delete',
    ]);

    await tester.pumpWidget(const MaterialApp(home: MovieScreen()));
    await tester.pump();
    expect(find.text('Install a source in Provider Hub'), findsOneWidget);
    expect(find.text('Trending'), findsNothing);
    expect(find.text('Browse Installed Sources'), findsNothing);

    await tester.tap(find.text('Install a source in Provider Hub'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    for (final label in [
      'CloudStream Extensions',
      'Native JS Streaming Engines',
      'Aniyomi Anime Extensions',
      'Mihon Extensions',
      'LNReader Plugins',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    var version = 1;
    final client = MockClient((request) async {
      expect(request.url.toString(), repoUrl);
      return http.Response(
        jsonEncode({
          'sources': [
            if (version < 3)
              {
                'id': 'original',
                'name': 'Original Name',
                'file': 'providers/original.js',
                'logo': 'icons/original.png',
                'version': version,
              },
            if (version > 1)
              {'id': 'new', 'name': 'New', 'file': 'providers/new.js'},
          ],
        }),
        200,
      );
    });
    Future<bool?> refresh() => tester.runAsync(
      () => http.runWithClient(
        () => service.refreshRepository('retained'),
        () => client,
      ),
    );

    expect(await refresh(), isTrue);
    final provider = service.repositories.single.providers.single;
    expect(provider.name, 'Original Name');
    expect(provider.iconUrl, 'https://example.test/repo/icons/original.png');
    expect(
      provider.scriptUrl,
      'https://example.test/repo/providers/original.js',
    );
    expect(provider.isInstalled, isFalse);
    expect(engine.catalogSources, isEmpty);

    await tester.runAsync(
      () => service.installExtension('retained', 'original'),
    );
    version = 2;
    expect(await refresh(), isTrue);
    final providers = service.repositories.single.providers;
    expect(providers.first.version, '2');
    expect(providers.first.isInstalled, isTrue);
    expect(providers.last.isInstalled, isFalse);
    expect(engine.catalogSources.single.provider.id, 'original');
    version = 3;
    expect(await refresh(), isTrue);
    expect(engine.catalogSources.single.provider.id, 'original');
    await tester.runAsync(
      () => service.uninstallExtension('retained', 'original'),
    );
    expect(engine.catalogSources, isEmpty);
  });
}
