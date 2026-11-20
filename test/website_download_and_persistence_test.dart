// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/models/extract_result.dart';
import 'package:snaptube_pure/models/movie_model.dart';
import 'package:snaptube_pure/services/download_manager.dart';
import 'package:snaptube_pure/services/extractor_service.dart';
import 'package:snaptube_pure/services/movie_repository_service.dart';
import 'package:snaptube_pure/services/settings_service.dart';
import 'package:snaptube_pure/services/vault_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late HttpServer server;
  late String baseUrl;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) => _handleRequest(request, server.port));
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('custom repositories survive the storage-key migration', () async {
    SharedPreferences.setMockInitialValues({
      'snaptube_movie_repos_v8_user_clean': jsonEncode([
        {
          'id': 'repo_migrated',
          'name': 'Migrated Repo',
          'description': 'Added by the user before the update',
          'url': 'https://example.com/repo.json',
          'author': 'User',
          'version': '1.0.0',
          'iconType': 'cloudstream',
          'ecosystem': 'cloudstream',
          'isEnabled': true,
          'providerCount': 1,
          'tags': ['Custom', 'User-Added'],
          'isCustom': true,
          'providers': [
            {'id': 'migrated_provider', 'name': 'Migrated Provider'},
          ],
        }
      ]),
    });

    await MovieRepositoryService.instance.ready;

    final repo = MovieRepositoryService.instance.repositories
        .firstWhere((r) => r.id == 'repo_migrated');
    expect(repo.name, 'Migrated Repo');
    expect(repo.providers.single.id, 'migrated_provider');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('snaptube_movie_repos_v8_user_clean'), isNull,
        reason: 'legacy key is removed only after migration');
    final saved = prefs.getKeys()
        .map((k) => prefs.get(k))
        .whereType<String>()
        .firstWhere((v) => v.contains('https://example.com/repo.json'));
    expect(saved, contains('repo_migrated'));
  });

  test('ordinary website pages expose their real <video> source', () async {
    final result = await ExtractorService.instance.extract('$baseUrl/watch');

    expect(result, isNotNull);
    expect(result!.videoFormats, isNotEmpty);
    expect(result.videoFormats.first.url, '$baseUrl/movie.mp4');
    expect(result.videoFormats.first.ext, 'mp4');
    expect(result.title, 'Local Test Movie');
  });

  test('web and movie downloads resume at the exact missing byte', () async {
    final expected = List<int>.generate(65536, (i) => (i * 31) % 251);
    final ranges = <String?>[];
    final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final folder = await Directory.systemTemp.createTemp('all_in_one_resume');
    addTearDown(() async {
      await media.close(force: true);
      await folder.delete(recursive: true);
    });
    media.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/stream-only') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (request.uri.path == '/movie-download.mp4' &&
          request.headers.value('X-Source-Fixture') != 'movie') {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      final start = range == 'bytes=16384-' ? 16384 : 0;
      final end = range == 'bytes=0-0' ? 1 : range == null ? 16384 : expected.length;
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.contentType = ContentType('video', 'mp4')
        ..headers.contentLength = end - start
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/${expected.length}')
        ..add(expected.sublist(start, end));
      await response.close();
    });
    final url = 'http://127.0.0.1:${media.port}';
    final manager = DownloadManager.instance;
    await manager.setDownloadDirectory(folder.path);

    final webTask = await manager.startDirectDownload(
      url: '$url/web-download.mp4',
      title: 'Resume Web Demo',
      author: 'Fixture',
      thumbnailUrl: '',
      isAudio: false,
    );
    await _waitForCompletedDownload(webTask);
    expect(await File(webTask.savePath!).readAsBytes(), expected);
    manager.deleteTask(webTask);

    final movieTask = await manager.startMovieDownload(
      movie: const MovieItem(
        id: 'resume_fixture',
        title: 'Resume Movie Demo',
        posterUrl: '',
        backdropUrl: '',
        year: 2026,
        rating: 0,
        quality: '360p',
        genres: [],
        type: 'movie',
        synopsis: '',
        duration: '',
        repoId: 'fixture',
        repoName: 'Fixture',
        sources: [],
      ),
      source: MovieSource(
        serverName: 'Fixture',
        resolution: '360p',
        downloadUrl: '$url/movie-download.mp4',
        streamUrl: '$url/stream-only',
        fileSize: '0.01 MB',
        headers: const {'X-Source-Fixture': 'movie'},
      ),
    );
    await _waitForCompletedDownload(movieTask);
    expect(await File(movieTask.savePath!).readAsBytes(), expected);
    expect(ranges.where((range) => range == 'bytes=16384-'), hasLength(2));
    manager.deleteTask(movieTask);
  });

  test('HLS master playlists are downloaded as one playable file', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = await Directory.systemTemp.createTemp('snaptube_hls_test');
    addTearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    await DownloadManager.instance.ready;
    await DownloadManager.instance.setDownloadDirectory(temp.path);

    final result = ExtractResult(
      id: 'hls_test',
      title: 'HLS Test',
      author: 'Test',
      duration: '0:08',
      thumbnailUrl: '',
      originalUrl: '$baseUrl/watch',
      platform: 'Website',
      videoFormats: [
        MediaFormat(
          id: 'web_hls_test',
          label: 'Original HLS Stream',
          ext: 'mp4',
          type: MediaType.video,
          url: '$baseUrl/master.m3u8',
          note: 'Adaptive HLS stream from the page',
        ),
      ],
      audioFormats: const [],
    );

    final task = await DownloadManager.instance.startDownload(
      video: result,
      format: result.videoFormats.first,
    );

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (task.status == DownloadStatus.downloading &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    expect(task.status, DownloadStatus.completed, reason: task.errorMessage);
    expect(task.savePath, endsWith('.mp4'));

    final file = File(task.savePath!);
    expect(file.existsSync(), true);
    expect(await file.readAsBytes(), [1, 2, 3, 4, 5, 6, 7]);
    expect(task.downloadedBytes, 7);

    DownloadManager.instance.deleteTask(task);
  });

  test('audio filenames follow the real stream container', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = await Directory.systemTemp.createTemp('snaptube_audio_test');
    addTearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    await DownloadManager.instance.ready;
    await DownloadManager.instance.setDownloadDirectory(temp.path);

    final task = await DownloadManager.instance.startDirectDownload(
      url: '$baseUrl/audio-source.webm',
      title: 'Container Test',
      author: 'Tester',
      thumbnailUrl: '',
      isAudio: true,
    );

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (task.status == DownloadStatus.downloading &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    expect(task.status, DownloadStatus.completed, reason: task.errorMessage);
    expect(task.ext, 'webm');
    expect(task.savePath, endsWith('.webm'));
    expect(await File(task.savePath!).readAsBytes(), [10, 20, 30, 40]);

    DownloadManager.instance.deleteTask(task);
  });

  test('CloudStream pluginLists manifests are parsed and persisted', () async {
    SharedPreferences.setMockInitialValues({});

    final ok = await MovieRepositoryService.instance.addCustomRepository(
      'Test Repository',
      '$baseUrl/cloudstream/repo.json',
    );

    expect(ok, true);

    final repo = MovieRepositoryService.instance.repositories.firstWhere(
      (r) => r.url == '$baseUrl/cloudstream/repo.json',
    );
    expect(repo.name, 'CloudStream Test Repo');
    expect(repo.providers.map((p) => p.id), ['alpha', 'beta']);
    expect(repo.providerCount, 2);

    final prefs = await SharedPreferences.getInstance();
    // The storage key version can change between builds; find the persisted
    // document that actually contains this repository instead of hard-coding it.
    String? saved;
    for (final key in prefs.getKeys()) {
      final value = prefs.get(key);
      if (value is String && value.contains('$baseUrl/cloudstream/repo.json')) {
        saved = value;
        break;
      }
    }
    expect(saved, isNotNull);

    final list = jsonDecode(saved!) as List<dynamic>;
    final custom = list
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['url'] == '$baseUrl/cloudstream/repo.json');
    final reloaded = MovieRepository.fromJson(custom);
    expect(reloaded.url, '$baseUrl/cloudstream/repo.json');
    expect(reloaded.providers.map((p) => p.name), ['Alpha Source', 'Beta Source']);
  });

  test('theme mode and audio preference persist across reads', () async {
    SharedPreferences.setMockInitialValues({
      'theme_mode': 'light',
      'default_audio_format': 'M4A Lossless',
    });

    await SettingsService.instance.ready;
    expect(SettingsService.instance.themeMode, ThemeMode.light);
    // Legacy "M4A Lossless" preference is migrated to the honest M4A/AAC label.
    expect(SettingsService.instance.defaultAudioFormat, 'M4A (AAC)');

    await SettingsService.instance.setThemeMode(ThemeMode.dark);
    await SettingsService.instance.setDefaultAudioFormat('256 kbps MP3');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
    expect(prefs.getString('default_audio_format'), '256 kbps MP3');
  });

  test('vault PIN is stored, verified and survives a reload', () async {
    SharedPreferences.setMockInitialValues({});

    await VaultService.instance.ready;
    expect(VaultService.instance.hasPin, false);

    expect(await VaultService.instance.setPin('1234'), true);
    expect(VaultService.instance.hasPin, true);
    expect(VaultService.instance.isUnlocked, true);

    VaultService.instance.lock();
    expect(VaultService.instance.isUnlocked, false);
    expect(await VaultService.instance.unlock('9999'), false);
    expect(await VaultService.instance.unlock('1234'), true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('vault_pin_hash'), isNotNull);
  });
}

