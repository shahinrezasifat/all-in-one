// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/services/download_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a persisted download location wins over the internal default', () async {
    final chosen =
        '${Directory.systemTemp.path}/all-in-one-location-${DateTime.now().microsecondsSinceEpoch}/All in One';
    SharedPreferences.setMockInitialValues({'custom_download_path': chosen});

    // The folder does not exist yet: it must be created, not discarded in
    // favour of /storage/emulated/0/Download/SnapTube.
    await DownloadManager.instance.ready;

    expect(DownloadManager.instance.downloadDirectory, chosen);
    expect(Directory(chosen).existsSync(), isTrue);
    expect(Directory('$chosen/Movies').existsSync(), isTrue);
    expect(await DownloadManager.instance.hasSavedLocation(), isTrue);

    // A permission grant / resume must never move downloads back to internal.
    await DownloadManager.instance.upgradeToPublicStorage();
    expect(DownloadManager.instance.downloadDirectory, chosen);
  });

  test('setDownloadDirectory creates the chosen tree and persists it', () async {
    final chosen =
        '${Directory.systemTemp.path}/all-in-one-picked-${DateTime.now().microsecondsSinceEpoch}';
    await DownloadManager.instance.setDownloadDirectory(chosen);

    expect(DownloadManager.instance.downloadDirectory, chosen);
    expect(Directory('$chosen/Videos').existsSync(), isTrue);
    expect(Directory('$chosen/Music').existsSync(), isTrue);
    expect(Directory('$chosen/Movies').existsSync(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('custom_download_path'), chosen);
  });
}
