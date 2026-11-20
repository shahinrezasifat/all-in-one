import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snaptube_pure/services/app_update_service.dart';
import 'package:snaptube_pure/widgets/startup_update_gate.dart';

const _releases = 'https://github.com/shahinrezasifat1999/all-in-one/releases';
const _release = '$_releases/tag/v1.10.0';
const _apk = '$_releases/download/v1.10.0/all-in-one.apk';

MockClient _githubRelease({
  String tag = 'v1.10.0',
  String apkUrl = _apk,
  int status = 200,
}) {
  return MockClient((request) async {
    expect(
      request.url.toString(),
      'https://api.github.com/repos/shahinrezasifat1999/all-in-one/releases/latest',
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
              for (final name in ['split-arm64.apk', universal])
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
      final update = await fetchAppUpdate(client, '1.9.0');
      expect(update?.apkUrl?.pathSegments.last, universal);
    },
  );

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

  testWidgets('A mandatory update blocks dismissal and prefers the APK URL', (
    tester,
  ) async {
    final launches = <String>[];
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(launcher, (call) async {
      final url = call.arguments['url'] as String;
      launches.add(url);
      return url != _apk;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(launcher, null));

    await tester.pumpWidget(
      MaterialApp(
        home: StartupUpdateGate(
          checkForUpdate: () async => AppUpdate(
            version: '1.10.0',
            notes: 'Release notes',
            releaseUrl: Uri.parse(_release),
            apkUrl: Uri.parse(_apk),
          ),
          child: const Text('Home screen'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Update required · v1.10.0'), findsOneWidget);
    expect(find.text('Release notes'), findsOneWidget);
    expect(find.text('Exit App'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Home screen'), findsNothing);

    await tester.tap(find.text('Update Now'));
    await tester.pumpAndSettle();
    expect(launches, [_apk, _release]);
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
