import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../services/watch_history_service.dart';
import '../theme/app_palette.dart';
import '../widgets/download_item_tile.dart';
import '../widgets/remote_image.dart';

/// Full page (not a bottom sheet) for one downloaded movie or series.
/// Season/language tags sit on top; episodes are ordered 1 → last.
class DownloadedTitlePage extends StatefulWidget {
  const DownloadedTitlePage({
    super.key,
    required this.title,
    required this.tasks,
    required this.isSeries,
  });

  final String title;
  final List<DownloadTask> tasks;
  final bool isSeries;

  static Future<void> show(
    BuildContext context, {
    required String title,
    required List<DownloadTask> tasks,
    required bool isSeries,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadedTitlePage(
          title: title,
          tasks: tasks,
          isSeries: isSeries,
        ),
      ),
    );
  }

  @override
  State<DownloadedTitlePage> createState() => _DownloadedTitlePageState();
}

class _DownloadedTitlePageState extends State<DownloadedTitlePage> {
  static final _seasonPattern = RegExp(r'(?:Season\s*|S)(\d+)', caseSensitive: false);
  static final _episodePattern = RegExp(r'(?:Episode\s*|E)(\d+)', caseSensitive: false);

  String? _season;
  String? _language;

  int _episode(DownloadTask task) =>
      int.tryParse(_episodePattern.firstMatch(task.title)?.group(1) ?? '') ?? 0;

  String _seasonOf(DownloadTask task) {
    final m = _seasonPattern.firstMatch(task.title);
    if (m != null) return 'Season ${m.group(1)}';
    final explicit = task.seriesSeason?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final pathMatch = _seasonPattern.firstMatch(task.savePath ?? '');
    if (pathMatch != null) return 'Season ${pathMatch.group(1)}';
    return 'Season 1';
  }

  String _languageOf(DownloadTask task) {
    final explicit = task.seriesLanguage?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final match = RegExp(
      r'\[([A-Za-z]+)\]',
    ).firstMatch(task.title)?.group(1);
    return match ?? 'Original';
  }

  List<DownloadTask> get _filtered {
    var list = List<DownloadTask>.from(widget.tasks);
    if (_season != null) {
      list = list.where((t) => _seasonOf(t) == _season).toList();
    }
    if (_language != null) {
      list = list.where((t) => _languageOf(t) == _language).toList();
    }
    list.sort((a, b) => _episode(a).compareTo(_episode(b)));
    return list;
  }

  List<String> get _seasons {
    final list = widget.tasks.map(_seasonOf).toSet().toList();
    list.sort((a, b) {
      final x = int.tryParse(_seasonPattern.firstMatch(a)?.group(1) ?? '') ?? 0;
      final y = int.tryParse(_seasonPattern.firstMatch(b)?.group(1) ?? '') ?? 0;
      return x.compareTo(y);
    });
    return list;
  }

  @override
  void initState() {
    super.initState();
    if (widget.isSeries) _season = _seasons.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final seasons = _seasons;
    final languages = widget.tasks.map(_languageOf).toSet().toList()..sort();
    final tasks = _filtered;

    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.background,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              '${widget.tasks.length} downloaded',
              style: TextStyle(color: p.textSecondary, fontSize: 11),
            ),
          ],
        ),
      ),
      body: AnimatedBuilder(
        animation: WatchHistoryService.instance,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            if (widget.isSeries && seasons.isNotEmpty) ...[
              Text(
                'Downloaded seasons',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final season in seasons)
                    ChoiceChip(
                      label: Text(season),
                      selected: _season == season,
                      onSelected: (_) => setState(
                        () => _season = _season == season ? null : season,
                      ),
                      selectedColor: p.primary,
                      backgroundColor: p.card,
                      side: BorderSide(
                        color: _season == season ? p.primary : p.border,
                      ),
                      labelStyle: TextStyle(
                        color: _season == season ? p.onPrimary : p.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (languages.length > 1) ...[
              Text(
                'Languages',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final language in languages)
                    ChoiceChip(
                      label: Text(language),
                      selected: _language == language,
                      onSelected: (_) => setState(
                        () => _language = _language == language ? null : language,
                      ),
                      selectedColor: p.secondary,
                      backgroundColor: p.card,
                      side: BorderSide(
                        color: _language == language ? p.secondary : p.border,
                      ),
                      labelStyle: TextStyle(
                        color: _language == language ? p.onSecondary : p.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (_season != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '$_season · ${tasks.length} downloaded',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    'No downloaded files in this selection.',
                    style: TextStyle(color: p.textSecondary, fontSize: 13),
                  ),
                ),
              )
            else
              ...tasks.map((task) {
                final history = WatchHistoryService.instance
                    .getProgress(task.id);
                final ratio = history == null || history.totalSeconds <= 0
                    ? 0.0
                    : (history.positionSeconds / history.totalSeconds).clamp(
                        0.0,
                        1.0,
                      );
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DownloadItemTile(key: ValueKey(task.id), task: task),
                      if (ratio > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: ratio,
                              minHeight: 4,
                              backgroundColor: p.trackBg,
                              color: p.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
