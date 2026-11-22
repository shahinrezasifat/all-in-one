import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/screens/vault_screen.dart';
import 'package:snaptube_pure/services/player_service.dart';
import 'package:snaptube_pure/services/vault_service.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  testWidgets('Vault opens its local file in the in-app player', (
    tester,
  ) async {
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
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previous);

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
    expect(platform.dataSource?.sourceType, DataSourceType.file);
    expect(
      Uri.parse(platform.dataSource!.uri!).path,
      endsWith('/vault/private.mp4'),
    );
    expect(platform.playCalls, 1);
    // The fake video platform records play() but does not emit state events,
    // so the control may still expose its "Play" tooltip here.
    expect(
      find.byIcon(Icons.pause_rounded).evaluate().isNotEmpty ||
          find.byIcon(Icons.play_arrow_rounded).evaluate().isNotEmpty,
      isTrue,
    );
    // The related-video panel is populated asynchronously from the network and
    // is intentionally not asserted in this offline unit test.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // Release the singleton player engine (and its position-polling timer)
    // before the test zone checks for pending timers.
    PlayerService.instance.close();
  });
}

class _VideoPlatform extends VideoPlayerPlatform {
  int playCalls = 0;
  DataSource? dataSource;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    dataSource = options.dataSource;
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      size: const Size(1280, 720),
      duration: const Duration(minutes: 2),
    ),
  );

  @override
  Future<void> play(int playerId) async {
    playCalls++;
  }

  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool prevent,
  ) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> dispose(int playerId) async {}
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}
