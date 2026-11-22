import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vault_item.dart';
import '../models/download_task.dart';
import 'gallery_media_service.dart';
import 'virtual_folder_service.dart';
import 'download_manager.dart';

class VaultFolder {
  final String id;
  final String name;
  final DateTime createdAt;

  const VaultFolder({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
  };

  factory VaultFolder.fromJson(Map<String, dynamic> json) => VaultFolder(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? 'Vault Folder',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}

class VaultService extends ChangeNotifier with WidgetsBindingObserver {
  static final VaultService instance = VaultService._();

  late final Future<void> _ready = _init();
  VaultService._() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A private vault must not stay open while the app is in the background.
    if ((state == AppLifecycleState.detached ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        _isUnlocked) {
      lock();
    }
  }

  bool _isUnlocked = false;
  bool _hasPin = false;
  bool _biometricsEnabled = false;
  bool _authenticating = false;
  final _restoring = <String>{};
  final _moving = <String>{};
  static const _biometricChannel = MethodChannel('snaptube_pure/vault_auth');
  bool get biometricsEnabled => _biometricsEnabled;
  bool get supportsBiometrics =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final List<VaultItem> _vaultItems = [];
  final List<VaultFolder> _vaultFolders = [];

  bool get isUnlocked => _isUnlocked;
  bool get hasPin => _hasPin;
  List<VaultItem> get items => List.unmodifiable(_vaultItems);
  List<VaultFolder> get vaultFolders => List.unmodifiable(_vaultFolders);

  /// Completes once the stored PIN hash and vault index have been loaded.
  Future<void> get ready => _ready;

  String get vaultDirectoryPath =>
      '${DownloadManager.instance.downloadDirectory}/.secret_vault';

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _biometricsEnabled = prefs.getBool('vault_biometrics') ?? false;
    final pinHash = prefs.getString('vault_pin_hash');
    _hasPin = pinHash != null && pinHash.isNotEmpty;

    final foldersJson = prefs.getString('vault_folders_list');
    if (foldersJson != null) {
      try {
        final List<dynamic> list = json.decode(foldersJson);
        _vaultFolders.clear();
        for (final f in list) {
          _vaultFolders.add(VaultFolder.fromJson(f));
        }
      } catch (_) {}
    }

    final itemsJson = prefs.getString('vault_items_list');
    if (itemsJson != null) {
      try {
        final List<dynamic> list = json.decode(itemsJson);
        _vaultItems.clear();
        for (final item in list) {
          _vaultItems.add(VaultItem.fromJson(item));
        }
      } catch (_) {}
    }

    // Older builds stored moved downloads under the application-support dir
    // while photos/folders used the download dir. Fold them into one root so
    // restore, playback and deletion all look in the same place.
    // Skip the platform call entirely when there is nothing to migrate (also
    // keeps unit tests, which have no path_provider plugin, from blocking).
    if (_vaultItems.any((item) => item.vaultPath.contains('/secret_vault/'))) {
      try {
        final support = await getApplicationSupportDirectory().timeout(
          const Duration(seconds: 3),
        );
        final legacyRoot = '${support.path}/secret_vault';
        var migrated = false;
        for (var i = 0; i < _vaultItems.length; i++) {
          final item = _vaultItems[i];
          if (!item.vaultPath.startsWith('$legacyRoot/')) continue;
          final oldFile = File(item.vaultPath);
          if (!await oldFile.exists()) continue;
          final fileName = item.vaultPath.split('/').last;
          final target = File('$vaultDirectoryPath/${item.id}/$fileName');
          await target.parent.create(recursive: true);
          if (!await target.exists()) {
            await oldFile.copy(target.path);
            await oldFile.delete();
          }
          _vaultItems[i] = item.copyWith(vaultPath: target.path);
          migrated = true;
        }
        if (migrated) await _persistItems();
      } catch (_) {}
    }
    notifyListeners();
  }

  static const int _pinStretchRounds = 25000;
  static const String _pinSaltKey = 'vault_pin_salt';

  String _newPinSalt() {
    final random = Random.secure();
    return base64.encode(List<int>.generate(16, (_) => random.nextInt(256)));
  }

  /// Salted, stretched hash. A plain SHA-256 of a 4-digit PIN with a global
  /// salt is trivially brute-forced once SharedPreferences is readable.
  String _hashPin(String pin, String salt) {
    List<int> bytes = utf8.encode('$salt:${pin.trim()}');
    for (var i = 0; i < _pinStretchRounds; i++) {
      bytes = sha256.convert(bytes).bytes;
    }
    return 'v1\$$salt\$${base64.encode(bytes)}';
  }

  String _legacyPinHash(String pin) =>
      sha256.convert(utf8.encode('snaptube_pure_vault_$pin')).toString();

  Future<bool> setPin(String newPin) async {
    if (newPin.trim().length < 4) return false;
    await _ready;
    final prefs = await SharedPreferences.getInstance();
    final salt = _newPinSalt();
    await prefs.setString('vault_pin_hash', _hashPin(newPin, salt));
    await prefs.setString(_pinSaltKey, salt);
    _hasPin = true;
    _isUnlocked = true;

    notifyListeners();
    return true;
  }

  /// Verifies an existing PIN. NEVER creates one implicitly — first-time
  /// setup must go through the explicit, UI-driven [setPin] confirmation
  /// flow, so a stray 4-digit tap can never silently become the vault password.
  Future<bool> unlock(String enteredPin) async {
    await _ready;
    final prefs = await SharedPreferences.getInstance();
    final savedHash = prefs.getString('vault_pin_hash');
    if (savedHash == null || savedHash.isEmpty) {
      return false;
    }
    final salt = prefs.getString(_pinSaltKey);
    var valid = false;
    String? migratedHash;
    String? migratedSalt;
    if (savedHash.startsWith('v1\$') && salt != null) {
      valid = _hashPin(enteredPin, salt) == savedHash;
    } else {
      // Existing installations keep working and are silently upgraded on the
      // first successful unlock.
      valid = _legacyPinHash(enteredPin.trim()) == savedHash;
      if (valid) {
        migratedSalt = _newPinSalt();
        migratedHash = _hashPin(enteredPin, migratedSalt);
      }
    }
    if (!valid) return false;
    if (migratedHash != null && migratedSalt != null) {
      await prefs.setString('vault_pin_hash', migratedHash);
      await prefs.setString(_pinSaltKey, migratedSalt);
    }
    _isUnlocked = true;
    notifyListeners();
    return true;
  }

  Future<bool> setBiometricsEnabled(bool enabled) async {
    await ready;
    if (!_isUnlocked || !_hasPin) return false;
    if (enabled && !await _authenticateBiometric()) return false;
    if (!_isUnlocked) return false;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool('vault_biometrics', enabled)) return false;
    _biometricsEnabled = enabled;
    notifyListeners();
    return true;
  }

