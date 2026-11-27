import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

///kind of storage a download root lives on.
enum StorageKind { internal, external, custom }

/// One selectable storage volume (or a user-picked folder).
class StorageLocation {
  const StorageLocation({
    required this.id,
    required this.label,
    required this.kind,
    required this.downloadRoot,
  });

  final String id;
  final String label;
  final StorageKind kind;
  final String downloadRoot;

  /// Every download lands inside this folder, whatever the chosen root is.
  String get appFolder => StorageService.joinAppFolder(downloadRoot);

  String get subtitle => kind == StorageKind.custom
      ? 'Custom folder'
      : kind == StorageKind.internal
      ? 'Internal storage'
      : 'External storage';
}

/// Discovers phone storages, owns the "All in One" download folder rule and
/// migrates legacy "SnapTube" downloads so they stay visible after switching.
class StorageService extends ChangeNotifier {
  StorageService._();
  static final StorageService instance = StorageService._();

  static const String appFolderName = 'All in One';
  static const String legacyFolderName = 'SnapTube';
  static const String subVideos = 'Videos';
  static const String subMusic = 'Music';
  static const String subMovies = 'Movies';

  static const MethodChannel _channel = MethodChannel('snaptube_pure/storage');
  static const String _keySelectedId = 'selected_storage_id_v1';
  static const String _keyCustomRoot = 'custom_download_root_v1';
  static const String _keyCustomUri = 'custom_download_uri_v1';
  static const String _keyLegacyMigrated = 'legacy_downloads_migrated_v2';

  List<StorageLocation> _locations = [];
  String? _selectedId;
  bool _loaded = false;
  bool _migrating = false;

  bool get isLoaded => _loaded;
  bool get isMigrating => _migrating;
  List<StorageLocation> get locations => List.unmodifiable(_locations);

  String? _customRootCache;
  String? _customUriCache;

  /// The SAF tree URI granted by Android, when the folder came from the
  /// system picker. Kept so a reboot cannot lose the grant; raw paths alone
  /// are not writable on many SD-card providers.
  String? get customUri => _customUriCache;

