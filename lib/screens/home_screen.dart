import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/site_model.dart';
import '../models/video_item.dart';
import '../services/bookmark_service.dart';
import '../services/download_manager.dart';
import '../services/permission_service.dart';
import '../services/preference_service.dart';
import '../services/search_service.dart';
import '../services/trending_engine_service.dart';
import '../theme/app_colors.dart';
import '../widgets/analyze_download_flow.dart';
import '../widgets/bookmark_editor_sheet.dart';
import '../widgets/remote_image.dart';
import '../widgets/speed_dial_grid.dart';
import '../widgets/video_card.dart';
import 'browser_screen.dart';

class HomeScreen extends StatefulWidget {
  final Function(String)? onSearchQuery;
  final Function(SiteModel)? onOpenBrowser;
  final String? initialQuery;

  const HomeScreen({
    super.key,
    this.onSearchQuery,
    this.onOpenBrowser,
    this.initialQuery,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  bool _isExtracting = false;
  bool _isSearching = false;

  int _searchRequest = 0;
  List<VideoItem> _searchResults = [];
  String _activeSearchQuery = '';

  // LIVE YouTube home feed: page 0 is the real trending chart, later pages pull
  // fresh unique videos as the user scrolls (no more static repeated list).
  final List<VideoItem> _feedVideos = [];
  bool _loadingFeed = true;
  bool _loadingMoreFeed = false;
  bool _hasMoreFeed = true;

  // Multi-Select Batch Download state
  bool _isMultiSelect = false;
  final Set<VideoItem> _selectedVideos = {};

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(_refreshSearchField);
    BookmarkService.instance.init();
    PreferenceService.instance.ready.then((_) {
      if (mounted) setState(() {});
    });

    _loadFeedPage();

    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _executeSearch(widget.initialQuery!);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _searchFocus.removeListener(_refreshSearchField);
    _searchFocus.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Fetch a page of fresh, randomised, NEVER-before-seen videos from the
  /// persistent trending engine (which is also refreshed in the background).
  Future<void> _loadFeedPage({bool forceRefresh = false}) async {
    if (_loadingMoreFeed) return;
    setState(() => _loadingMoreFeed = true);
    final batch = await TrendingEngineService.instance.fetchFreshBatch(
      count: 8,
      forceRefresh: forceRefresh,
    );
    if (!mounted) return;
    setState(() {
      for (final v in batch) {
        if (!_feedVideos.any((e) => e.id == v.id)) _feedVideos.add(v);
      }
      _loadingMoreFeed = false;
      _loadingFeed = false;
      if (batch.isEmpty || !TrendingEngineService.instance.hasMore('All')) {
        _hasMoreFeed = false;
      }
    });
    // PRELOAD the page's thumbnails into the 50 MB disk cache in the
    // background, so scrolling the feed never waits on the network.
    SmartNetworkImage.prefetch(batch.map((v) => v.thumbnailUrl));
  }

  /// Force a brand-new randomised feed (called by the header refresh button).
  void _refreshFeed() {
    if (_isSearching || _loadingMoreFeed) return;
    setState(() {
      _feedVideos.clear();
      _hasMoreFeed = true;
      _loadingFeed = true;
    });
    unawaited(_loadFeedPage(forceRefresh: true));
  }

  void _triggerLoadMoreFeed() {
    if (_loadingMoreFeed || !_hasMoreFeed) return;
    _loadFeedPage();
  }

  /// Record submitted queries for matching while the user types.
  Future<void> _executeSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;

    final request = ++_searchRequest;
    _searchFocus.unfocus();
    // Persist the query in the recent-search history (video surface) AND teach
    // the trending engine which channel/topic the user cares about.
    PreferenceService.instance.logSearch(q, isAudio: false);
    TrendingEngineService.instance.logChannel(q);
    setState(() {
      _isSearching = true;
      _activeSearchQuery = q;
      _searchController.text = q;
    });

    final results = await SearchService.instance.searchVideos(q);

    if (mounted && request == _searchRequest) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
      // Pre-cache every result thumbnail — the list renders instantly even
      // while the user flicks through it.
      SmartNetworkImage.prefetch(results.map((v) => v.thumbnailUrl));
    }
  }

  /// Clear the active search and return to the live feed.
  void _clearSearch() {
    _searchRequest++;
    _searchController.clear();
    setState(() {
      _isSearching = false;
      _activeSearchQuery = '';
      _searchResults = [];
    });
  }