Future<void> _waitForCompletedDownload(DownloadTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (task.status == DownloadStatus.downloading &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(task.status, DownloadStatus.completed, reason: task.errorMessage);
  expect(task.payloadVerified, isTrue);
}

Future<void> _handleRequest(HttpRequest request, int port) async {
  final path = request.uri.path;
  final baseUrl = 'http://127.0.0.1:$port';

  if (path == '/watch') {
    _write(request, '''
<!doctype html>
<html><head>
<title>Local Test Movie</title>
<meta property="og:image" content="$baseUrl/poster.jpg">
</head><body>
<video controls><source src="/movie.mp4" type="video/mp4"></video>
</body></html>
''', contentType: ContentType.html);
    return;
  }

  if (path == '/movie.mp4') {
    final bytes = List<int>.generate(2048, (i) => i % 256);
    if (request.method == 'HEAD') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('video', 'mp4')
        ..headers.contentLength = bytes.length;
      await request.response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.startsWith('bytes=')) {
      final parts = range.substring(6).split('-');
      final start = int.tryParse(parts.first) ?? 0;
      final end = parts.length > 1 && parts[1].isNotEmpty
          ? int.tryParse(parts[1]) ?? bytes.length - 1
          : bytes.length - 1;
      final slice = bytes.sublist(start.clamp(0, bytes.length), (end + 1).clamp(0, bytes.length));
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.contentType = ContentType('video', 'mp4')
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${start + slice.length - 1}/${bytes.length}')
        ..headers.contentLength = slice.length
        ..add(slice);
      await request.response.close();
      return;
    }
    request.response
      ..headers.contentType = ContentType('video', 'mp4')
      ..headers.contentLength = bytes.length
      ..add(bytes);
    await request.response.close();
    return;
  }

  if (path == '/master.m3u8') {
    _write(request, '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=500000
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000
high/index.m3u8
''', contentType: ContentType('application', 'vnd.apple.mpegurl'));
    return;
  }

  if (path == '/high/index.m3u8' || path == '/low/index.m3u8') {
    _write(request, '''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4,
seg0.m4s
#EXTINF:4,
seg1.m4s
#EXT-X-ENDLIST
''', contentType: ContentType('application', 'vnd.apple.mpegurl'));
    return;
  }

  if (path == '/high/init.mp4') return _bytes(request, [1, 2, 3]);
  if (path == '/high/seg0.m4s') return _bytes(request, [4, 5]);
  if (path == '/high/seg1.m4s') return _bytes(request, [6, 7]);
  if (path.startsWith('/low/')) return _bytes(request, [9, 9]);

  if (path == '/audio-source.webm') {
    request.response
      ..headers.contentType = ContentType('audio', 'webm')
      ..headers.contentLength = 4
      ..add([10, 20, 30, 40]);
    request.response.close();
    return;
  }

  if (path == '/cloudstream/repo.json') {
    _writeJson(request, {
      'name': 'CloudStream Test Repo',
      'description': 'A test repository',
      'author': 'Tester',
      'manifestVersion': 1,
      'pluginLists': ['$baseUrl/cloudstream/plugins.json'],
    });
    return;
  }

  if (path == '/cloudstream/plugins.json') {
    _writeJson(request, [
      {
        'internalName': 'alpha',
        'name': 'Alpha Source',
        'description': 'First test plugin',
        'version': 3,
        'tvTypes': ['Movie', 'TvSeries'],
        'language': 'en',
      },
      {
        'internalName': 'beta',
        'name': 'Beta Source',
        'description': 'Second test plugin',
        'version': 1,
        'tvTypes': ['AnimeMovie'],
        'language': 'ja',
      },
    ]);
    return;
  }

  request.response.statusCode = HttpStatus.notFound;
  await request.response.close();
}

void _write(HttpRequest request, String body, {ContentType? contentType}) {
  request.response
    ..headers.contentType = contentType ?? ContentType.text
    ..write(body);
  request.response.close();
}

void _writeJson(HttpRequest request, Object body) {
  request.response
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  request.response.close();
}

void _bytes(HttpRequest request, List<int> bytes) {
  request.response
    ..headers.contentType = ContentType.binary
    ..headers.contentLength = bytes.length
    ..add(bytes);
  request.response.close();
}
