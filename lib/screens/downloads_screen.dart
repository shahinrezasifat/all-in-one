import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../services/download_manager.dart';
import '../services/player_service.dart';
import '../services/virtual_folder_service.dart';
import '../theme/app_colors.dart';
import '../widgets/download_item_tile.dart';
import '../widgets/movie_card.dart';
import '../widgets/remote_image.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
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
  static final _numberedSeason = RegExp(
    r'^Season\s+(\d+)$',
    caseSensitive: false,
  );

  String? _seriesTitle(DownloadTask task) =>
      task.series?.title ?? _episodeTitle.firstMatch(task.title)?.group(1);

  String _downloadedSeason(DownloadTask task) {
    final episode = _episodeTitle.firstMatch(task.title);
    final seasonNumber = episode?.group(2) ?? episode?.group(3);
    final path = (task.savePath ?? '').split(RegExp(r'[/\\]'));
    final label =
        task.seriesSeason ??
        (seasonNumber != null
            ? 'Season $seasonNumber'
            : task.seriesEpisodeUrl != null && path.length >= 3
            ? path[path.length - 2]
            : 'Season unspecified');
    final number = int.tryParse(
      _numberedSeason.firstMatch(label)?.group(1) ?? '',
    );
    return number == null ? label : 'Season $number';
  }

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
        title: const Row(
          children: [
            Icon(Icons.create_new_folder_rounded, color: AppColors.primary),
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
            const Text(
              'Enter folder name to create a real directory on disk:',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
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
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
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
            child: const Text(
              'Create Folder',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
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
                  padding: const EdgeInsets.only(bottom: 76.0),
                  child: FloatingActionButton(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 5,
                    tooltip: 'New Folder',
                    onPressed: _showCreateFolderDialog,
                    child: const Icon(
                      Icons.create_new_folder_rounded,
                      size: 28,
                    ),
                  ),
                )
              : null,
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Downloads',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),

                // Modern Floating Segmented Switcher (Downloading vs Downloaded)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkCard : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      children: [
                        // Tab 0: Downloading
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _activeTabIndex = 0;
                              });
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _activeTabIndex == 0
                                    ? AppColors.primary
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(26),
                                boxShadow: _activeTabIndex == 0
                                    ? [
                                        BoxShadow(
                                          color: AppColors.primary.withValues(
                                            alpha: 0.35,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ]
                                    : [],
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.download_rounded,
                                    size: 18,
                                    color: _activeTabIndex == 0
                                        ? Colors.white
                                        : (isDark
                                              ? Colors.white70
                                              : Colors.black87),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Downloading',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: _activeTabIndex == 0
                                          ? Colors.white
                                          : (isDark
                                                ? Colors.white70
                                                : Colors.black87),
                                    ),
                                  ),
                                  if (activeList.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _activeTabIndex == 0
                                            ? Colors.white
                                            : AppColors.primary,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '${activeList.length}',
                                        style: TextStyle(
                                          color: _activeTabIndex == 0
                                              ? AppColors.primary
                                              : Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Tab 1: Downloaded Folders
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _activeTabIndex = 1;
                              });
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _activeTabIndex == 1
                                    ? AppColors.primary
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(26),
                                boxShadow: _activeTabIndex == 1
                                    ? [
                                        BoxShadow(
                                          color: AppColors.primary.withValues(
                                            alpha: 0.35,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ]
                                    : [],
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.cloud_done_rounded,
                                    size: 18,
                                    color: _activeTabIndex == 1
                                        ? Colors.white
                                        : (isDark
                                              ? Colors.white70
                                              : Colors.black87),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Downloaded',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: _activeTabIndex == 1
                                          ? Colors.white
                                          : (isDark
                                                ? Colors.white70
                                                : Colors.black87),
                                    ),
                                  ),
                                  if (completedList.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _activeTabIndex == 1
                                            ? Colors.white
                                            : (isDark
                                                  ? AppColors.darkSurface
                                                  : Colors.grey.shade300),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '${completedList.length}',
                                        style: TextStyle(
                                          color: _activeTabIndex == 1
                                              ? AppColors.primary
                                              : (isDark
                                                    ? Colors.white70
                                                    : Colors.black87),
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
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
                  ),
                ),

                const SizedBox(height: 12),

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
                                      padding: const EdgeInsets.symmetric(
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
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 110),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (movieGroups.isNotEmpty) ...[
            Text(
              'Movies & Series',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            GridView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: MovieCard.catalogGrid,
              itemCount: movieGroups.length,
              itemBuilder: (context, index) =>
                  _buildDownloadedPoster(movieGroups[index]),
            ),
            const SizedBox(height: 20),
          ],
          // 1. AUTO-ORGANIZED WEBSITE FOLDERS (YouTube, Facebook, etc.)
          if (websiteFolders.isNotEmpty) ...[
            Row(
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  color: AppColors.primary,
                  size: 16,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Auto Organized Folders (ওয়েবসাইট ও চ্যানেল ফোল্ডার)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${websiteFolders.length} sites',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(
                    Icons.folder_open_rounded,
                    color: AppColors.primary,
                    size: 18,
                  ),
                  tooltip: 'Open Directory in System Explorer',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    PlayerService.instance.launchSystemPlayer(
                      manager.downloadDirectory,
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
            const SizedBox(height: 16),
          ],

          // 2. USER-CREATED CUSTOM FOLDERS
          if (userFolders.isNotEmpty) ...[
            const Row(
              children: [
                Icon(
                  Icons.folder_copy_rounded,
                  color: AppColors.accentBlue,
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
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                  color: AppColors.primary,
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
            const SizedBox(height: 16),
          ],

          // 3. NOTICE IF ZERO FOLDERS OF ANY KIND EXIST
          if (websiteFolders.isEmpty &&
              userFolders.isEmpty &&
              movieGroups.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              margin: const EdgeInsets.only(top: 20, bottom: 16),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkCard : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.folder_open_outlined,
                    color: AppColors.primary.withValues(alpha: 0.7),
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'No download folders yet (কোনো ফোল্ডার তৈরি হয়নি)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Downloaded videos and files will automatically be organized into website and channel folders here.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildDownloadedPoster(List<DownloadTask> tasks) {
    final task = tasks.first;
    final series = task.series;
    final seriesTitle = _seriesTitle(task);
    final title = seriesTitle ?? task.title;
    final manager = DownloadManager.instance;

    void showFiles() {
      String? selectedSeason;
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => FractionallySizedBox(
          heightFactor: .65,
          child: StatefulBuilder(
            builder: (context, updateSheet) => ListenableBuilder(
              listenable: manager,
              builder: (context, _) {
                final completed = manager.completedTasks.toSet();
                final files = tasks.where(completed.contains).toList();
                final seasons = <String, List<DownloadTask>>{};
                if (seriesTitle != null) {
                  for (final file in files) {
                    seasons
                        .putIfAbsent(_downloadedSeason(file), () => [])
                        .add(file);
                  }
                }
                final labels = seasons.keys.toList()
                  ..sort((a, b) {
                    final first = int.tryParse(
                      _numberedSeason.firstMatch(a)?.group(1) ?? '',
                    );
                    final second = int.tryParse(
                      _numberedSeason.firstMatch(b)?.group(1) ?? '',
                    );
                    if (first != null && second != null)
                      return first.compareTo(second);
                    if (first != null) return -1;
                    if (second != null) return 1;
                    return a.compareTo(b);
                  });
                final activeSeason = seasons.containsKey(selectedSeason)
                    ? selectedSeason
                    : labels.firstOrNull;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    if (labels.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Downloaded seasons',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final label in labels)
                            ChoiceChip(
                              label: Text(label),
                              selected: label == activeSeason,
                              onSelected: (_) => updateSheet(() {
                                selectedSeason = label;
                              }),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (files.isEmpty) const Text('No downloaded files'),
                    if (seriesTitle == null)
                      for (final file in files)
                        DownloadItemTile(key: ValueKey(file.id), task: file),
                    if (activeSeason != null) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '$activeSeason · ${seasons[activeSeason]!.length} downloaded',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      for (final file in seasons[activeSeason]!)
                        DownloadItemTile(key: ValueKey(file.id), task: file),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      );
    }

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: seriesTitle == null
            ? () => PlayerService.instance.playDownloadTask(task)
            : showFiles,
        onLongPress: showFiles,
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
                    placeholderColor: AppColors.darkSurface,
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton.filledTonal(
                      tooltip: seriesTitle == null
                          ? 'Download options'
                          : 'Episodes',
                      onPressed: showFiles,
                      icon: Icon(
                        seriesTitle == null
                            ? Icons.more_vert_rounded
                            : Icons.video_library_rounded,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Breadcrumb Navigation
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
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
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Downloads > $website',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${channels.length} $folderLabel • $totalFiles files',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.folder_open_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                  tooltip: 'Open in System File Manager',
                  onPressed: () {
                    PlayerService.instance.launchSystemPlayer(
                      '${manager.downloadDirectory}/$website',
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              const Icon(
                Icons.folder_shared_rounded,
                color: AppColors.primary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isSeries ? 'Seasons' : '$website Channels (চ্যানেল ফোল্ডার)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          if (channels.isEmpty)
            _buildEmptyState(
              icon: Icons.folder_open_rounded,
              title: 'No files for $website',
              subtitle: 'Downloaded files from $website will be grouped here.',
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                  color: AppColors.accentBlue,
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

          const SizedBox(height: 80),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Breadcrumb Navigation
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
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
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        channel == 'Unknown'
                            ? 'Downloads > $website'
                            : 'Downloads > $website > $channel',
                        style: const TextStyle(
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
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.folder_open_rounded,
                    color: AppColors.primary,
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

        const SizedBox(height: 8),

        // In-Folder Filter Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
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

        const SizedBox(height: 8),

        Expanded(
          child: tasks.isEmpty
              ? _buildEmptyState(
                  icon: Icons.folder_open_rounded,
                  title: 'No $_inFolderFilter files',
                  subtitle:
                      'No downloaded files match the selected filter in $channel.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: tasks.length + 1,
                  itemBuilder: (context, index) {
                    if (index == tasks.length) {
                      return const SizedBox(height: 80);
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
    if (lower.contains('youtube')) return const Color(0xFFFF0000);
    if (lower.contains('facebook')) return const Color(0xFF1877F2);
    if (lower.contains('instagram')) return const Color(0xFFE4405F);
    if (lower.contains('tiktok')) return const Color(0xFF00F2FE);
    if (lower.contains('pornhub')) return const Color(0xFFFFA31A);
    if (lower.contains('soundcloud')) return const Color(0xFFFF5500);
    return AppColors.primary;
  }

  void _showFolderOptionsSheet(VirtualFolder folder) {
    final renameCtrl = TextEditingController(text: folder.name);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Folder Options: ${folder.name}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.edit_rounded, color: AppColors.primary),
              title: const Text('Rename Folder'),
              onTap: () {
                Navigator.pop(ctx);
                showDialog(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: const Text('Rename Folder'),
                    content: TextField(controller: renameCtrl, autofocus: true),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dCtx),
                        child: const Text('Cancel'),
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
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_forever_rounded,
                color: Colors.red,
              ),
              title: const Text(
                'Delete Folder',
                style: TextStyle(color: Colors.red),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top Folder Navigation Breadcrumb
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
                  onPressed: () {
                    setState(() {
                      _openedFolderType = null;
                      _openedFolderName = null;
                    });
                  },
                ),
                const Icon(
                  Icons.folder_open_rounded,
                  color: AppColors.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _openedFolderName ?? 'Folder View',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${tasksInFolder.length} files in this folder',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 8),

        // In-Folder Filter Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
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

        const SizedBox(height: 8),

        Expanded(
          child: tasksInFolder.isEmpty
              ? _buildEmptyState(
                  icon: Icons.folder_open_rounded,
                  title: 'This folder is empty',
                  subtitle: 'Downloaded files assigned to this folder will automatically appear here.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: tasksInFolder.length + 1,
                  itemBuilder: (context, index) {
                    if (index == tasksInFolder.length) {
                      return const SizedBox(height: 80);
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
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: icon != null
            ? Icon(
                icon,
                size: 14,
                color: isSelected ? Colors.white : AppColors.primary,
              )
            : null,
        label: Text('$label ($count)'),
        selected: isSelected,
        selectedColor: AppColors.primary,
        labelStyle: TextStyle(
          color: isSelected
              ? Colors.white
              : (isDark ? Colors.white70 : Colors.black87),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 12,
        ),
        backgroundColor: isDark ? AppColors.darkCard : Colors.grey.shade200,
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
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
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
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: color, size: 24),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
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
                const Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
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
    final preparingCount = activeList.where((task) => task.isPreparing).length;
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

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.speed_rounded,
              color: AppColors.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '${activeList.length} Active Download${activeList.length > 1 ? "s" : ""}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: isAnyDownloading
                            ? AppColors.accentGreen
                            : AppColors.accentGold,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  totalSpeedBytes <= 0 && preparingCount > 0
                      ? '$preparingCount preparing to start'
                      : 'Combined speed · $totalSpeedText',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                final mgr = DownloadManager.instance;
                if (isAnyDownloading) {
                  for (final t in activeList) {
                    if (t.status == DownloadStatus.downloading ||
                        t.status == DownloadStatus.queued) {
                      mgr.pauseTask(t);
                    }
                  }
                } else {
                  for (final t in activeList) {
                    if (t.status == DownloadStatus.paused ||
                        t.status == DownloadStatus.failed) {
                      mgr.resumeTask(t);
                    }
                  }
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isAnyDownloading
                      ? AppColors.accentGold.withValues(alpha: 0.14)
                      : AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isAnyDownloading
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 15,
                      color: isAnyDownloading
                          ? AppColors.accentGold
                          : AppColors.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isAnyDownloading ? 'Pause All' : 'Resume All',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: isAnyDownloading
                            ? AppColors.accentGold
                            : AppColors.primary,
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
              color: AppColors.primary.withValues(alpha: 0.5),
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
              style: const TextStyle(
                color: Colors.grey,
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