  /// Footer for the live feed's infinite scroll: a spinner while the next page
  /// loads, or an honest end-of-feed note once the seeds are exhausted.
  Widget _buildFeedFooter(bool isDark) {
    if (_loadingFeed || _loadingMoreFeed) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Column(
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppColors.primary,
                ),
              ),
              SizedBox(height: 10),
              Text(
                'Finding fresh videos…',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }
    if (!_hasMoreFeed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'You’re caught up.',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white54 : Colors.black45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: 8);
  }

  Future<void> _handleFastDownload({String? customUrl}) async {
    if (_isExtracting) return;
    final url = (customUrl ?? _searchController.text).trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        !const ['http', 'https'].contains(uri.scheme)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a YouTube or website URL.')),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _isExtracting = true);
    try {
      await analyzeAndPickFormat(context, url: url);
    } finally {
      if (mounted) setState(() => _isExtracting = false);
    }
  }

  Uri? _submittedLink(String input) {
    final text = input.trim();
    final withScheme = text.contains('://') ? text : 'https://$text';
    final uri = Uri.tryParse(withScheme);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        RegExp(r'\s').hasMatch(text)) {
      return null;
    }
    if (!text.contains('://') && !uri.host.contains('.')) return null;
    return uri;
  }

  Future<void> _submitSearchOrLink(String input) async {
    final url = _submittedLink(input);
    if (url != null) {
      await _handleFastDownload(customUrl: url.toString());
    } else {
      await _executeSearch(input);
    }
  }

  void _refreshSearchField() {
    if (mounted) setState(() {});
  }

  Future<void> _pasteSearchLink() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (!mounted) return;
    if (text == null || _submittedLink(text) == null) {
      _searchFocus.requestFocus();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copy a video link to paste it here.')),
      );
      return;
    }
    _searchController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _searchFocus.requestFocus();
    _refreshSearchField();
  }

  Widget _buildSearchPanel() {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final query = _searchController.text.trim().toLowerCase();
    final isLink = _submittedLink(query) != null;
    final matches =
        _searchFocus.hasFocus && query.characters.length >= 2 && !isLink
        ? PreferenceService.instance.recentVideoSearches
              .where((entry) => entry.toLowerCase().contains(query))
              .take(5)
              .toList()
        : const <String>[];
    final accent = dark ? AppColors.primaryLight : AppColors.primary;
    final surface = dark ? AppColors.darkCard : Colors.white;
    final border = dark ? AppColors.darkBorder : AppColors.lightBorder;
    final muted = dark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Single, calm search field — no decorative gradient wrapper.
        Material(
          color: surface,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .22 : .06),
                  blurRadius: 16,
                  spreadRadius: -6,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(Icons.search_rounded, color: accent, size: 22),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      decoration: InputDecoration(
                        hintText: 'Search videos or paste a link',
                        hintStyle: TextStyle(
                          color: dark
                              ? AppColors.darkTextTertiary
                              : AppColors.lightTextTertiary,
                          fontSize: 14,
                        ),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                      onChanged: (_) => _refreshSearchField(),
                      onSubmitted: _submitSearchOrLink,
                      textInputAction: TextInputAction.go,
                    ),
                  ),
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      tooltip: 'Clear search',
                      onPressed: _clearSearch,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: dark ? Colors.white54 : Colors.black45,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  IconButton(
                    tooltip: 'Paste link',
                    onPressed: _isExtracting ? null : _pasteSearchLink,
                    icon: Icon(Icons.link_rounded, size: 19, color: accent),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 2),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _isExtracting || query.isEmpty
                          ? null
                          : () => _submitSearchOrLink(_searchController.text),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          gradient: AppColors.primaryGradient,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: .26),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: _isExtracting
                            ? const Center(
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                              )
                            : const Tooltip(
                                message: 'Search videos',
                                child: Icon(
                                  Icons.arrow_forward_rounded,
                                  color: Colors.white,
                                  size: 21,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (matches.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .20 : .07),
                  blurRadius: 18,
                  spreadRadius: -8,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
                    child: Text(
                      'RECENT SEARCHES',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                        color: dark
                            ? AppColors.darkTextTertiary
                            : AppColors.lightTextTertiary,
                      ),
                    ),
                  ),
                  for (final entry in matches)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.history_rounded,
                        size: 18,
                        color: accent,
                      ),
                      title: Text(
                        entry,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                      trailing: Icon(
                        Icons.north_west_rounded,
                        size: 15,
                        color: muted,
                      ),
                      onTap: () => _executeSearch(entry),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _showBookmarkEditor([SiteModel? site]) async {
    final saved = await BookmarkEditorSheet.show(context, site: site);
    if (saved != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(site == null ? 'Bookmark added' : 'Bookmark updated'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // Batch Download Format Selection Modal Sheet
  void _showBatchFormatSelectionSheet() {
    if (_selectedVideos.isEmpty) return;

    String selectedFormat = '1080p Full HD (MP4)';
    bool isAudioFormat = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;

            final videoFormats = [
              {
                'label': '4K Ultra HD (2160p MP4)',
                'value': '4K Ultra HD (MP4)',
                'isAudio': false,
              },
              {
                'label': '1080p Full HD (1080p MP4)',
                'value': '1080p Full HD (MP4)',
                'isAudio': false,
              },
              {
                'label': '720p HD (720p MP4)',
                'value': '720p HD (MP4)',
                'isAudio': false,
              },
              {
                'label': '480p SD (480p MP4)',
                'value': '480p SD (MP4)',
                'isAudio': false,
              },
            ];

            final audioFormats = [
              {
                'label': '320kbps MP3 Premium Audio',
                'value': '320kbps MP3',
                'isAudio': true,
              },
              {
                'label': '192kbps MP3 High Quality',
                'value': '192kbps MP3',
                'isAudio': true,
              },
              {
                'label': '128kbps MP3 Fast Audio',
                'value': '128kbps MP3',
                'isAudio': true,
              },
            ];

            return Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.download_rounded,
                        color: AppColors.primary,
                        size: 24,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Choose Format for ${_selectedVideos.length} Selected Downloads',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Select format option before downloading. Downloads will start after tapping the button below.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),

                  const Text(
                    'Video Formats',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...videoFormats.map((f) {
                    final val = f['value'] as String;
                    final isSel = selectedFormat == val && !isAudioFormat;
                    return InkWell(
                      onTap: () {
                        setSheetState(() {
                          selectedFormat = val;
                          isAudioFormat = false;
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSel
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              color: isSel ? AppColors.primary : Colors.grey,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              f['label'] as String,
                              style: TextStyle(
                                fontWeight: isSel
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSel ? AppColors.primary : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),

                  const SizedBox(height: 10),
                  const Text(
                    'Audio Formats (MP3)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: AppColors.accentGold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...audioFormats.map((f) {
                    final val = f['value'] as String;
                    final isSel = selectedFormat == val && isAudioFormat;
                    return InkWell(
                      onTap: () {
                        setSheetState(() {
                          selectedFormat = val;
                          isAudioFormat = true;
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSel
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              color: isSel ? AppColors.accentGold : Colors.grey,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              f['label'] as String,
                              style: TextStyle(
                                fontWeight: isSel
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSel ? AppColors.accentGold : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),

                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _executeBatchDownload(selectedFormat, isAudioFormat);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(
                        Icons.download_done_rounded,
                        color: Colors.white,
                      ),
                      label: Text(
                        'Start Batch Download ($selectedFormat)',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _executeBatchDownload(String formatLabel, bool isAudio) async {
    if (_selectedVideos.isEmpty) return;

    final hasPerm = await PermissionService.instance.hasStoragePermission();
    if (!hasPerm) {
      await PermissionService.instance.requestStoragePermission();
    }

    final count = _selectedVideos.length;
    for (final video in _selectedVideos) {
      DownloadManager.instance.startDirectDownload(
        url: video.videoUrl,
        title: video.title,
        author: video.author,
        thumbnailUrl: video.thumbnailUrl,
        isAudio: isAudio,
        quality: formatLabel,
      );
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Started batch download of $count items ($formatLabel)...',
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.primary,
      ),
    );

    setState(() {
      _selectedVideos.clear();
      _isMultiSelect = false;
    });
  }

  Widget _buildQuickAccess(Color accent) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Quick access',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _showBookmarkEditor,
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('Add bookmark'),
                style: FilledButton.styleFrom(
                  foregroundColor: accent,
                  backgroundColor: accent.withValues(alpha: dark ? .17 : .09),
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          AnimatedBuilder(
            animation: BookmarkService.instance,
            builder: (context, _) => SpeedDialGrid(
              sites: BookmarkService.instance.bookmarks,
              onSiteTap: (site) {
                if (widget.onOpenBrowser != null) {
                  widget.onOpenBrowser!(site);
                } else {
                  BrowserScreen.open(context, site);
                }
              },
              onEditBookmark: _showBookmarkEditor,
              onDeleteBookmark: (site) async {
                await BookmarkService.instance.removeBookmark(site);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Removed ${site.title}')),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Divider(
            height: 1,
            color: dark ? AppColors.darkBorder : AppColors.lightBorder,
          ),
        ],
      ),
    );
  }

  Widget _buildFeedHeader({
    required bool showingResults,
    required Color accent,
  }) {
    final theme = Theme.of(context);
    final actionStyle = TextButton.styleFrom(
      foregroundColor: theme.colorScheme.onSurfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              showingResults
                  ? 'Results for "$_activeSearchQuery"'
                  : 'Trending now',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: 21,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (!showingResults)
            TextButton(
              onPressed: _loadingMoreFeed ? null : _refreshFeed,
              style: actionStyle,
              child: const Text('Refresh'),
            ),
          TextButton(
            onPressed: () {
              setState(() {
                _isMultiSelect = !_isMultiSelect;
                if (!_isMultiSelect) _selectedVideos.clear();
              });
            },
            style: _isMultiSelect
                ? actionStyle.copyWith(
                    foregroundColor: WidgetStatePropertyAll(accent),
                  )
                : actionStyle,
            child: Text(_isMultiSelect ? 'Done' : 'Batch'),
          ),
          if (showingResults)
            TextButton(
              onPressed: _clearSearch,
              style: actionStyle,
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.primaryLight : AppColors.primary;
    final bottomClearance = MediaQuery.paddingOf(context).bottom;
    final showingResults = _activeSearchQuery.isNotEmpty;
    final displayedVideos = showingResults ? _searchResults : _feedVideos;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollUpdateNotification ||
                    notification is ScrollEndNotification) {
                  final metrics = notification.metrics;
                  if (metrics.maxScrollExtent > 0 &&
                      metrics.pixels >= metrics.maxScrollExtent - 300) {
                    if (_activeSearchQuery.isEmpty) _triggerLoadMoreFeed();
                  }
                }
                return false;
              },
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: _buildSearchPanel(),
                    ),
                  ),
                  if (!showingResults)
                    SliverToBoxAdapter(child: _buildQuickAccess(accent))
                  else
                    const SliverToBoxAdapter(child: SizedBox(height: 14)),
                  SliverToBoxAdapter(
                    child: _buildFeedHeader(
                      showingResults: showingResults,
                      accent: accent,
                    ),
                  ),

                  // Video Feed List
                  _isSearching
                      ? const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(
                              child: Column(
                                children: [
                                  CircularProgressIndicator(
                                    color: AppColors.primary,
                                  ),
                                  SizedBox(height: 16),
                                  Text('Searching YouTube & web for videos...'),
                                ],
                              ),
                            ),
                          ),
                        )
                      : showingResults && displayedVideos.isEmpty
                      ? const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(
                              child: Text(
                                'No videos found. Try another search term.',
                              ),
                            ),
                          ),
                        )
                      : SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final video = displayedVideos[index];
                              final isSelected = _selectedVideos.contains(
                                video,
                              );

                              return VideoCard(
                                video: video,
                                isMultiSelect: _isMultiSelect,
                                isSelected: isSelected,
                                onSelectToggle: () {
                                  setState(() {
                                    if (isSelected) {
                                      _selectedVideos.remove(video);
                                    } else {
                                      _selectedVideos.add(video);
                                    }
                                  });
                                },
                                onLongPress: () {
                                  setState(() {
                                    _isMultiSelect = true;
                                    _selectedVideos.add(video);
                                  });
                                },
                              );
                            }, childCount: displayedVideos.length),
                          ),
                        ),

                  // Infinite-scroll footer: spinner while the next live page loads,
                  // honest "end" note once the feed is exhausted.
                  if (_activeSearchQuery.isEmpty)
                    SliverToBoxAdapter(child: _buildFeedFooter(isDark)),

                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: bottomClearance + (_isMultiSelect ? 76 : 16),
                    ),
                  ),
                ],
              ),
            ),

            // Floating Batch Download Selection Bar in Multi-Select Mode
            if (_isMultiSelect)
              Positioned(
                left: 16,
                right: 16,
                bottom: bottomClearance + 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkCard : AppColors.lightCard,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.4 : 0.15,
                        ),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () {
                          setState(() {
                            _selectedVideos.clear();
                            _isMultiSelect = false;
                          });
                        },
                      ),
                      Text(
                        'Selected: ${_selectedVideos.length} items',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(
                          Icons.download_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                        label: const Text(
                          'Download Selected',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.white,
                          ),
                        ),
                        onPressed: _selectedVideos.isNotEmpty
                            ? _showBatchFormatSelectionSheet
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
