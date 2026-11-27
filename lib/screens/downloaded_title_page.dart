import 'dart:io';

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

  /// The episode the page-level Resume button should open: the most recently
  /// watched local file, including its exact season, episode and position.
  ({DownloadTask task, WatchHistoryItem? history})? _resumeCandidate() {
    final playable = _currentTasks
        .where(
          (task) =>
              !task.isAudioTask &&
              !task.isImageTask &&
              (task.savePath ?? '').isNotEmpty &&
              File(task.savePath!).existsSync(),
        )
        .toList();
    if (playable.isEmpty) return null;
    WatchHistoryItem? best;
    DownloadTask? bestTask;
    for (final task in playable) {
      final history = WatchHistoryService.instance.getProgress(task.id);
      if (history == null) continue;
      if (best == null || history.lastWatched.isAfter(best.lastWatched)) {
        best = history;
        bestTask = task;
      }
    }
    bestTask ??= playable.first;
    return (task: bestTask, history: best);
  }

  String _resumeSubtitle({
    required DownloadTask task,
    WatchHistoryItem? history,
  }) {
    final season =
        history?.seasonNumber ??
        EpisodeParser.season(task.seriesSeason ?? '') ??
        EpisodeParser.season(task.title) ??
        EpisodeParser.season(task.savePath ?? '') ??
        1;
    final parsedEpisode = _episode(task);
    final episode = history?.episodeNumber ??
        (parsedEpisode > 0 ? parsedEpisode : 1);
    if (history != null && history.positionSeconds > 0) {
      return 'S$season E$episode · ${history.positionFormatted}';
    }
    return 'S$season E$episode · Start';
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
            _buildHero(p, posterUrl, currentTasks, tasks),
            const SizedBox(height: 18),
            const SizedBox(height: 2),
            if (widget.isSeries && seasons.isNotEmpty) ...[
              _buildSectionTitle('Downloaded seasons', p),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final season in seasons)
                    _seasonPill(p, season, selected: _season == season),
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

  Widget _seasonPill(AppPalette p, String season, {required bool selected}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () =>
            setState(() => _season = selected ? null : season),
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? p.primary : p.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? p.primary : p.border,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: p.shadowAt(0.22),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: p.onPrimary,
                  ),
                ),
              Text(
                season,
                style: TextStyle(
                  color: selected ? p.onPrimary : p.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeleteButton(AppPalette p, List<DownloadTask> targets) {
    return Tooltip(
      message: 'Delete selected downloads',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _confirmDelete(targets, 'this selection'),
          borderRadius: BorderRadius.circular(13),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: p.scrimAt(0.55),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: p.tint(p.onScrim, 0.28)),
            ),
            child: Icon(
              Icons.delete_outline_rounded,
              color: p.onScrim,
              size: 17,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResumeButton(
    AppPalette p,
    ({DownloadTask task, WatchHistoryItem? history})? candidate,
  ) {
    final subtitle = candidate == null
        ? 'Nothing to resume'
        : _resumeSubtitle(
            task: candidate.task,
            history: candidate.history,
          );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: candidate == null
            ? null
            : () => DownloadItemTile.playTask(context, candidate.task),
        borderRadius: BorderRadius.circular(15),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            gradient: candidate == null ? null : p.primaryGradient,
            color: candidate == null ? p.disabledBg : null,
            borderRadius: BorderRadius.circular(14),
            boxShadow: candidate == null
                ? null
                : [
                    BoxShadow(
                      color: p.shadowAt(0.34),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_arrow_rounded,
                color: candidate == null ? p.textSecondary : p.onPrimary,
                size: 17,
              ),
              const SizedBox(width: 5),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Resume',
                    maxLines: 1,
                    style: TextStyle(
                      color: candidate == null
                          ? p.textSecondary
                          : p.onPrimary,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: (candidate == null ? p.textSecondary : p.onPrimary)
                          .withValues(alpha: 0.78),
                      fontSize: 8,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
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

  Widget _buildSectionTitle(String label, AppPalette p) => Row(
    children: [
      Container(
        width: 3,
        height: 15,
        decoration: BoxDecoration(
          color: p.primary,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          style: TextStyle(
            color: p.textPrimary,
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.1,
          ),
        ),
      ),
    ],
  );

  Widget _buildHero(
    AppPalette p,
    String posterUrl,
    List<DownloadTask> currentTasks,
    List<DownloadTask> tasks,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: Stack(
        children: [
          SizedBox(
            height: 176,
            width: double.infinity,
            child: posterUrl.isNotEmpty
                ? SmartNetworkImage(
                    url: posterUrl,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: 176,
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
            top: 14,
            left: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: p.scrimAt(0.45),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: p.tint(p.onScrim, 0.22)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.download_done_rounded,
                    size: 12,
                    color: p.success,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'OFFLINE READY',
                    style: TextStyle(
                      color: p.onScrim,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.isSeries && currentTasks.isNotEmpty)
            Positioned(
              right: 12,
              bottom: 14,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDeleteButton(
                    p,
                    tasks.isNotEmpty ? tasks : currentTasks,
                  ),
                  const SizedBox(width: 8),
                  _buildResumeButton(p, _resumeCandidate()),
                ],
              ),
            ),
          Positioned(
            left: 16,
            right: widget.isSeries ? 158 : 16,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.onScrim,
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                    height: 1.18,
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