  Future<bool> unlockWithBiometrics() async {
    await ready;
    if (!_hasPin || !_biometricsEnabled || !await _authenticateBiometric()) {
      return false;
    }
    _isUnlocked = true;
    notifyListeners();
    return true;
  }

  Future<bool> _authenticateBiometric() async {
    if (!supportsBiometrics || _authenticating) return false;
    _authenticating = true;
    try {
      return await _biometricChannel.invokeMethod<bool>('authenticate') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } finally {
      _authenticating = false;
    }
  }

  void lock() {
    _isUnlocked = false;
    notifyListeners();
  }

  // Vault Folders Management
  /// Folder names become directory names on disk — never allow separators or
  /// `..` to escape the vault root.
  String _safeFolderName(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'Vault Folder';
    }
    return cleaned;
  }

  Future<VaultFolder> createVaultFolder(String name) async {
    await _ready;
    final folderName = _safeFolderName(name);
    final newFolder = VaultFolder(
      id: 'vf_${DateTime.now().millisecondsSinceEpoch}',
      name: folderName,
      createdAt: DateTime.now(),
    );
    _vaultFolders.add(newFolder);
    await _persistFolders();

    // Create sub-directory in real secret vault on disk
    final subDir = Directory('$vaultDirectoryPath/$folderName');
    if (!subDir.existsSync()) {
      try {
        subDir.createSync(recursive: true);
      } catch (_) {}
    }

    notifyListeners();
    return newFolder;
  }

  Future<void> renameVaultFolder(String id, String newName) async {
    await _ready;
    final idx = _vaultFolders.indexWhere((f) => f.id == id);
    if (idx != -1) {
      _vaultFolders[idx] = VaultFolder(
        id: id,
        name: _safeFolderName(newName),
        createdAt: _vaultFolders[idx].createdAt,
      );
      await _persistFolders();
      notifyListeners();
    }
  }

  Future<void> deleteVaultFolder(String id) async {
    await _ready;
    _vaultFolders.removeWhere((f) => f.id == id);
    // Move items in this folder to root
    for (int i = 0; i < _vaultItems.length; i++) {
      if (_vaultItems[i].folderId == id) {
        _vaultItems[i] = VaultItem(
          id: _vaultItems[i].id,
          title: _vaultItems[i].title,
          originalPath: _vaultItems[i].originalPath,
          vaultPath: _vaultItems[i].vaultPath,
          ext: _vaultItems[i].ext,
          isAudio: _vaultItems[i].isAudio,
          fileSize: _vaultItems[i].fileSize,
          addedAt: _vaultItems[i].addedAt,
          folderId: null,
          sourceFolder: _vaultItems[i].sourceFolder,
          downloadRecord: _vaultItems[i].downloadRecord,
          downloadFolderIds: _vaultItems[i].downloadFolderIds,
        );
      }
    }
    await _persistFolders();
    await _persistItems();
    notifyListeners();
  }

  Future<void> moveItemToVaultFolder(String itemId, String? folderId) async {
    await _ready;
    final idx = _vaultItems.indexWhere((it) => it.id == itemId);
    if (idx != -1) {
      final old = _vaultItems[idx];
      _vaultItems[idx] = VaultItem(
        id: old.id,
        title: old.title,
        originalPath: old.originalPath,
        vaultPath: old.vaultPath,
        ext: old.ext,
        isAudio: old.isAudio,
        fileSize: old.fileSize,
        addedAt: old.addedAt,
        folderId: folderId,
        sourceFolder: old.sourceFolder,
        downloadRecord: old.downloadRecord,
        downloadFolderIds: old.downloadFolderIds,
      );
      await _persistItems();
      notifyListeners();
    }
  }

  String sourceFolderFor(VaultItem item) =>
      item.sourceFolder ?? _downloadFolder(File(item.originalPath));

  String _downloadFolder(File file) {
    final directory = file.parent.path.replaceAll('\\', '/');
    final root = DownloadManager.instance.downloadDirectory
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    if (directory == root || directory.isEmpty || directory == '.')
      return 'Downloads';
    if (directory.startsWith('$root/'))
      return directory.substring(root.length + 1);
    return directory.split('/').where((part) => part.isNotEmpty).lastOrNull ??
        'Downloads';
  }

  Future<void> moveToVault(DownloadTask task) async {
    await ready;
    if (!_isUnlocked) throw StateError('Unlock the vault first');
    if (!_moving.add(task.id)) return;
    try {
      final downloads = DownloadManager.instance;
      await downloads.ready;
      final folders = VirtualFolderService.instance;
      await folders.ready;
      final path = task.savePath ?? '';
      final file = File(path);
      if (path.isEmpty || !await file.exists())
        throw StateError('The download file is missing');
      // Use the single vault root shared by photos, folders and migration.
      final privateRoot = await Directory(vaultDirectoryPath)
          .create(recursive: true);
      final slot = await privateRoot.createTemp('media_');
      final ext = task.ext.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
      final destination = File('${slot.path}/media.$ext');
      final item = VaultItem(
        id: slot.uri.pathSegments.where((part) => part.isNotEmpty).last,
        title: task.title,
        originalPath: path,
        vaultPath: destination.path,
        ext: ext,
        isAudio: task.isAudioTask,
        fileSize: await file.length(),
        addedAt: DateTime.now(),
        sourceFolder: _downloadFolder(file),
        downloadRecord: task.toJson(),
        downloadFolderIds: folders
            .getFoldersContainingTask(task.id)
            .map((folder) => folder.id)
            .toList(),
      );
      await _moveFile(file, destination);
      _vaultItems.insert(0, item);
      try {
        await _persistItems();
      } catch (_) {
        _vaultItems.remove(item);
        await _moveFile(destination, file);
        rethrow;
      }
      await downloads.removeTaskOnly(task);
      await GalleryMediaService.instance.scanFile(path);
      notifyListeners();
    } finally {
      _moving.remove(task.id);
    }
  }

  Future<void> _moveFile(File from, File to) async {
    await to.parent.create(recursive: true);
    try {
      await from.rename(to.path);
    } on FileSystemException {
      try {
        await from.copy(to.path);
        await from.delete();
      } catch (_) {
        if (await to.exists() && await from.exists()) await to.delete();
        rethrow;
      }
    }
  }

  Future<void> importPhotoToVault({
    required String filePath,
    required String title,
    String? folderId,
  }) async {
    await _ready;
    if (!_isUnlocked) throw StateError('Unlock the vault first');
    final file = File(filePath);
    if (!file.existsSync()) return;

    final vaultDir = Directory(vaultDirectoryPath);
    if (!vaultDir.existsSync()) {
      vaultDir.createSync(recursive: true);
    }

    final ext = filePath.contains('.') ? filePath.split('.').last : 'jpg';
    final vaultFileName =
        'vault_photo_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final vaultPath = '${vaultDir.path}/$vaultFileName';

    try {
      file.copySync(vaultPath);
    } catch (_) {
      // Never index an item whose vault copy does not exist — it would break
      // restore, playback and deletion later on.
      return;
    }

    final item = VaultItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title.isNotEmpty
          ? title
          : 'Secret Photo ${DateTime.now().millisecond}',
      originalPath: filePath,
      vaultPath: vaultPath,
      ext: ext,
      isAudio: false,
      fileSize: File(vaultPath).existsSync()
          ? File(vaultPath).lengthSync()
          : 512 * 1024,
      addedAt: DateTime.now(),
      folderId: folderId,
    );

    _vaultItems.insert(0, item);
    await _persistItems();
    notifyListeners();
  }

  Future<void> restoreFromVault(VaultItem item) async {
    await ready;
    if (!_isUnlocked) throw StateError('Unlock the vault first');
    if (!_vaultItems.contains(item) || !_restoring.add(item.id)) return;
    try {
      final vaultFile = File(item.vaultPath);
      final original = File(item.originalPath);
      if (!await vaultFile.exists())
        throw StateError('The vault file is missing');
      if (await original.exists())
        throw StateError('A file already exists in the original folder');
      await _moveFile(vaultFile, original);
      final index = _vaultItems.indexOf(item);
      _vaultItems.remove(item);
      try {
        await _persistItems();
      } catch (_) {
        _vaultItems.insert(index, item);
        await _moveFile(original, vaultFile);
        rethrow;
      }
      final record = item.downloadRecord;
      final task = record == null
          ? DownloadTask(
              id: 'restored_${item.id}',
              title: item.title,
              author: '',
              thumbnailUrl: '',
              formatLabel: item.ext.toUpperCase(),
              ext: item.ext,
              isAudio: item.isAudio,
              category: item.isImage
                  ? 'image'
                  : (item.isAudio ? 'audio' : 'video'),
              originalUrl: '',
              totalBytes: item.fileSize,
              downloadedBytes: item.fileSize,
              status: DownloadStatus.completed,
              completedAt: item.addedAt,
            )
          : DownloadTask.fromJson(record);
      task.savePath = original.path;
      await DownloadManager.instance.restoreCompletedTask(task);
      final folders = VirtualFolderService.instance;
      await folders.ready;
      for (final folder in item.downloadFolderIds) {
        if (!folders.isTaskInFolder(folder, task.id)) {
          await folders.toggleItemInFolder(folder, task.id);
        }
      }
      await GalleryMediaService.instance.scanFile(original.path);
      notifyListeners();
    } finally {
      _restoring.remove(item.id);
    }
  }

  Future<void> deleteFromVault(VaultItem item) async {
    await ready;
    if (!_isUnlocked) throw StateError('Unlock the vault first');
    if (!_vaultItems.contains(item) || !_restoring.add(item.id)) return;
    try {
      final vaultFile = File(item.vaultPath);
      if (await vaultFile.exists()) await vaultFile.delete();
      _vaultItems.remove(item);
      await _persistItems();
      notifyListeners();
    } finally {
      _restoring.remove(item.id);
    }
  }

  Future<void> _persistFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _vaultFolders.map((e) => e.toJson()).toList();
    await prefs.setString('vault_folders_list', json.encode(list));
  }

  Future<void> _persistItems() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _vaultItems.map((e) => e.toJson()).toList();
    if (!await prefs.setString('vault_items_list', json.encode(list))) {
      throw StateError('Could not save the vault index');
    }
  }
}
