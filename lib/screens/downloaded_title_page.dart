import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../services/download_manager.dart';
import '../services/watch_history_service.dart';
import '../theme/app_palette.dart';
import '../utils/episode_parser.dart';
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
        builder: (_) =>
            DownloadedTitlePage(title: title, tasks: tasks, isSeries: isSeries),
      ),
    );
  }

  @override
  State<DownloadedTitlePage> createState() => _DownloadedTitlePageState();
}

class _DownloadedTitlePageState extends State<DownloadedTitlePage> {
  String? _season;
  String? _language;
  final Set<String> _removedIds = {};

  List<DownloadTask> get _currentTasks =>
      widget.tasks.where((task) => !_removedIds.contains(task.id)).toList();

  int _episode(DownloadTask task) =>
      EpisodeParser.episode(task.title) ??
      EpisodeParser.episode(task.savePath ?? '') ??
      0;

  String _seasonOf(DownloadTask task) {
    final explicit =
        EpisodeParser.season(task.title) ??
        EpisodeParser.season(task.seriesSeason ?? '') ??
        EpisodeParser.season(task.savePath ?? '');
    if (explicit != null) return 'Season $explicit';
    final named = task.seriesSeason?.trim();
    if (named != null && named.isNotEmpty) return named;
    return 'Season 1';
  }

  String _languageOf(DownloadTask task) {
    final explicit = task.seriesLanguage?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final match = RegExp(r'\[([A-Za-z]+)\]').firstMatch(task.title)?.group(1);
    return match ?? 'Original';
  }

  List<DownloadTask> get _filtered {
    var list = List<DownloadTask>.from(_currentTasks);
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
    final list = _currentTasks.map(_seasonOf).toSet().toList();
    list.sort((a, b) {
      final x = EpisodeParser.season(a) ?? 0;
      final y = EpisodeParser.season(b) ?? 0;
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
    final currentTasks = _currentTasks;
    final languages = currentTasks.map(_languageOf).toSet().toList()..sort();
    final tasks = _filtered;
    final posterUrl = currentTasks.isNotEmpty
        ? (currentTasks.first.thumbnailUrl.isNotEmpty
              ? currentTasks.first.thumbnailUrl
              : currentTasks.first.series?.posterUrl ?? '')
        : '';

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
              '${currentTasks.length} downloaded',
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
            // ── Hero banner ───────────────────────────────────────────────
            _buildHero(p, posterUrl),
            const SizedBox(height: 18),
            if (widget.isSeries && currentTasks.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: PopupMenuButton<String>(
                  tooltip: 'Manage all downloaded episodes and seasons',
                  onSelected: (value) {
                    if (value == 'all') {
                      _confirmDelete(currentTasks, 'the full series');
                    } else if (value.startsWith('season:')) {
                      final season = value.substring('season:'.length);
                      _confirmDelete(
                        currentTasks
                            .where((task) => _seasonOf(task) == season)
                            .toList(),
                        season,
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'all',
                      child: Text('Delete all downloads'),
                    ),
                    for (final season in seasons)
                      PopupMenuItem(
                        value: 'season:$season',
                        child: Text('Delete $season'),
                      ),
                  ],
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: p.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: p.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.download_for_offline_rounded,
                            color: p.primary,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'All Download',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_drop_down_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            if (widget.isSeries && seasons.isNotEmpty) ...[
              _buildSectionTitle('Downloaded seasons', p),
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
              const SizedBox(height: 16),
            ],
            if (languages.length > 1) ...[
              _buildSectionTitle('Languages', p),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final language in languages)
                    ChoiceChip(
                      label: Text(language),
                      selected: _language == language,
                      onSelected: (_) => setState(
                        () =>
                            _language = _language == language ? null : language,
                      ),
                      selectedColor: p.secondary,
                      backgroundColor: p.card,
                      side: BorderSide(
                        color: _language == language ? p.secondary : p.border,
                      ),
                      labelStyle: TextStyle(
                        color: _language == language
                            ? p.onSecondary
                            : p.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            _buildSectionTitle(
              _season != null
                  ? '$_season · ${tasks.length} downloaded'
                  : '${tasks.length} downloaded',
              p,
            ),
            const SizedBox(height: 10),
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
              ...tasks.map(
                (task) => DownloadItemTile(
                  key: ValueKey(task.id),
                  task: task,
                  episodeMode: true,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(List<DownloadTask> tasks, String label) async {
    if (tasks.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete downloaded files?'),
        content: Text('Delete ${tasks.length} downloaded file(s) from $label?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: context.palette.critical,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DownloadManager.instance.deleteTasks(tasks);
    if (!mounted) return;
    setState(() {
      _removedIds.addAll(tasks.map((task) => task.id));
      if (_season != null && !_seasons.contains(_season))
        _season = _seasons.firstOrNull;
    });
  }

  Widget _buildSectionTitle(String label, AppPalette p) => Text(
    label,
    style: TextStyle(
      color: p.textPrimary,
      fontSize: 13.5,
      fontWeight: FontWeight.w800,
    ),
  );

  Widget _buildHero(AppPalette p, String posterUrl) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        children: [
          SizedBox(
            height: 148,
            width: double.infinity,
            child: posterUrl.isNotEmpty
                ? SmartNetworkImage(
                    url: posterUrl,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: 148,
                    placeholderColor: p.card,
                    placeholderIcon: Icons.movie_rounded,
                  )
                : Container(color: p.card),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [p.scrimAt(0.15), p.scrimAt(0.88)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.onScrim,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(
                      Icons.download_done_rounded,
                      size: 14,
                      color: p.success,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${widget.tasks.length} episodes ready to watch offline',
                      style: TextStyle(
                        color: p.onScrim,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
