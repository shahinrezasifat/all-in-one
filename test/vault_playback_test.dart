import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/screens/vault_screen.dart';
import 'package:snaptube_pure/services/player_service.dart';
import 'package:snaptube_pure/services/vault_service.dart';

void main() {
  testWidgets('Vault opens its local file in the in-app player', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({
      'vault_pin_hash': sha256
          .convert(utf8.encode('snaptube_pure_vault_1234'))
          .toString(),
      'vault_items_list': jsonEncode([
        {
          'id': 'video',
          'originalPath': '/Downloads/YouTube/Creator/video.mp4',
          'vaultPath': '/vault/private.mp4',
          'title': 'Vault video',
          'ext': 'mp4',
          'sourceFolder': 'YouTube/Creator',
        },
        {
          'id': 'other',
          'title': 'Another vault video',
          'sourceFolder': 'youtube/Another channel',
          'ext': 'mp4',
          'vaultPath': '/vault/other.mp4',
        },
      ]),
    });
    final loadedPaths = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const mpvChannel = MethodChannel('snaptube_pure/mpv');
    messenger.setMockMethodCallHandler(mpvChannel, (call) async {
      if (call.method == 'load') {
        loadedPaths.add((call.arguments as Map?)?['path']?.toString() ?? '');
      }
      if (call.method == 'getState') {
        return {
          'position': 0.0,
          'duration': 0.0,
          'playing': true,
          'tracks': '[]',
        };
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(mpvChannel, null));
    const mpvEvents = MethodChannel('snaptube_pure/mpv_events');
    messenger.setMockMethodCallHandler(mpvEvents, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(mpvEvents, null));
    const platformViews = MethodChannel('flutter/platform_views');
    messenger.setMockMethodCallHandler(platformViews, (call) async {
      if (call.method == 'create') return 0;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(platformViews, null));

    final vault = VaultService.instance;
    expect(await vault.unlock('1234'), isTrue);
    await tester.pumpWidget(const MaterialApp(home: VaultScreen()));
    await tester.pumpAndSettle();
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('Vault video'), findsNothing);
    await tester.tap(find.text('YouTube'));
    await tester.pumpAndSettle();
    expect(find.text('Another channel'), findsOneWidget);
    await tester.tap(find.text('Creator'));
    await tester.pumpAndSettle();
    expect(find.text('Another vault video'), findsNothing);
    await tester.tap(find.text('Vault video'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    // In a widget test the native platform view never actually initialises;
    // mark the bridge ready so the queued libmpv load is flushed.
    PlayerService.instance.mpv.markReady();
    await tester.pump();
    expect(
      loadedPaths.any((path) => path.endsWith('/vault/private.mp4')),
      isTrue,
    );
    // The related-video panel is populated asynchronously from the network and
    // is intentionally not asserted in this offline unit test.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // Release the singleton player engine (and its position-polling timer)
    // before the test zone checks for pending timers.
    PlayerService.instance.close();
    PlayerService.instance.mpv.dispose();
  });
}
