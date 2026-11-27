import 'dart:io';

import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../models/movie_model.dart';
import '../services/download_manager.dart';
import '../services/player_service.dart';
import '../services/watch_history_service.dart';
import 'mpv_player_screen.dart';
import '../services/virtual_folder_service.dart';
import '../theme/app_palette.dart';
import '../utils/episode_parser.dart';
import 'downloaded_title_page.dart';
import '../widgets/download_item_tile.dart';
import '../widgets/folder_picker_sheet.dart';
import '../widgets/movie_card.dart';
import '../widgets/remote_image.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  Future<void> _pickFolder(BuildContext context) async {
    final manager = DownloadManager.instance;
    final picked = await FolderPickerSheet.show(
      context,
      initialPath: manager.downloadDirectory,
    );
    if (picked == null || picked.isEmpty || !context.mounted) return;
    await manager.setDownloadDirectory(picked);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Downloads now save to $picked'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  int _activeTabIndex = 0; // 0 = Downloading, 1 = Downloaded
  String? _openedFolderType; // null = Root Folder View, 'custom_id'
  String? _openedFolderName;
  String? _openedWebsite; // e.g. 'YouTube'
  String? _openedChannel; // e.g. 'MrBeast'
  String _inFolderFilter = 'All'; // Filter inside opened folder: 'All', 'Videos', 'Music', 'Images', 'Movies'

  static final _episodeTitle = RegExp(
    r'^(.*?) - (?:(?:Season\s+(\d+)\s*·\s*)?Episode\s+\d+|S(\d+)E\d+)\b',
    caseSensitive: false,
  );
  static final _numberedEpisode = RegExp(
    r'(?:Episode\s*|E)(\d+)',
    caseSensitive: false,
  );

  int _episodeNumber(DownloadTask task) =>
      int.tryParse(_numberedEpisode.firstMatch(task.title)?.group(1) ?? '') ??
      0;

  String? _seriesTitle(DownloadTask task) =>
      task.series?.title ?? _episodeTitle.firstMatch(task.title)?.group(1);

  Map<String, Map<String, List<DownloadTask>>> _websiteFolders(
    DownloadManager manager,
  ) => manager.organizeWebsiteFolders(
    manager.completedTasks.where((task) => task.category != 'movie'),
  );

  void _showCreateFolderDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.create_new_folder_rounded,
              color: context.palette.primary,
            ),
            SizedBox(width: 8),
            Text(
              'Create Real Folder',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter folder name to create a real directory on disk:',
              style: TextStyle(fontSize: 12, color: context.palette.onPrimary),
            ),
            SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'e.g. Bengali Cinema, Gym Beats',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.palette.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) {
                final name = ctrl.text.trim();
                Navigator.pop(ctx);
                VirtualFolderService.instance.createFolder(
                  name,
                  baseDirectory: DownloadManager.instance.downloadDirectory,
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Created folder "$name" on disk!'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: Text(
              'Create Folder',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: context.palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: Listenable.merge([
        DownloadManager.instance,
        VirtualFolderService.instance,
      ]),
      builder: (context, _) {
        final manager = DownloadManager.instance;
        final folderService = VirtualFolderService.instance;
        final activeList = manager.activeTasks;
        // Files that live inside a user folder are shown ONLY there — the
        // All Downloaded history stays clean.
        final filedIds = {
          for (final f in folderService.folders)
            for (final id in f.taskIds) id,
        };
        final completedList = manager.completedTasks
            .where((t) => !filedIds.contains(t.id))
            .toList();

        return Scaffold(
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButton:
              _activeTabIndex == 1 &&
                  _openedFolderType == null &&
                  _openedWebsite == null
              ? Padding(
                  padding: EdgeInsets.only(bottom: 76.0),
                  child: FloatingActionButton(
                    backgroundColor: context.palette.primary,
                    foregroundColor: context.palette.card,
                    shape: CircleBorder(),
                    elevation: 5,
                    tooltip: 'New Folder',
                    onPressed: _showCreateFolderDialog,
                    child: Icon(Icons.create_new_folder_rounded, size: 28),
                  ),
                )
              : null,
          body: SafeArea(
            child: Column(
              children: [
                // Hyper-Modern Animated Sliding Tab Switcher
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0x1AFFFFFF)
                          : Colors.black.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color: isDark
                            ? const Color(0x22FFFFFF)
                            : Colors.black12,
                        width: 1,
                      ),
                    ),
                    child: Stack(
                      children: [
                        // Smooth Sliding Active Pill Indicator
                        AnimatedAlign(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                          alignment: _activeTabIndex == 0
                              ? Alignment.centerLeft
                              : Alignment.centerRight,
                          child: FractionallySizedBox(
                            widthFactor: 0.5,
                            child: Container(
                              decoration: BoxDecoration(
                                color: context.palette.primary,
                                borderRadius: BorderRadius.circular(22),
                                boxShadow: [
                                  BoxShadow(
                                    color: context.palette.primary.withValues(
                                      alpha: 0.35,
                                    ),
                                    blurRadius: 12,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Tab Options Layer
                        Row(
                          children: [
                            // Tab 0: Downloading
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () =>
                                    setState(() => _activeTabIndex = 0),
                                child: Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.download_rounded,
                                        size: 18,
                                        color: _activeTabIndex == 0
                                            ? context.palette.onPrimary
                                            : context.palette.textPrimary,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Downloading',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13,
                                          color: _activeTabIndex == 0
                                              ? context.palette.onPrimary
                                              : context.palette.textPrimary,
                                        ),
                                      ),
                                      if (activeList.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _activeTabIndex == 0
                                                ? context.palette.onPrimary
                                                : context.palette.primary
                                                      .withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                          child: Text(
                                            '${activeList.length}',
                                            style: TextStyle(
                                              color: context.palette.primary,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),

                            // Tab 1: Downloaded
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () =>
                                    setState(() => _activeTabIndex = 1),
                                child: Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.cloud_done_rounded,
                                        size: 18,
                                        color: _activeTabIndex == 1
                                            ? context.palette.onPrimary
                                            : context.palette.textPrimary,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Downloaded',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13,
                                          color: _activeTabIndex == 1
                                              ? context.palette.onPrimary
                                              : context.palette.textPrimary,
                                        ),
                                      ),
                                      if (completedList.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _activeTabIndex == 1
                                                ? context.palette.onPrimary
                                                : context.palette.primary
                                                      .withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                          child: Text(
                                            '${completedList.length}',
                                            style: TextStyle(
                                              color: context.palette.primary,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                SizedBox(height: 12),

                // Content View
                Expanded(
                  child: _activeTabIndex == 0
                      ? (activeList.isEmpty
                            ? _buildEmptyState(
                                icon: Icons.cloud_download_outlined,
                                title: 'No active downloads',
                                subtitle:
                                    'Add a video or audio link from Home.',
                              )
                            : Column(
                                children: [
                                  _buildActiveDownloadsHeader(
                                    activeList,
                                    isDark,
                                  ),
                                  Expanded(
                                    child: ListView.builder(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 4,
                                      ),
                                      itemCount: activeList.length,
                                      itemBuilder: (context, index) {
                                        return DownloadItemTile(
                                          task: activeList[index],
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ))
                      : (_openedFolderType == null && _openedWebsite == null
                            ? _buildFoldersGridRootView(
                                manager,
                                folderService,
                                isDark,
                                completedList.where(
                                  (task) => task.category == 'movie',
                                ),
                              )
                            : (_openedFolderType != null
                                  ? _buildFolderContentDetailView(
                                      manager,
                                      folderService,
                                      isDark,
                                    )
                                  : (_openedChannel == null
                                        ? _buildWebsiteChannelsView(
                                            manager,
                                            isDark,
                                          )
                                        : _buildChannelContentDetailView(
                                            manager,
                                            isDark,
                                          )))),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 2-Column Grid Folder View with Auto-Organized Website & Channel Folders
  Widget _buildFoldersGridRootView(
    DownloadManager manager,
    VirtualFolderService folderService,
    bool isDark,
    Iterable<DownloadTask> movieTasks,
  ) {
    final websiteFolders = _websiteFolders(manager);
    final userFolders = folderService.folders;
    final titles = <(bool, String, String), List<DownloadTask>>{};
    final knownSeries = {
      for (final task in movieTasks)
        if (task.series case final series?)
          (series.title, series.posterUrl): (
            true,
            series.providerId,
            series.id,
          ),
    };
    for (final task in movieTasks) {
      final title = _seriesTitle(task);
      final series = task.series;
      final key = title == null
          ? (false, '', task.id)
          : series != null
          ? (true, series.providerId, series.id)
          : knownSeries[(title, task.thumbnailUrl)] ??
                (true, task.thumbnailUrl, title);
      titles.putIfAbsent(key, () => []).add(task);
    }
    final movieGroups = titles.values.toList();

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 110),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (movieGroups.isNotEmpty) ...[
            Row(
              children: [
                Container(
                  width: 3,
                  height: 18,
                  decoration: BoxDecoration(
                    color: context.palette.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  'Movies & Series',
                  style: TextStyle(
                    color: context.palette.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: context.palette.selectedBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${movieGroups.length}',
                    style: TextStyle(
                      color: context.palette.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            GridView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              gridDelegate: MovieCard.catalogGrid,
              itemCount: movieGroups.length,
              itemBuilder: (context, index) =>
                  _buildDownloadedPoster(movieGroups[index]),
            ),
            SizedBox(height: 20),
          ],
          // 1. AUTO-ORGANIZED WEBSITE FOLDERS (YouTube, Facebook, etc.)
          if (websiteFolders.isNotEmpty) ...[
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  color: context.palette.primary,
                  size: 16,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Auto Organized Folders',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.palette.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                SizedBox(width: 6),
                Text(
                  '${websiteFolders.length} sites',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.palette.onPrimary,
                  ),
                ),
                SizedBox(width: 6),
                IconButton(
                  icon: Icon(
                    Icons.folder_open_rounded,
                    color: context.palette.primary,
                    size: 18,
                  ),
                  tooltip: 'Open Directory in System Explorer',
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(),
                  onPressed: () {
                    PlayerService.instance.launchSystemPlayer(
                      manager.downloadDirectory,
                    );
                  },
                ),
              ],
            ),
            SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.15,
              ),
              itemCount: websiteFolders.keys.length,
              itemBuilder: (context, index) {
                final website = websiteFolders.keys.elementAt(index);
                final channels = websiteFolders[website]!;
                final isSeries = channels.values.any(
                  (tasks) => tasks.any((task) => task.series != null),
                );
                final folderLabel = isSeries ? 'Seasons' : 'Channels';
                final totalFiles = channels.values.fold<int>(
                  0,
                  (s, l) => s + l.length,
                );
                final hasOnlyUnknown =
                    channels.keys.length == 1 &&
                    channels.containsKey('Unknown');
                final subtitle = hasOnlyUnknown
                    ? '$totalFiles Files (Direct)'
                    : '${channels.keys.length} $folderLabel • $totalFiles Files';
                return _buildGridFolderTile(
                  title: website,
                  subtitle: subtitle,
                  icon: isSeries
                      ? Icons.video_library_rounded
                      : _iconForWebsite(website),
                  color: _colorForWebsite(website),
                  count: totalFiles,
                  isDark: isDark,
                  onTap: () {
                    setState(() {
                      _openedWebsite = website;
                      if (hasOnlyUnknown) {
                        _openedChannel = 'Unknown';
                      } else {
                        _openedChannel = null;
                      }
                      _inFolderFilter = 'All';
                    });
                  },
                  onLongPress: () {
                    PlayerService.instance.launchSystemPlayer(
                      '${manager.downloadDirectory}/$website',
                    );
                  },
                );
              },
            ),
            SizedBox(height: 16),
          ],

          // 2. USER-CREATED CUSTOM FOLDERS
          if (userFolders.isNotEmpty) ...[
            Row(
              children: [
                Icon(
                  Icons.folder_copy_rounded,
                  color: context.palette.info,
                  size: 16,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Custom Folders (কাস্টম ফোল্ডার)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.15,
              ),
              itemCount: userFolders.length,
              itemBuilder: (context, index) {
                final folder = userFolders[index];
                final liveCount = manager.completedTasks
                    .where((t) => folder.taskIds.contains(t.id))
                    .length;
                return _buildGridFolderTile(
                  title: folder.name,
                  subtitle: '$liveCount Files',
                  icon: Icons.folder_special_rounded,
                  color: context.palette.primary,
                  count: liveCount,
                  isDark: isDark,
                  onTap: () {
                    setState(() {
                      _openedFolderType = 'custom_${folder.id}';
                      _openedFolderName = folder.name;
                      _inFolderFilter = 'All';
                    });
                  },
                  onLongPress: () {
                    _showFolderOptionsSheet(folder);
                  },
                );
              },
            ),
            SizedBox(height: 16),
          ],

          // 3. NOTICE IF ZERO FOLDERS OF ANY KIND EXIST
          if (websiteFolders.isEmpty &&
              userFolders.isEmpty &&
              movieGroups.isEmpty)
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(24),
              margin: EdgeInsets.only(top: 20, bottom: 16),
              decoration: BoxDecoration(
                color: isDark
                    ? context.palette.card
                    : context.palette.textSecondary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.folder_open_outlined,
                    color: context.palette.tint(context.palette.primary, 0.7),
                    size: 48,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'No download folders yet (কোনো ফোল্ডার তৈরি হয়নি)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Downloaded videos and files will automatically be organized into website and channel folders here.',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

          SizedBox(height: 80),
        ],
      ),
    );
  }

  void _openDownloadedTask(BuildContext context, DownloadTask task) {
    final path = task.savePath ?? '';
    if (task.isAudioTask ||
        task.isImageTask ||
        path.isEmpty ||
        !File(path).existsSync()) {
      PlayerService.instance.playDownloadTask(task);
      return;
    }
    final history = WatchHistoryService.instance.getProgress(task.id);
    final parsedSeason =
        EpisodeParser.season(task.seriesSeason ?? '') ??
        EpisodeParser.season(task.title) ??
        EpisodeParser.season(task.savePath ?? '');
    final parsedEpisode =
        EpisodeParser.episode(task.title) ??
        EpisodeParser.episode(task.seriesEpisodeUrl ?? '') ??
        EpisodeParser.episode(task.savePath ?? '');
    final season = parsedSeason ?? history?.seasonNumber ?? 1;
    final episode = parsedEpisode ?? history?.episodeNumber ?? 1;
    final source = MovieSource(
      serverName: 'Downloaded',
      resolution: task.formatLabel.isNotEmpty ? task.formatLabel : 'Original',
      downloadUrl: path,
      streamUrl: path,
      fileSize: '',
      format: task.ext.toLowerCase(),
    );
    final series = task.series;
    final movie = series != null
        ? series.copyWith(
            sources: [source],
            detailUrl: path,
            episodeUrl: task.seriesEpisodeUrl ?? '',
          )
        : MovieItem(
            id: task.id,
            title: task.title,
            posterUrl: task.thumbnailUrl,
            backdropUrl: task.thumbnailUrl,
            year: 0,
            rating: 0,
            quality: task.formatLabel,
            genres: const ['Downloaded'],
            type: 'movie',
            synopsis: '',
            duration: '',
            repoId: '',
            repoName: 'Downloads',
            detailUrl: path,
            sources: [source],
          );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MpvPlayerScreen(
          movie: movie,
          initialSource: source,
          initialSeason: season,
          initialEpisode: episode,
          initialPositionSeconds: history?.positionSeconds ?? 0,
          downloadTaskId: task.id,
          downloadedEpisodes: DownloadManager.instance.downloadedSiblings(task),
          liveSources: [source],
        ),
      ),
    );
  }

  Widget _buildDownloadedPoster(List<DownloadTask> tasks) {
    final task = tasks.first;
    final series = task.series;
    final seriesTitle = _seriesTitle(task);
    final title = seriesTitle ?? task.title;

    void showFiles() {
      DownloadedTitlePage.show(
        context,
        title: title,
        tasks: tasks,
        isSeries: seriesTitle != null,
      );
    }

    final card = Material(
      color: context.palette.card,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      elevation: 1,
      shadowColor: context.palette.shadowAt(0.18),
      child: InkWell(
        onTap: seriesTitle == null
            ? () => _openDownloadedTask(context, task)
            : showFiles,
        onLongPress: () => _confirmDeleteMovieGroup(tasks, title),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SmartNetworkImage(
                    url: task.thumbnailUrl,
                    fallbackUrl: series?.posterUrl,
                    placeholderIcon: Icons.movie_rounded,
                    placeholderColor: context.palette.surface,
                  ),
                  // Small type badge only — no floating icon on the artwork.
                  Positioned(
                    right: 5,
                    top: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: context.palette.scrimAt(0.78),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        seriesTitle == null ? 'MOVIE' : 'SERIES',
                        style: TextStyle(
                          color: context.palette.onScrim,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                  if (tasks.length > 1)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: context.palette.scrimAt(0.78),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${tasks.length} episodes',
                          style: TextStyle(
                            color: context.palette.onScrim,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(8, 7, 8, 8),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return seriesTitle == null
        ? card
        : Tooltip(message: 'Episodes', child: card);
  }

  Future<void> _confirmDeleteMovieGroup(
    List<DownloadTask> tasks,
    String title,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete downloaded title?'),
        content: Text('Delete all downloaded files for "$title"?'),
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
            child: const Text('Delete downloads'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DownloadManager.instance.deleteTasks(tasks);
  }

  // Website Channels View: Shows channels inside the opened website
  Widget _buildWebsiteChannelsView(DownloadManager manager, bool isDark) {
    final website = _openedWebsite!;
    final websiteMap = _websiteFolders(manager);
    final channels = websiteMap[website] ?? <String, List<DownloadTask>>{};
    final isSeries = channels.values.any(
      (tasks) => tasks.any((task) => task.series != null),
    );
    final folderLabel = isSeries ? 'seasons' : 'channels';
    final totalFiles = channels.values.fold<int>(0, (s, l) => s + l.length);

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Breadcrumb Navigation
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark
                  ? context.palette.card
                  : context.palette.textSecondary,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back_rounded, size: 20),
                  onPressed: () {
                    setState(() {
                      _openedWebsite = null;
                      _openedChannel = null;
                    });
                  },
                ),
                Icon(
                  _iconForWebsite(website),
                  color: _colorForWebsite(website),
                  size: 20,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Downloads > $website',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${channels.length} $folderLabel • $totalFiles files',
                        style: TextStyle(
                          fontSize: 11,
                          color: context.palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.folder_open_rounded,
                    color: context.palette.primary,
                    size: 20,
                  ),
                  tooltip: 'Open in System File Manager',
                  onPressed: () {
                    PlayerService.instance.launchSystemPlayer(
                      '${manager.downloadDirectory}/$website',
                    );
                  },
                ),
                IconButton(
                  icon: Icon(
                    Icons.edit_location_alt_rounded,
                    color: context.palette.primary,
                    size: 20,
                  ),
                  tooltip: 'Change download folder',
                  onPressed: () => _pickFolder(context),
                ),
              ],
            ),
          ),
          SizedBox(height: 12),

          Row(
            children: [
              Icon(
                Icons.folder_shared_rounded,
                color: context.palette.primary,
                size: 18,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  isSeries ? 'Seasons' : '$website Channels (চ্যানেল ফোল্ডার)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),

          if (channels.isEmpty)
            _buildEmptyState(
              icon: Icons.folder_open_rounded,
              title: 'No files for $website',
              subtitle: 'Downloaded files from $website will be grouped here.',
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.15,
              ),
              itemCount: channels.keys.length,
              itemBuilder: (context, index) {
                final channelName = channels.keys.elementAt(index);
                final taskList = channels[channelName]!;
                final displayTitle = channelName == 'Unknown'
                    ? 'Unknown (Direct)'
                    : channelName;
                final icon = isSeries || channelName == 'Unknown'
                    ? Icons.folder_rounded
                    : Icons.account_circle_rounded;
                return _buildGridFolderTile(
                  title: displayTitle,
                  subtitle: '${taskList.length} Files',
                  icon: icon,
                  color: context.palette.info,
                  count: taskList.length,
                  isDark: isDark,
                  onTap: () {
                    setState(() {
                      _openedChannel = channelName;
                      _inFolderFilter = 'All';
                    });
                  },
                  onLongPress: () {
                    PlayerService.instance.launchSystemPlayer(
                      '${manager.downloadDirectory}/$website/$channelName',
                    );
                  },
                );
              },
            ),

          SizedBox(height: 80),
        ],
      ),
    );
  }

  // Channel Content Detail View: Shows files inside the channel
  Widget _buildChannelContentDetailView(DownloadManager manager, bool isDark) {
    final website = _openedWebsite!;
    final channel = _openedChannel!;
    final websiteMap = _websiteFolders(manager);
    final channels = websiteMap[website] ?? <String, List<DownloadTask>>{};
    final allInChannel = channels[channel] ?? <DownloadTask>[];
    List<DownloadTask> tasks = List<DownloadTask>.from(allInChannel);

    // Apply In-Folder Filters
    if (_inFolderFilter == 'Videos') {
      tasks = tasks.where((t) => t.isVideoTask).toList();
    } else if (_inFolderFilter == 'Music') {
      tasks = tasks.where((t) => t.isAudioTask).toList();
    } else if (_inFolderFilter == 'Images') {
      tasks = tasks.where((t) => t.isImageTask).toList();
    } else if (_inFolderFilter == 'Movies') {
      tasks = tasks.where((t) => t.category == 'movie').toList();
    }
    // First episode on top, last episode at the bottom.
    tasks.sort((a, b) => _episodeNumber(a).compareTo(_episodeNumber(b)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Breadcrumb Navigation
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark
                  ? context.palette.card
                  : context.palette.textSecondary,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back_rounded, size: 20),
                  onPressed: () {
                    setState(() {
                      final websiteChannels =
                          _websiteFolders(manager)[website] ?? {};
                      if (websiteChannels.keys.length <= 1 &&
                          websiteChannels.containsKey('Unknown')) {
                        _openedWebsite = null;
                        _openedChannel = null;
                      } else {
                        _openedChannel = null;
                      }
                    });
                  },
                ),
                Icon(
                  _iconForWebsite(website),
                  color: _colorForWebsite(website),
                  size: 18,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        channel == 'Unknown'
                            ? 'Downloads > $website'
                            : 'Downloads > $website > $channel',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        channel == 'Unknown'
                            ? '${allInChannel.length} files in this site'
                            : allInChannel.any((task) => task.series != null)
                            ? '${allInChannel.length} episodes'
                            : '${allInChannel.length} items in this channel',
                        style: TextStyle(
                          fontSize: 11,
                          color: context.palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.folder_open_rounded,
                    color: context.palette.primary,
                    size: 20,
                  ),
                  tooltip: 'Open in System File Manager',
                  onPressed: () {
                    PlayerService.instance.launchSystemPlayer(
                      '${manager.downloadDirectory}/$website/$channel',
                    );
                  },
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: 8),

        // In-Folder Filter Bar
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildInFolderFilterChip('All', allInChannel.length, isDark),
                _buildInFolderFilterChip(
                  'Videos',
                  allInChannel.where((t) => t.isVideoTask).length,
                  isDark,
                  icon: Icons.videocam_rounded,
                ),
                _buildInFolderFilterChip(
                  'Music',
                  allInChannel.where((t) => t.isAudioTask).length,
                  isDark,
                  icon: Icons.headphones_rounded,
                ),
                _buildInFolderFilterChip(
                  'Images',
                  allInChannel.where((t) => t.isImageTask).length,
                  isDark,
                  icon: Icons.image_rounded,
                ),
                _buildInFolderFilterChip(
                  'Movies',
                  allInChannel.where((t) => t.category == 'movie').length,
                  isDark,
                  icon: Icons.movie_filter_rounded,
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: 8),

        Expanded(
          child: tasks.isEmpty
              ? _buildEmptyState(
                  icon: Icons.folder_open_rounded,
                  title: 'No $_inFolderFilter files',
                  subtitle:
                      'No downloaded files match the selected filter in $channel.',
                )
              : ListView.builder(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  itemCount: tasks.length + 1,
                  itemBuilder: (context, index) {
                    if (index == tasks.length) {
                      return SizedBox(height: 80);
                    }
                    return DownloadItemTile(task: tasks[index]);
                  },
                ),
        ),
      ],
    );
  }

  IconData _iconForWebsite(String website) {
    final lower = website.toLowerCase();
    if (lower.contains('youtube')) return Icons.smart_display_rounded;
    if (lower.contains('facebook')) return Icons.facebook_rounded;
    if (lower.contains('instagram')) return Icons.camera_alt_rounded;
    if (lower.contains('tiktok')) return Icons.music_note_rounded;
    if (lower.contains('pornhub') ||
        lower.contains('xvideo') ||
        lower.contains('xnxx')) {
      return Icons.videocam_rounded;
    }
    if (lower.contains('twitter') || lower.contains('x'))
      return Icons.tag_rounded;
    if (lower.contains('vimeo')) return Icons.video_collection_rounded;
    return Icons.folder_special_rounded;
  }

  Color _colorForWebsite(String website) {
    final lower = website.toLowerCase();
    if (lower.contains('youtube')) return context.palette.primary;
    if (lower.contains('facebook')) return context.palette.primary;
    if (lower.contains('instagram')) return context.palette.primary;
    if (lower.contains('tiktok')) return context.palette.secondary;
    if (lower.contains('pornhub')) return context.palette.primary;
    if (lower.contains('soundcloud')) return context.palette.primary;
    return context.palette.primary;
  }

  void _showFolderOptionsSheet(VirtualFolder folder) {
    final renameCtrl = TextEditingController(text: folder.name);
    showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Folder Options: ${folder.name}',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            SizedBox(height: 16),
            ListTile(
              leading: Icon(Icons.edit_rounded, color: context.palette.primary),
              title: Text('Rename Folder'),
              onTap: () {
                Navigator.pop(ctx);
                showDialog(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: Text('Rename Folder'),
                    content: TextField(controller: renameCtrl, autofocus: true),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dCtx),
                        child: Text('Cancel'),
                      ),
                      ElevatedButton(
                        onPressed: () async {
                          if (renameCtrl.text.trim().isNotEmpty) {
                            final nav = Navigator.of(dCtx);
                            await VirtualFolderService.instance.renameFolder(
                              folder.id,
                              renameCtrl.text.trim(),
                            );
                            if (dCtx.mounted) nav.pop();
                          }
                        },
                        child: Text('Save'),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_forever_rounded,
                color: context.palette.error,
              ),
              title: Text(
                'Delete Folder',
                style: TextStyle(color: context.palette.error),
              ),
              onTap: () async {
                final nav = Navigator.of(ctx);
                await VirtualFolderService.instance.deleteFolder(folder.id);
                if (ctx.mounted) nav.pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  // Inside Folder View with In-Folder Filter Bar
  Widget _buildFolderContentDetailView(
    DownloadManager manager,
    VirtualFolderService folderService,
    bool isDark,
  ) {
    List<DownloadTask> tasksInFolder = [];

    if (_openedFolderType != null && _openedFolderType!.startsWith('custom_')) {
      final folderId = _openedFolderType!.replaceFirst('custom_', '');
      tasksInFolder = manager.completedTasks.where((t) {
        return folderService.isTaskInFolder(folderId, t.id);
      }).toList();
    }

    // Apply In-Folder Filters
    if (_inFolderFilter == 'Videos') {
      tasksInFolder = tasksInFolder.where((t) => t.isVideoTask).toList();
    } else if (_inFolderFilter == 'Music') {
      tasksInFolder = tasksInFolder.where((t) => t.isAudioTask).toList();
    } else if (_inFolderFilter == 'Images') {
      tasksInFolder = tasksInFolder.where((t) => t.isImageTask).toList();
    } else if (_inFolderFilter == 'Movies') {
      tasksInFolder = tasksInFolder
          .where((t) => t.category == 'movie')
          .toList();
    }
    tasksInFolder.sort(
      (a, b) => _episodeNumber(a).compareTo(_episodeNumber(b)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top Folder Navigation Breadcrumb
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark
                  ? context.palette.card
                  : context.palette.textSecondary,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back_rounded, size: 20),
                  onPressed: () {
                    setState(() {
                      _openedFolderType = null;
                      _openedFolderName = null;
                    });
                  },
                ),
                Icon(
                  Icons.folder_open_rounded,
                  color: context.palette.primary,
                  size: 20,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _openedFolderName ?? 'Folder View',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${tasksInFolder.length} files in this folder',
                        style: TextStyle(
                          fontSize: 11,
                          color: context.palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: 8),

        // In-Folder Filter Bar
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildInFolderFilterChip('All', tasksInFolder.length, isDark),
                _buildInFolderFilterChip(
                  'Videos',
                  tasksInFolder.where((t) => t.isVideoTask).length,
                  isDark,
                  icon: Icons.videocam_rounded,
                ),
                _buildInFolderFilterChip(
                  'Music',
                  tasksInFolder.where((t) => t.isAudioTask).length,
                  isDark,
                  icon: Icons.headphones_rounded,
                ),
                _buildInFolderFilterChip(
                  'Images',
                  tasksInFolder.where((t) => t.isImageTask).length,
                  isDark,
                  icon: Icons.image_rounded,
                ),
                _buildInFolderFilterChip(
                  'Movies',
                  tasksInFolder.where((t) => t.category == 'movie').length,
                  isDark,
                  icon: Icons.movie_filter_rounded,
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: 8),

        Expanded(
          child: tasksInFolder.isEmpty
              ? _buildEmptyState(
                  icon: Icons.folder_open_rounded,
                  title: 'This folder is empty',
                  subtitle: 'Downloaded files assigned to this folder will automatically appear here.',
                )
              : ListView.builder(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  itemCount: tasksInFolder.length + 1,
                  itemBuilder: (context, index) {
                    if (index == tasksInFolder.length) {
                      return SizedBox(height: 80);
                    }
                    return DownloadItemTile(task: tasksInFolder[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildInFolderFilterChip(
    String label,
    int count,
    bool isDark, {
    IconData? icon,
  }) {
    final isSelected = _inFolderFilter == label;

    return Padding(
      padding: EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: icon != null
            ? Icon(
                icon,
                size: 14,
                color: isSelected
                    ? context.palette.onPrimary
                    : context.palette.primary,
              )
            : null,
        label: Text('$label ($count)'),
        selected: isSelected,
        selectedColor: context.palette.primary,
        labelStyle: TextStyle(
          color: isSelected
              ? context.palette.onPrimary
              : (isDark
                    ? context.palette.textSecondary
                    : context.palette.textPrimary),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 12,
        ),
        backgroundColor: context.palette.card,
        side: BorderSide(
          color: isSelected ? context.palette.primary : context.palette.border,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (val) {
          if (val) {
            setState(() {
              _inFolderFilter = label;
            });
          }
        },
      ),
    );
  }

  Widget _buildGridFolderTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required int count,
    required bool isDark,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.palette.border),
        boxShadow: [
          BoxShadow(
            color: context.palette.shadowAt(isDark ? 0.25 : 0.05),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: color, size: 24),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.palette.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: context.palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActiveDownloadsHeader(
    List<DownloadTask> activeList,
    bool isDark,
  ) {
    if (activeList.isEmpty) return const SizedBox.shrink();

    double totalSpeedBytes = 0;
    for (final t in activeList) {
      if (t.status == DownloadStatus.downloading) {
        totalSpeedBytes += t.speedBytesPerSec;
      }
    }
    final speedKb = totalSpeedBytes / 1024;
    String totalSpeedText;
    if (speedKb >= 1024) {
      totalSpeedText = '${(speedKb / 1024).toStringAsFixed(1)} MB/s';
    } else {
      totalSpeedText = '${speedKb.toStringAsFixed(0)} KB/s';
    }

    final isAnyDownloading = activeList.any(
      (t) => t.status == DownloadStatus.downloading,
    );
    final accent = context.palette.primary;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0x1AFFFFFF) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0x22FFFFFF) : Colors.black12,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.speed_rounded, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${activeList.length} Active Download${activeList.length == 1 ? '' : 's'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isDark ? Colors.white : Colors.black87,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: isAnyDownloading
                            ? Colors.greenAccent
                            : Colors.amberAccent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                (isAnyDownloading
                                        ? Colors.greenAccent
                                        : Colors.amberAccent)
                                    .withValues(alpha: 0.6),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Combined speed · $totalSpeedText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.palette.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                if (isAnyDownloading) {
                  for (final t in activeList) {
                    DownloadManager.instance.pauseTask(t);
                  }
                } else {
                  for (final t in activeList) {
                    DownloadManager.instance.resumeTask(t);
                  }
                }
              },
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isAnyDownloading
                      ? accent
                      : accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: accent.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isAnyDownloading
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 15,
                      color: isAnyDownloading ? Colors.white : accent,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isAnyDownloading ? 'Pause All' : 'Resume All',
                      style: TextStyle(
                        color: isAnyDownloading ? Colors.white : accent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 72,
              color: context.palette.tint(context.palette.primary, 0.5),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
