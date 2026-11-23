import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_palette.dart';

/// A dependency-free folder chooser that works on every platform (including
/// desktop and test hosts, where the Android SAF channel is unavailable).
///
/// Returns the directory the user confirmed, or `null` when cancelled.
class FolderPickerSheet extends StatefulWidget {
  const FolderPickerSheet({
    super.key,
    required this.initialPath,
    this.title = 'Choose Download Folder',
  });

  final String initialPath;
  final String title;

  static Future<String?> show(
    BuildContext context, {
    required String initialPath,
  }) {
    return showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FolderPickerSheet(initialPath: initialPath),
    );
  }

  @override
  State<FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends State<FolderPickerSheet> {
  late String _current;
  late final TextEditingController _pathCtrl;
  List<String> _folders = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _current = _nearestExisting(widget.initialPath);
    _pathCtrl = TextEditingController(text: _current);
    _load();
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  String _nearestExisting(String path) {
    var dir = Directory(path);
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    return dir.path;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final dir = Directory(_current);
      final items = await dir
          .list()
          .where((entity) => entity is Directory)
          .map((entity) => entity.path)
          .toList();
      items.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _folders = items;
        _error = null;
        _loading = false;
        _pathCtrl.text = _current;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _folders = [];
        _error = 'This folder cannot be listed: $error. '
            'You can still type a path below.';
        _loading = false;
      });
    }
  }

  void _open(String path) {
    setState(() => _current = path);
    unawaited(_load());
  }

  void _goUp() {
    final parent = Directory(_current).parent.path;
    if (parent != _current) _open(parent);
  }

  void _confirm([String? path]) {
    final target = (path ?? _pathCtrl.text).trim();
    if (target.isEmpty) return;
    Navigator.of(context).pop(target);
  }

  String _label(String path) {
    final name = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull;
    return name ?? path;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return FractionallySizedBox(
      heightFactor: 0.78,
      child: Container(
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                decoration: BoxDecoration(
                  color: p.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.folder_rounded, color: p.primary, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: p.textSecondary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Parent folder',
                      icon: Icon(Icons.arrow_upward_rounded, color: p.primary),
                      onPressed: _goUp,
                    ),
                    Expanded(
                      child: Text(
                        _current,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: p.border),
              Expanded(
                child: _loading
                    ? Center(
                        child: CircularProgressIndicator(color: p.primary),
                      )
                    : _error != null
                        ? Padding(
                            padding: const EdgeInsets.all(18),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: p.error,
                                fontSize: 12.5,
                              ),
                            ),
                          )
                        : _folders.isEmpty
                            ? Center(
                                child: Text(
                                  'No sub-folders here — use this folder.',
                                  style: TextStyle(
                                    color: p.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                itemCount: _folders.length,
                                separatorBuilder: (_, __) =>
                                    Divider(height: 1, color: p.border),
                                itemBuilder: (context, index) {
                                  final path = _folders[index];
                                  return ListTile(
                                    leading: Icon(
                                      Icons.folder_open_rounded,
                                      color: p.primary,
                                      size: 22,
                                    ),
                                    title: Text(
                                      _label(path),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.textPrimary,
                                        fontSize: 14,
                                      ),
                                    ),
                                    trailing: Icon(
                                      Icons.chevron_right_rounded,
                                      color: p.textSecondary,
                                      size: 20,
                                    ),
                                    onTap: () => _open(path),
                                  );
                                },
                              ),
              ),
              Divider(height: 1, color: p.border),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  10,
                  16,
                  10 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pathCtrl,
                        onSubmitted: (_) => _confirm(),
                        decoration: InputDecoration(
                          hintText: '/storage/emulated/0/Download',
                          prefixIcon: Icon(
                            Icons.edit_location_alt_rounded,
                            color: p.primary,
                            size: 20,
                          ),
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        style: TextStyle(color: p.textPrimary, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: () => _confirm(),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Use'),
                      style: FilledButton.styleFrom(
                        backgroundColor: p.primary,
                        foregroundColor: p.onPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
