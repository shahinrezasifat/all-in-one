import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'download_manager.dart';

class PermissionService {
  PermissionService._();
  static final PermissionService instance = PermissionService._();

  static const String _keyStartupPrompted = 'permissions_startup_prompted_v1';

  /// Returns true if either standard storage, media, or all files access is granted.
  Future<bool> hasStoragePermission() async {
    if (!Platform.isAndroid) return true;

    try {
      final manageStatus = await Permission.manageExternalStorage.status;
      if (manageStatus.isGranted) return true;

      final storageStatus = await Permission.storage.status;
      if (storageStatus.isGranted) return true;

      final videoStatus = await Permission.videos.status;
      final audioStatus = await Permission.audio.status;
      if (videoStatus.isGranted && audioStatus.isGranted) return true;

      return false;
    } catch (e) {
      debugPrint('Error checking storage permission: $e');
      return false;
    }
  }

  /// Returns true if notification permission is granted.
  Future<bool> hasNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.notification.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Returns true if Manage External Storage (All files access) is granted.
  Future<bool> hasManageStoragePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.manageExternalStorage.status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Returns true if battery optimization ignore is granted (background running allowed).
  Future<bool> hasBatteryOptimizationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Request ignore battery optimizations so Android does not kill background downloads.
  Future<bool> requestBatteryOptimizationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await Permission.ignoreBatteryOptimizations.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('Error requesting battery optimization permission: $e');
      return false;
    }
  }

  /// Request all essential permissions (Storage, Battery, Notifications) at once.
  Future<Map<String, bool>> requestAllStartupPermissions() async {
    if (!Platform.isAndroid) {
      return {'storage': true, 'battery': true, 'notification': true};
    }

    try {
      // 1. Request standard runtime storage permissions
      final statuses = await [
        Permission.storage,
        Permission.videos,
        Permission.audio,
        Permission.photos,
      ].request();

      bool storageGranted = (statuses[Permission.storage]?.isGranted == true) ||
          ((statuses[Permission.videos]?.isGranted == true) &&
              (statuses[Permission.audio]?.isGranted == true)) ||
          (statuses[Permission.videos]?.isGranted == true) ||
          (statuses[Permission.audio]?.isGranted == true);

      if (!storageGranted) {
        final manageStatus = await Permission.manageExternalStorage.status;
        if (manageStatus.isGranted) {
          storageGranted = true;
        }
      }

      if (storageGranted) {
        await DownloadManager.instance.upgradeToPublicStorage();
      }

      // 2. Request battery optimization (so Android does not stop background downloads)
      bool batteryGranted = false;
      try {
        final bStatus = await Permission.ignoreBatteryOptimizations.request();
        batteryGranted = bStatus.isGranted;
      } catch (e) {
        debugPrint('Battery optimization request notice: $e');
      }

      // 3. Request notification permission
      bool notifGranted = false;
      try {
        final nStatus = await Permission.notification.request();
        notifGranted = nStatus.isGranted;
      } catch (e) {
        debugPrint('Notification request notice: $e');
      }

      final finalStorageOk = await hasStoragePermission();
      if (finalStorageOk) {
        await DownloadManager.instance.upgradeToPublicStorage();
      }

      return {
        'storage': finalStorageOk,
        'battery': batteryGranted || await hasBatteryOptimizationPermission(),
        'notification': notifGranted || await hasNotificationPermission(),
      };
    } catch (e) {
      debugPrint('Error in requestAllStartupPermissions: $e');
      return {
        'storage': await hasStoragePermission(),
        'battery': await hasBatteryOptimizationPermission(),
        'notification': await hasNotificationPermission(),
      };
    }
  }

  /// Request all essential permissions (Storage, Media, and Notifications) at once.
  Future<Map<String, bool>> requestAllPermissions() async {
    if (!Platform.isAndroid) {
      return {'storage': true, 'notification': true, 'manage_storage': true};
    }

    try {
      // 1. Request standard runtime permissions
      final statuses = await [
        Permission.storage,
        Permission.notification,
        Permission.videos,
        Permission.audio,
        Permission.photos,
      ].request();

      final storageGranted = (statuses[Permission.storage]?.isGranted == true) ||
          ((statuses[Permission.videos]?.isGranted == true) &&
              (statuses[Permission.audio]?.isGranted == true));

      final notificationGranted = statuses[Permission.notification]?.isGranted == true;

      // 2. If storage granted or available, try upgrading to public download folder
      await DownloadManager.instance.upgradeToPublicStorage();

      return {
        'storage': storageGranted,
        'notification': notificationGranted,
      };
    } catch (e) {
      debugPrint('Error requesting permissions: $e');
      return {'storage': false, 'notification': false};
    }
  }

  /// Request storage specific permission (supports Android 13+ media vs older storage).
  Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    try {
      final statuses = await [
        Permission.storage,
        Permission.videos,
        Permission.audio,
        Permission.photos,
      ].request();

      final granted = (statuses[Permission.storage]?.isGranted == true) ||
          ((statuses[Permission.videos]?.isGranted == true) &&
              (statuses[Permission.audio]?.isGranted == true));

      if (granted) {
        await DownloadManager.instance.upgradeToPublicStorage();
      }
      return granted;
    } catch (e) {
      debugPrint('Error requesting storage permission: $e');
      return false;
    }
  }

  /// Request Manage External Storage (Android 11+ All Files Access)
  Future<bool> requestManageStoragePermission() async {
    if (!Platform.isAndroid) return true;

    try {
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) {
        await DownloadManager.instance.upgradeToPublicStorage();
      }
      return status.isGranted;
    } catch (e) {
      debugPrint('Error requesting manage storage permission: $e');
      return false;
    }
  }

  /// Request notification permission (Android 13+)
  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;

    try {
      final status = await Permission.notification.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('Error requesting notification permission: $e');
      return false;
    }
  }

  /// Open application settings if permission is permanently denied.
  Future<bool> openSettings() async {
    return await openAppSettings();
  }

  /// Checks if the startup permission prompt should be shown.
  Future<bool> shouldShowStartupPrompt() async {
    if (!Platform.isAndroid) return false;

    try {
      final hasStorage = await hasStoragePermission();
      if (hasStorage) return false; // Already granted

      final prefs = await SharedPreferences.getInstance();
      return !(prefs.getBool(_keyStartupPrompted) ?? false);
    } catch (_) {
      return false;
    }
  }

  /// Records that the user has seen the startup prompt.
  Future<void> markStartupPromptShown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyStartupPrompted, true);
    } catch (_) {}
  }
}