  /// Whether the user explicitly picked a storage device or folder. Used at
  /// startup so the legacy public-storage migration cannot override it.
  bool get hasUserSelection =>
      (_selectedId != null && _selectedId!.isNotEmpty) ||
      (_customRootCache != null && _customRootCache!.isNotEmpty);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _selectedId = prefs.getString(_keySelectedId);
      _customRootCache = prefs.getString(_keyCustomRoot);
      _customUriCache = prefs.getString(_keyCustomUri);
      _locations = await _discover();
    } catch (error) {
      debugPrint('Storage discovery failed: $error');
    } finally {
      // Always mark as loaded so failing discovery cannot cause a rebuild loop.
      if (_locations.isEmpty) {
        _locations = [
          StorageLocation(
            id: 'internal',
            label: 'Internal storage',
            kind: StorageKind.internal,
            downloadRoot: Directory.systemTemp.path,
          ),
        ];
      }
      _loaded = true;
      notifyListeners();
    }
  }

  /// Adds the app folder to any user-chosen root, unless it is already there.
  static String joinAppFolder(String root) {
    final trimmed = root.replaceAll(RegExp(r'[\\/]+$'), '');
    final last = trimmed.split(RegExp(r'[\\/]')).lastOrNull ?? '';
    return last == appFolderName ? trimmed : '$trimmed/$appFolderName';
  }

  Future<List<StorageLocation>> _discover() async {
    final locations = <StorageLocation>[];
    if (Platform.isAndroid) {
      List<Map<String, dynamic>> nativeVolumes = [];
      try {
        final result = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
          'listVolumes',
        );
        nativeVolumes = [
          for (final volume in result ?? <Map<dynamic, dynamic>>[])
            Map<String, dynamic>.from(volume),
        ];
      } on MissingPluginException {
        // Older host / test environment: fall back to path_provider only.
      } catch (error) {
        debugPrint('Storage volume discovery failed: $error');
      }

      try {
        final dirs =
            await getExternalStorageDirectories(
              type: StorageDirectory.downloads,
            ) ??
            <Directory>[];
        final seen = <String>{};
        for (final dir in dirs) {
          final path = dir.path.replaceAll(RegExp(r'[\\/]+$'), '');
          if (!seen.add(path)) continue;
          final isInternal =
              path.contains('/emulated/0') ||
              path.contains('/storage/emulated');
          final native = nativeVolumes.firstWhere(
            (volume) => path.startsWith(
              (volume['downloadPath'] as String? ?? '').replaceAll(
                RegExp(r'[\\/]+$'),
                '',
              ),
            ),
            orElse: () => <String, dynamic>{},
          );
          final label = (native['label'] as String?)?.trim().isNotEmpty == true
              ? native['label'] as String
              : (isInternal ? 'Internal storage' : 'External storage');
          locations.add(
            StorageLocation(
              id: (native['id'] as String?) ?? path,
              label: label,
              kind: isInternal ? StorageKind.internal : StorageKind.external,
              downloadRoot: path,
            ),
          );
        }
      } catch (error) {
        debugPrint('Download directory discovery failed: $error');
      }
      // path_provider does not report every removable volume. Add native
      // volumes that were not seen above so an SD card is actually selectable
      // instead of silently falling back to internal storage.
      for (final volume in nativeVolumes) {
        final id = volume['id'] as String?;
        final path = volume['downloadPath'] as String?;
        if (id == null || id.isEmpty || path == null || path.isEmpty) continue;
        if (locations.any(
          (location) => location.id == id || location.downloadRoot == path,
        )) {
          continue;
        }
        final internal = id == 'internal';
        locations.add(
          StorageLocation(
            id: id,
            label: (volume['label'] as String?)?.trim().isNotEmpty == true
                ? volume['label'] as String
                : (internal ? 'Internal storage' : 'SD card'),
            kind: internal ? StorageKind.internal : StorageKind.external,
            downloadRoot: path,
          ),
        );
      }
    } else {
      String root = Directory.systemTemp.path;
      try {
        root = (await getDownloadsDirectory())?.path ?? root;
      } on UnsupportedError {
        // Desktop/test platforms without a downloads directory API.
      } catch (_) {}
      locations.add(
        StorageLocation(
          id: 'internal',
          label: 'Downloads',
          kind: StorageKind.internal,
          downloadRoot: root,
        ),
      );
    }

    if (locations.isEmpty) {
      locations.add(
        StorageLocation(
          id: 'internal',
          label: 'Internal storage',
          kind: StorageKind.internal,
          downloadRoot: Platform.isAndroid
              ? '/storage/emulated/0/Download'
              : Directory.systemTemp.path,
        ),
      );
    }

    final custom = _customRootCache;
    if (custom != null && custom.isNotEmpty) {
      locations.add(
        StorageLocation(
          id: 'custom',
          label: 'Picked folder',
          kind: StorageKind.custom,
          downloadRoot: custom,
        ),
      );
    }
    return locations;
  }

  StorageLocation get current {
    if (!_loaded) return _locations.first;
    return _locations.firstWhere(
      (location) => location.id == _selectedId,
      orElse: () => _locations.firstWhere(
        (location) => location.kind == StorageKind.internal,
        orElse: () => _locations.first,
      ),
    );
  }

  /// Creates the canonical folder tree: <root>/All in One/{Videos,Music,Movies}.
  static Future<Directory> ensureAppFolder(String root) async {
    final app = Directory(joinAppFolder(root));
    if (!app.existsSync()) await app.create(recursive: true);
    for (final name in [subVideos, subMusic, subMovies]) {
      final sub = Directory('${app.path}/$name');
      if (!sub.existsSync()) await sub.create(recursive: true);
    }
    return app;
  }

  Future<StorageLocation> select(StorageLocation location) async {
    await ensureLoaded();
    await ensureAppFolder(location.downloadRoot);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySelectedId, location.id);
    _selectedId = location.id;
    notifyListeners();
    return location;
  }

  /// Opens the Android folder picker. Returns the chosen app folder path.
  Future<String?> pickFolder() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pickFolder',
      );
      if (result == null) return null;
      final path = result['path'] as String?;
      if (path == null || path.isEmpty) return null;
      final uri = result['uri'] as String?;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyCustomRoot, path);
      if (uri != null && uri.isNotEmpty) {
        await prefs.setString(_keyCustomUri, uri);
      } else {
        await prefs.remove(_keyCustomUri);
      }
      _customRootCache = path;
      _customUriCache = uri;
      _locations = await _discover();
      await select(
        _locations.firstWhere(
          (location) => location.kind == StorageKind.custom,
        ),
      );
      return joinAppFolder(path);
    } on MissingPluginException {
      return null;
    } catch (error) {
      debugPrint('Folder picker failed: $error');
      return null;
    }
  }

  Future<void> openFolder(String path) async {
    try {
      await _channel.invokeMethod<void>('openFolder', {'path': path});
    } on MissingPluginException {
      // Desktop / test: ignore, the caller already shows the path as text.
    } catch (error) {
      debugPrint('Open folder failed: $error');
    }
  }

  /// Moves a legacy SnapTube folder into "All in One" and rewrites task paths.
  /// Returns the number of files that were relocated.
  Future<int> migrateLegacyFolder({
    required String newRoot,
    required Future<void> Function(String oldRoot, String newRoot)
    relocateTasks,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_keyLegacyMigrated) == true) return 0;
    _migrating = true;
    notifyListeners();
    var moved = 0;
    try {
      final candidates = <String>{
        for (final location in _locations) location.downloadRoot,
        newRoot,
      };
      final target = Directory(joinAppFolder(newRoot));
      await ensureAppFolder(newRoot);
      for (final root in candidates) {
        final legacy = Directory('$root/$legacyFolderName');
        if (!legacy.existsSync()) continue;
        await for (final entity in legacy.list(recursive: true)) {
          if (entity is! File) continue;
          final relative = entity.path.substring(legacy.path.length + 1);
          final destination = File('${target.path}/$relative');
          await destination.parent.create(recursive: true);
          if (!destination.existsSync()) {
            await entity.copy(destination.path);
            moved++;
          }
        }
        await relocateTasks(root, newRoot);
        // Keep the old folder as a safety net; it stays out of the new root.
      }
      await prefs.setBool(_keyLegacyMigrated, true);
      return moved;
    } catch (error) {
      debugPrint('Legacy download migration failed: $error');
      return moved;
    } finally {
      _migrating = false;
      notifyListeners();
    }
  }
}
