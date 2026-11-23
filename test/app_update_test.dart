import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/services/app_update_service.dart';
import 'package:snaptube_pure/widgets/startup_update_gate.dart';

const _releases = 'https://github.com/shahinrezasifat/all-in-one/releases';
const _release = '$_releases/tag/v1.10.0';
const _apk = '$_releases/download/v1.10.0/all-in-one.apk';

void _testApkTransfer() {
  test('Only a complete and verified APK is handed to the installer', () async {
    final cache = await Directory.systemTemp.createTemp('app-update-test-');
    addTearDown(() => cache.delete(recursive: true));
    final progress = <int>[];
    final update = AppUpdate(
      version: '1.10.0',
      notes: '',
      releaseUrl: Uri.parse(_release),
      apkUrl: Uri.parse(_apk),
      apkSize: 3,
      apkDigest: 'sha256:${sha256.convert([1, 2, 3])}',
    );
    final client = MockClient((request) async {
      if (request.url.host == 'github.com') {
        return http.Response(
          '',
          302,
          headers: {
            'location': 'https://release-assets.githubusercontent.com/test',
          },
        );
      }
      return http.Response.bytes([1, 2, 3], 200);
    });
    addTearDown(client.close);
    final apk = File('${cache.path}/app-updates/update.apk');
    final partial = File('${apk.path}.part');
    final invalid = MockClient((_) async => http.Response.bytes([1, 2], 200));
    addTearDown(invalid.close);
    await expectLater(
      downloadAppUpdate(update, (_, _) {}, client: invalid, cache: cache),
      throwsFormatException,
    );
    expect(await partial.exists(), isFalse);
    expect(await apk.exists(), isFalse);
    await downloadAppUpdate(
      update,
      (received, _) => progress.add(received),
      client: client,
      cache: cache,
    );
    expect(await apk.readAsBytes(), [1, 2, 3]);
    expect(progress, [0, 3]);
  });
}

MockClient _githubRelease({
  String tag = 'v1.10.0',
  String apkUrl = _apk,
  int status = 200,
}) {
  return MockClient((request) async {
    expect(
      request.url.toString(),
      'https://api.github.com/repos/shahinrezasifat/all-in-one/releases/latest',
    );
    return http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'tag_name': tag,
          'body': 'New release — update now.',
          'html_url': _release,
          'assets': [
            {
              'name': 'all-in-one.apk',
              'state': 'uploaded',
              'browser_download_url': apkUrl,
            },
          ],
        }),
      ),
      status,
    );
  });
}

