import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VirtualFolder {
  final String id;
  final String name;
  final String icon;
  final String colorHex;
  final List<String> taskIds;
  final DateTime createdAt;

  const VirtualFolder({
    required this.id,
    required this.name,
    this.icon = 'folder_rounded',
    this.colorHex = 'FF1DB954',
    this.taskIds = const [],
    required this.createdAt,
  });

  VirtualFolder copyWith({
    String? name,
    String? icon,
    String? colorHex,
    List<String>? taskIds,
  }) {
    return VirtualFolder(
      id: id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      colorHex: colorHex ?? this.colorHex,
      taskIds: taskIds ?? this.taskIds,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'colorHex': colorHex,
    'taskIds': taskIds,
    'createdAt': createdAt.toIso8601String(),
  };

  factory VirtualFolder.fromJson(Map<String, dynamic> json) => VirtualFolder(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? 'Folder',
    icon: json['icon'] as String? ?? 'folder_rounded',
    colorHex: json['colorHex'] as String? ?? 'FF1DB954',
    taskIds: (json['taskIds'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}

class VirtualFolderService extends ChangeNotifier {
  static final VirtualFolderService instance = VirtualFolderService._();
  VirtualFolderService._() {
    ready = _init();
  }

  static const String _prefsKey = 'snaptube_virtual_folders_v2';
  List<VirtualFolder> _folders = [];

  /// Completes once the persisted folder lists are loaded. Used by startup
  /// housekeeping so prune passes never run against an empty in-memory copy.
  /// Assigned by the constructor — `_init()` runs exactly once.
  late final Future<void> ready;

  List<VirtualFolder> get folders => List.unmodifiable(_folders);

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final List<dynamic> list = jsonDecode(raw);
        _folders = list.map((e) => VirtualFolder.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        _folders = _getDefaultFolders();
      }
    } else {
      _folders = _getDefaultFolders();
      await _save();
    }
    notifyListeners();
  }

  List<VirtualFolder> _getDefaultFolders() {
    return [];
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_folders.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, raw);
  }

  Future<VirtualFolder> createFolder(String name, {String icon = 'folder_rounded', String colorHex = 'FF1DB954', String? baseDirectory}) async {
    final folderName = name.trim();
    final newFolder = VirtualFolder(
      id: 'vf_${DateTime.now().millisecondsSinceEpoch}',
      name: folderName,
      icon: icon,
      colorHex: colorHex,
      taskIds: [],
      createdAt: DateTime.now(),
    );
    _folders.add(newFolder);
    await _save();

    // Create real directory on disk under SnapTube downloads path
    if (baseDirectory != null && baseDirectory.isNotEmpty) {
      try {
        final realDir = Directory('$baseDirectory/$folderName');
        if (!realDir.existsSync()) {
          realDir.createSync(recursive: true);
        }
      } catch (_) {}
    }

    notifyListeners();
    return newFolder;
  }

  Future<void> renameFolder(String id, String newName) async {
    final idx = _folders.indexWhere((f) => f.id == id);
    if (idx != -1) {
      _folders[idx] = _folders[idx].copyWith(name: newName.trim());
      await _save();
      notifyListeners();
    }
  }

  Future<void> deleteFolder(String id) async {
    _folders.removeWhere((f) => f.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> toggleItemInFolder(String folderId, String taskId) async {
    final idx = _folders.indexWhere((f) => f.id == folderId);
    if (idx != -1) {
      final currentList = List<String>.from(_folders[idx].taskIds);
      if (currentList.contains(taskId)) {
        currentList.remove(taskId);
      } else {
        currentList.add(taskId);
      }
      _folders[idx] = _folders[idx].copyWith(taskIds: currentList);
      await _save();
      notifyListeners();
    }
  }

  Future<void> addItemToFolderByName(String folderName, String taskId) async {
    final idx = _folders.indexWhere((f) => f.name.toLowerCase() == folderName.toLowerCase());
    if (idx != -1) {
      final currentList = List<String>.from(_folders[idx].taskIds);
      if (!currentList.contains(taskId)) {
        currentList.add(taskId);
        _folders[idx] = _folders[idx].copyWith(taskIds: currentList);
        await _save();
        notifyListeners();
      }
    }
  }

  List<VirtualFolder> getFoldersContainingTask(String taskId) {
    return _folders.where((f) => f.taskIds.contains(taskId)).toList();
  }

  /// Strips a task from EVERY folder the moment it leaves the download index
  /// (deleted, vault-locked, cancelled). Without this the folder tile keeps
  /// counting an id whose file is gone, while opening the folder shows
  /// nothing because the live task list no longer contains it.
  Future<void> removeTaskEverywhere(String taskId) async {
    var changed = false;
    for (var i = 0; i < _folders.length; i++) {
      if (_folders[i].taskIds.contains(taskId)) {
        _folders[i] = _folders[i].copyWith(
          taskIds: _folders[i].taskIds.where((id) => id != taskId).toList(),
        );
        changed = true;
      }
    }
    if (changed) {
      await _save();
      notifyListeners();
    }
  }

  /// Startup housekeeping: drops folder ids that are not present in the
  /// persisted download index (stale entries left by deletions from before).
  /// Reads the stored tasks directly, so it needs no DownloadManager import.
  Future<void> syncWithStoredTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tasksJson = prefs.getString('saved_download_tasks');
      final valid = <String>{};
      if (tasksJson != null) {
        for (final item in json.decode(tasksJson) as List<dynamic>) {
          final id = (item as Map<String, dynamic>)['id'];
          if (id != null) valid.add(id.toString());
        }
      }
      var changed = false;
      for (var i = 0; i < _folders.length; i++) {
        final kept = _folders[i].taskIds.where(valid.contains).toList();
        if (kept.length != _folders[i].taskIds.length) {
          _folders[i] = _folders[i].copyWith(taskIds: kept);
          changed = true;
        }
      }
      if (changed) {
        await _save();
        notifyListeners();
      }
    } catch (_) {}
  }

  bool isTaskInFolder(String folderId, String taskId) {
    final f = _folders.firstWhere((f) => f.id == folderId, orElse: () => VirtualFolder(id: '', name: '', createdAt: DateTime.now()));
    return f.taskIds.contains(taskId);
  }
}
