import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../services/download_manager.dart';
import '../services/player_service.dart';
import '../services/virtual_folder_service.dart';
import '../theme/app_palette.dart';
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
        title: Row(
          children: [
            Icon(Icons.create_new_folder_rounded, color: context.palette.primary),
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
                    child: Icon(
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
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 12),
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
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: context.palette.selectedBg,
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
                              duration: Duration(milliseconds: 200),
                              padding: EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _activeTabIndex == 0
                                    ? context.palette.primary
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(26),
                                boxShadow: _activeTabIndex == 0
                                    ? [
                                        BoxShadow(
                                          color: context.palette.tint(context.palette.primary, 0.35,),
                                          blurRadius: 10,
                                          offset: Offset(0, 3),
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
                                        ? context.palette.onPrimary
                                        : context.palette.textPrimary,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'Downloading',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: _activeTabIndex == 0
                                          ? context.palette.onPrimary
                                        : context.palette.textPrimary,
                                    ),
                                  ),
                                  if (activeList.isNotEmpty) ...[
                                    SizedBox(width: 6),
                                    Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _activeTabIndex == 0
                                            ? context.palette.onPrimary
                                            : context.palette.trackBg,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '${activeList.length}',
                                        style: TextStyle(
                                          color: _activeTabIndex == 0
                                              ? context.palette.primary
                                              : context.palette.textPrimary,
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
                              duration: Duration(milliseconds: 200),
                              padding: EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _activeTabIndex == 1
                                    ? context.palette.primary
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(26),
                                boxShadow: _activeTabIndex == 1
                                    ? [
                                        BoxShadow(
                                          color: context.palette.tint(context.palette.primary, 0.35,),
                                          blurRadius: 10,
                                          offset: Offset(0, 3),
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
                                        ? context.palette.onPrimary
                                        : context.palette.textPrimary,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'Downloaded',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: _activeTabIndex == 1
                                          ? context.palette.onPrimary
                                        : context.palette.textPrimary,
                                    ),
                                  ),
                                  if (completedList.isNotEmpty) ...[
                                    SizedBox(width: 6),
                                    Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _activeTabIndex == 1
                                            ? context.palette.onPrimary
                                            : context.palette.trackBg,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '${completedList.length}',
                                        style: TextStyle(
                                          color: _activeTabIndex == 1
                                              ? context.palette.primary
                                              : (isDark
                                                    ? context.palette.textSecondary
                                                    : context.palette.textPrimary),
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
            Text(
              'Movies & Series',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 10),
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
                    'Auto Organized Folders (ওয়েবসাইট ও চ্যানেল ফোল্ডার)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
                SizedBox(width: 6),
                Text(
                  '${websiteFolders.length} sites',
                  style: TextStyle(fontSize: 11, color: context.palette.onPrimary),
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
                color: isDark ? context.palette.card : context.palette.textSecondary,
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
                    style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
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
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    if (labels.isNotEmpty) ...[
                      SizedBox(height: 8),
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
                    SizedBox(height: 12),
                    if (files.isEmpty) Text('No downloaded files'),
                    if (seriesTitle == null)
                      for (final file in files)
                        DownloadItemTile(key: ValueKey(file.id), task: file),
                    if (activeSeason != null) ...[
                      Padding(
                        padding: EdgeInsets.only(bottom: 8),
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
                    placeholderColor: context.palette.surface,
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
              color: isDark ? context.palette.card : context.palette.textSecondary,
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
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Breadcrumb Navigation
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? context.palette.card : context.palette.textSecondary,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top Folder Navigation Breadcrumb
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? context.palette.card : context.palette.textSecondary,
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
                color: isSelected ? context.palette.onPrimary : context.palette.primary,
              )
            : null,
        label: Text('$label ($count)'),
        selected: isSelected,
        selectedColor: context.palette.primary,
        labelStyle: TextStyle(
          color: isSelected
              ? context.palette.onPrimary
              : (isDark ? context.palette.textSecondary : context.palette.textPrimary),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 12,
        ),
        backgroundColor: context.palette.card,
        side: BorderSide(color: isSelected ? context.palette.primary : context.palette.border),
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
                      padding: EdgeInsets.symmetric(
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
                  style: TextStyle(fontSize: 11, color: context.palette.textSecondary),
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
    if (activeList.isEmpty) return SizedBox.shrink();

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
      margin: EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? context.palette.border : context.palette.card,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? context.palette.shadowAt(0.25)
                : context.palette.textSecondary.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: context.palette.tint(context.palette.primary, 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.speed_rounded,
              color: context.palette.primary,
              size: 20,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '${activeList.length} Active Download${activeList.length > 1 ? "s" : ""}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    SizedBox(width: 6),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: isAnyDownloading
                            ? context.palette.success
                            : context.palette.info,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (isAnyDownloading
                                    ? context.palette.success
                                    : context.palette.info)
                                .withValues(alpha: 0.8),
                            blurRadius: 3,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 1),
                Text(
                  totalSpeedBytes <= 0 && preparingCount > 0
                      ? '$preparingCount preparing to start'
                      : 'Combined speed · $totalSpeedText',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
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
                height: 32,
                padding: EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: isAnyDownloading
                      ? (isDark
                          ? context.palette.secondary
                          : context.palette.card)
                      : (isDark
                          ? context.palette.tint(context.palette.success, 0.10)
                          : context.palette.tint(context.palette.success, 0.08)),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isAnyDownloading
                        ? (isDark
                            ? context.palette.secondary
                            : context.palette.tint(context.palette.info, 0.18))
                        : (context.palette.success),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isAnyDownloading
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 14,
                      color: isAnyDownloading
                          ? (isDark
                              ? context.palette.onSecondary
                              : context.palette.info)
                          : context.palette.success,
                    ),
                    SizedBox(width: 4),
                    Text(
                      isAnyDownloading ? 'Pause All' : 'Resume All',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: isAnyDownloading
                            ? (isDark
                                ? context.palette.onSecondary
                                : context.palette.info)
                            : context.palette.success,
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
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 72,
              color: context.palette.tint(context.palette.primary, 0.5),
            ),
            SizedBox(height: 18),
            Text(
              title,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
            SizedBox(height: 8),
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