void main() {
  _testApkTransfer();
  test(
    'A newer release includes the uploaded APK and UTF-8 release notes',
    () async {
      final update = await fetchAppUpdate(_githubRelease(), '1.9.0+2101');
      expect(update?.version, '1.10.0');
      expect(update?.notes, 'New release — update now.');
      expect(update?.apkUrl, Uri.parse(_apk));
      expect(update?.releaseUrl, Uri.parse(_release));
    },
  );

  test(
    'Equal, older, or invalid tags and unavailable GitHub allow startup',
    () async {
      for (final tag in ['v1.10.0', 'v1.9.0', 'release']) {
        expect(
          await fetchAppUpdate(_githubRelease(tag: tag), '1.10.0'),
          isNull,
        );
      }
      expect(
        await fetchAppUpdate(_githubRelease(status: 404), '1.9.0'),
        isNull,
      );
      final offline = MockClient(
        (_) async => throw http.ClientException('Offline'),
      );
      expect(await fetchAppUpdate(offline, '1.9.0'), isNull);
    },
  );

  test(
    'The release page is available when there is no trusted APK link',
    () async {
      final client = _githubRelease(
        apkUrl: 'https://example.com/all-in-one.apk',
      );
      final update = await fetchAppUpdate(client, '1.9.0');
      expect(update?.apkUrl, isNull);
      expect(update?.releaseUrl, Uri.parse(_release));
    },
  );

  test(
    'The updater prefers the universal APK over an earlier ABI asset',
    () async {
      const universal = 'all-in-one-v1.10.0.apk';
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode({
            'tag_name': 'v1.10.0',
            'html_url': _release,
            'assets': [
              for (final name in [
                'split-all-in-one-v1.10.0-arm64-v8a.apk',
                universal,
              ])
                {
                  'name': name,
                  'state': 'uploaded',
                  'browser_download_url': '$_releases/download/v1.10.0/$name',
                },
            ],
          }),
          200,
        );
      });
      final update = await fetchAppUpdate(
        client,
        '1.9.0',
        supportedAbis: ['arm64-v8a'],
      );
      expect(update?.apkUrl?.pathSegments.last, universal);
    },
  );

  test('Fallback selects a compatible ABI or the split bundle', () async {
    const arm = 'split-all-in-one-v1.10.0-arm64-v8a.apk';
    const bundle = 'all-in-one-v1.10.0.apks';
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'tag_name': 'v1.10.0',
          'assets': [
            for (final name in [arm, bundle])
              {
                'name': name,
                'state': 'uploaded',
                'browser_download_url': '$_releases/download/v1.10.0/$name',
              },
          ],
        }),
        200,
      ),
    );
    addTearDown(client.close);
    for (final (abi, expected) in [('arm64-v8a', arm), ('x86_64', bundle)]) {
      final update = await fetchAppUpdate(
        client,
        '1.9.0',
        supportedAbis: [abi],
      );
      expect(update?.apkUrl?.pathSegments.last, expected);
    }
  });

  testWidgets('The startup check holds the home screen until it completes', (
    tester,
  ) async {
    final check = Completer<AppUpdate?>();
    await tester.pumpWidget(
      MaterialApp(
        home: StartupUpdateGate(
          checkForUpdate: () => check.future,
          child: const Text('Home screen'),
        ),
      ),
    );
    expect(find.text('Home screen'), findsNothing);
    check.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Home screen'), findsOneWidget);
  });

  testWidgets(
    'A mandatory update blocks dismissal and downloads inside the app before installing',
    (tester) async {
      final finished = Completer<void>();
      final installs = <String>[];
      const installer = MethodChannel('snaptube_pure/app_update');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(installer, (call) async {
        installs.add(call.method);
        return installs.length > 1;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(installer, null));

      await tester.pumpWidget(
        MaterialApp(
          home: StartupUpdateGate(
            checkForUpdate: () async => AppUpdate(
              version: '1.10.0',
              notes: 'Release notes',
              releaseUrl: Uri.parse(_release),
              apkUrl: Uri.parse(_apk),
            ),
            downloadUpdate: (update, progress) {
              expect(update.apkUrl.toString(), _apk);
              progress(1024 * 1024, 2 * 1024 * 1024);
              return finished.future;
            },
            child: const Text('Home screen'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Version 1.10.0 is ready'), findsOneWidget);
      expect(find.text('Release notes'), findsOneWidget);
      expect(find.text('Exit App'), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Home screen'), findsNothing);

      await tester.tap(find.text('Download Update'));
      await tester.pump();
      expect(find.text('Downloading update · 50%'), findsOneWidget);
      expect(installs, isEmpty);
      finished.complete();
      await tester.pumpAndSettle();
      expect(find.text('Download complete'), findsOneWidget);
      await tester.tap(find.text('Update & Install'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Allow installs'), findsOneWidget);
      await tester.ensureVisible(find.text('Not now'));
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Update & Install'));
      await tester.tap(find.text('Update & Install'));
      await tester.pumpAndSettle();
      expect(installs, ['installUpdate', 'installUpdate']);
      expect(find.text('Restart'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  testWidgets('A foreground check gates even a screen pushed after startup', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var checks = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => StartupUpdateGate(
          checkForUpdate: () async {
            if (++checks == 1) return null;
            return AppUpdate(
              version: '1.10.0',
              notes: 'New release',
              releaseUrl: Uri.parse(_release),
            );
          },
          child: child!,
        ),
        home: const Scaffold(body: Text('Home screen')),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Playing video')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Playing video'), findsOneWidget);

    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text('Playing video'), findsNothing);
    expect(find.text('Version 1.10.0 is ready'), findsOneWidget);
  });

  testWidgets('A known mandatory release stays required while offline', (
    tester,
  ) async {
    const channel = MethodChannel('snaptube_pure/app_update');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'getInstalledVersion' ? '1.9.0' : false,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'required_github_app_release': jsonEncode({
        'version': '1.10.0',
        'notes': 'Mandatory release',
        'releaseUrl': _release,
        'apkUrl': _apk,
      }),
    });
    await tester.pumpWidget(
      const MaterialApp(home: StartupUpdateGate(child: Text('Home screen'))),
    );
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    expect(find.text('Home screen'), findsNothing);
    expect(find.text('Version 1.10.0 is ready'), findsOneWidget);
  });
}
