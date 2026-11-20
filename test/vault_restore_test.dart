import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/services/download_manager.dart';
import 'package:snaptube_pure/services/vault_service.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'vault preserves the source folder and restores its download record',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'tub_vault_test_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths('${workspace.path}/private');
      addTearDown(() => PathProviderPlatform.instance = previousPaths);
      SharedPreferences.setMockInitialValues({});

      final downloads = DownloadManager.instance;
      await downloads.setDownloadDirectory('${workspace.path}/Downloads');
      final original = File(
        '${downloads.downloadDirectory}/YouTube/Creator/video.mp4',
      );
      await original.parent.create(recursive: true);
      await original.writeAsBytes([0, 1, 2, 3]);
      final task = DownloadTask(
        id: 'fixture',
        title: 'Video',
        author: 'Creator',
        thumbnailUrl: '',
        ext: 'mp4',
        formatLabel: '720p',
        isAudio: false,
        originalUrl: '',
        status: DownloadStatus.completed,
        totalBytes: 4,
        downloadedBytes: 4,
        savePath: original.path,
      );
      downloads.addCompletedTaskForTesting(task);
      final vault = VaultService.instance;
      expect(await vault.setPin('1234'), isTrue);
      await vault.moveToVault(task);
      final item = vault.items.single;
      expect(item.sourceFolder, 'YouTube/Creator');
      expect(await original.exists(), isFalse);
      expect(await File(item.vaultPath).readAsBytes(), [0, 1, 2, 3]);
      expect(downloads.tasks.any((task) => task.id == 'fixture'), isFalse);

      await original.writeAsBytes([9]);
      await expectLater(vault.restoreFromVault(item), throwsStateError);
      expect(await original.readAsBytes(), [9]);
      expect(vault.items.single, item);
      await original.delete();
      await original.parent.delete();

      await vault.restoreFromVault(item);
      expect(await original.readAsBytes(), [0, 1, 2, 3]);
      expect(vault.items, isEmpty);
      expect(
        downloads.tasks.singleWhere((task) => task.id == 'fixture').savePath,
        original.path,
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('snaptube_pure/vault_auth');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      var verified = true;
      messenger.setMockMethodCallHandler(channel, (_) async => verified);
      expect(await vault.setBiometricsEnabled(true), isTrue);
      vault.lock();
      verified = false;
      expect(await vault.unlockWithBiometrics(), isFalse);
      expect(vault.isUnlocked, isFalse);
      verified = true;
      expect(await vault.unlockWithBiometrics(), isTrue);
    },
  );
}
