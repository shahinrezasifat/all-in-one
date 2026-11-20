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

  String _selectedCategory = 'All';
  bool _isExtracting = false;
  bool _isSearching = false;

  List<String> _suggestions = [];
  List<VideoItem> _searchResults = [];
  String _activeSearchQuery = '';

  // LIVE YouTube home feed: page 0 is the real trending chart, later pages pull
  // fresh unique videos as the user scrolls (no more static repeated list).
  final List<VideoItem> _feedVideos = [];
  bool _loadingFeed = true;
  bool _loadingMoreFeed = false;
  bool _hasMoreFeed = true;
  String _feedCategoryKey = '';

  // Multi-Select Batch Download state
  bool _isMultiSelect = false;
  final Set<VideoItem> _selectedVideos = {};

  // Clean, text-only feed filters — no playful emoji-style category icons.
  static const List<String> _categories = [
    'All',
    'Music',
    'Gaming',
    'Technology',
    'Shorts',
    'Comedy',
    'News',
  ];

  @override
  void initState() {
    super.initState();
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
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Fetch a page of fresh, randomised, NEVER-before-seen videos from the
  /// persistent trending engine (which is also refreshed in the background).
  Future<void> _loadFeedPage({bool forceRefresh = false}) async {
    if (_loadingMoreFeed) return;
    setState(() => _loadingMoreFeed = true);
    final batch = await TrendingEngineService.instance.fetchFreshBatch(
      category: _selectedCategory,
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
      if (batch.isEmpty ||
          !TrendingEngineService.instance.hasMore(_selectedCategory)) {
        _hasMoreFeed = false;
      }
    });
    // PRELOAD the page's thumbnails into the 50 MB disk cache in the
    // background, so scrolling the feed never waits on the network.
    SmartNetworkImage.prefetch(batch.map((v) => v.thumbnailUrl));
  }

  /// Force a brand-new randomised feed (called by the header refresh button).
  void _refreshFeed() {
    if (_isSearching) return;
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

  /// When the category changes, restart the feed from a fresh trending page.
  void _ensureFeedCategory() {
    if (_feedCategoryKey == _selectedCategory) return;
    _feedCategoryKey = _selectedCategory;
    _feedVideos.clear();
    _hasMoreFeed = true;
    _loadingFeed = true;
    _loadFeedPage();
  }

  /// Run a search AND record it in the recent-search history so the home screen
  /// can surface what the user actually looked for.
  Future<void> _executeSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;

    _searchFocus.unfocus();
    // Persist the query in the recent-search history (video surface) AND teach
    // the trending engine which channel/topic the user cares about.
    PreferenceService.instance.logSearch(q, isAudio: false);
    TrendingEngineService.instance.logChannel(q);
    setState(() {
      _isSearching = true;
      _activeSearchQuery = q;
      _suggestions = [];
      _searchController.text = q;
    });

    final results = await SearchService.instance.searchVideos(q);

    if (mounted) {
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
    _searchController.clear();
    setState(() {
      _activeSearchQuery = '';
      _searchResults = [];
      _suggestions = [];
    });
  }

  /// Tap a recent-search chip to re-run that query instantly.
  void _reuseRecentSearch(String query) {
    _searchController.text = query;
    _executeSearch(query);
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
            'No unseen videos left • Tap shuffle for a fresh random batch',
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

  Future<void> _onSearchChanged(String query) async {
    setState(() {}); // Trigger rebuild to toggle right button state

    if (query.trim().isEmpty || _submittedLink(query) != null) {
      setState(() {
        _suggestions = [];
      });
      return;
    }

    final list = await SearchService.instance.getSearchSuggestions(query);
    if (mounted && _searchFocus.hasFocus && _searchController.text == query) {
      setState(() {
        _suggestions = list;
      });
    }
  }

  void _showAddBookmarkDialog() {
    final titleCtrl = TextEditingController();
    final urlCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Add Bookmark',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Site Name',
                hintText: 'e.g. Reddit',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://...',
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
            onPressed: () async {
              final title = titleCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (url.isNotEmpty) {
                Navigator.pop(ctx);
                await BookmarkService.instance.addBookmark(
                  title: title,
                  url: url,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Bookmark "${title.isNotEmpty ? title : url}" added successfully!',
                      ),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              }
            },
            child: const Text('Add Bookmark'),
          ),
        ],
      ),
    );
  }

  void _showEditBookmarkDialog(SiteModel site) {
    final titleCtrl = TextEditingController(text: site.title);
    final urlCtrl = TextEditingController(text: site.url);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.edit_rounded, color: AppColors.accentGold),
            SizedBox(width: 8),
            Text(
              'Edit Bookmark',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(
                labelText: 'Site Name',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              decoration: InputDecoration(
                labelText: 'URL',
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
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () async {
              final newTitle = titleCtrl.text.trim();
              final newUrl = urlCtrl.text.trim();
              if (newUrl.isNotEmpty) {
                Navigator.pop(ctx);
                await BookmarkService.instance.editBookmark(
                  oldSite: site,
                  newTitle: newTitle,
                  newUrl: newUrl,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Bookmark updated successfully!'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              }
            },
            child: const Text(
              'Save Changes',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
        ],
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottomClearance = MediaQuery.paddingOf(context).bottom;
    // Restart the live feed whenever the category pill changes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureFeedCategory();
    });
    final displayedVideos = _activeSearchQuery.isNotEmpty
        ? _searchResults
        : _feedVideos;
    final recentSearches = PreferenceService.instance.recentVideoSearches;

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
                  // Unified Search Bar & Top Speed Dial
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 14),
                          Text(
                            'Home',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 12),

                          // 2. Calm search field — the focus ring belongs to the
                          //    input only; suggestions float in their own surface.
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? AppColors.darkCard
                                      : AppColors.lightCard,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: isDark ? .18 : .06,
                                      ),
                                      blurRadius: 16,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  children: [
                                    const SizedBox(width: 14),
                                    Icon(
                                      Icons.search_rounded,
                                      color: isDark
                                          ? Colors.white54
                                          : Colors.black45,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: TextField(
                                        controller: _searchController,
                                        focusNode: _searchFocus,
                                        decoration: const InputDecoration(
                                          hintText:
                                              'Search or paste a video link',
                                          hintStyle: TextStyle(fontSize: 13),
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          contentPadding: EdgeInsets.symmetric(
                                            vertical: 16,
                                          ),
                                        ),
                                        onChanged: _onSearchChanged,
                                        textInputAction: TextInputAction.go,
                                        onSubmitted: _submitSearchOrLink,
                                      ),
                                    ),
                                    if (_searchController.text.isNotEmpty)
                                      IconButton(
                                        icon: Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                          color: isDark
                                              ? Colors.white54
                                              : Colors.black45,
                                        ),
                                        onPressed: _clearSearch,
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    IconButton(
                                      tooltip: 'Paste link',
                                      icon: const Icon(
                                        Icons.content_paste_rounded,
                                        size: 18,
                                      ),
                                      onPressed: () async {
                                        final data = await Clipboard.getData(
                                          Clipboard.kTextPlain,
                                        );
                                        final text = data?.text?.trim();
                                        if (!mounted ||
                                            text == null ||
                                            text.isEmpty)
                                          return;
                                        _searchController
                                            .value = TextEditingValue(
                                          text: text,
                                          selection: TextSelection.collapsed(
                                            offset: text.length,
                                          ),
                                        );
                                        await _onSearchChanged(text);
                                      },
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: Material(
                                        color: AppColors.primary.withValues(
                                          alpha: 0.12,
                                        ),
                                        shape: const CircleBorder(),
                                        child: InkWell(
                                          customBorder: const CircleBorder(),
                                          onTap: _isExtracting
                                              ? null
                                              : () => _submitSearchOrLink(
                                                  _searchController.text,
                                                ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(8),
                                            child: _isExtracting
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color:
                                                              AppColors.primary,
                                                        ),
                                                  )
                                                : const Icon(
                                                    Icons.arrow_forward_rounded,
                                                    size: 18,
                                                    color: AppColors.primary,
                                                  ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Suggestions — quiet borderless rows, no dividers.
                              if (_suggestions.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Container(
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? AppColors.darkCard
                                        : AppColors.lightCard,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Column(
                                    children: [
                                      for (final item in _suggestions.take(5))
                                        Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            onTap: () => _executeSearch(item),
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 14,
                                                    vertical: 10,
                                                  ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.history_rounded,
                                                    size: 16,
                                                    color: isDark
                                                        ? Colors.white38
                                                        : Colors.black38,
                                                  ),
                                                  const SizedBox(width: 12),
                                                  Expanded(
                                                    child: Text(
                                                      item,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                        color: isDark
                                                            ? Colors.white70
                                                            : Colors.black87,
                                                      ),
                                                    ),
                                                  ),
                                                  Icon(
                                                    Icons.north_west_rounded,
                                                    size: 14,
                                                    color: isDark
                                                        ? Colors.white30
                                                        : Colors.black38,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),

                          // Quick access sites — lean header, no helper paragraph.
                          if (_activeSearchQuery.isEmpty) ...[
                            const SizedBox(height: 24),
                            Text(
                              'Quick access',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 12),

                            // Speed Dial with In-App Browser Navigation & BookmarkService
                            AnimatedBuilder(
                              animation: BookmarkService.instance,
                              builder: (context, _) {
                                final sites =
                                    BookmarkService.instance.bookmarks;
                                return SpeedDialGrid(
                                  sites: sites,
                                  onSiteTap: (site) {
                                    if (widget.onOpenBrowser != null) {
                                      widget.onOpenBrowser!(site);
                                    } else {
                                      BrowserScreen.open(context, site);
                                    }
                                  },
                                  onAddBookmark: _showAddBookmarkDialog,
                                  onEditBookmark: _showEditBookmarkDialog,
                                  onDeleteBookmark: (site) async {
                                    await BookmarkService.instance
                                        .removeBookmark(site);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                'Removed ${site.title}',
                                              ),
                                            ),
                                          );
                                    }
                                  },
                                );
                              },
                            ),
                            const SizedBox(height: 22),
                          ] else ...[
                            const SizedBox(height: 14),
                          ],

                          // Recent Searches — the queries the user actually ran on
                          // YouTube, so re-entering the app surfaces what they
                          // cared about instead of an identical static feed.
                          if (_activeSearchQuery.isEmpty &&
                              recentSearches.isNotEmpty) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Recent searches',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => PreferenceService.instance
                                      .clearRecentSearches(isAudio: false),
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  child: const Text(
                                    'Clear',
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 36,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: recentSearches.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final q = recentSearches[index];
                                  return ActionChip(
                                    avatar: const Icon(
                                      Icons.search_rounded,
                                      size: 15,
                                      color: AppColors.primary,
                                    ),
                                    label: Text(
                                      q,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    backgroundColor: isDark
                                        ? AppColors.darkCard
                                        : Colors.grey.shade200,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    onPressed: () => _reuseRecentSearch(q),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 18),
                          ],

                          // Feed header — quiet title, neutral icon, compact action.
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    Icon(
                                      _activeSearchQuery.isNotEmpty
                                          ? Icons.search_rounded
                                          : Icons.trending_up_rounded,
                                      size: 19,
                                      color: AppColors.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _activeSearchQuery.isNotEmpty
                                            ? 'Results for "$_activeSearchQuery"'
                                            : 'Trending now',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                              if (_activeSearchQuery.isEmpty)
                                IconButton(
                                  tooltip: 'Fresh random videos',
                                  icon: Icon(
                                    Icons.shuffle_rounded,
                                    size: 17,
                                    color: isDark
                                        ? AppColors.primaryLight
                                        : AppColors.primaryDark,
                                  ),
                                  onPressed: _refreshFeed,
                                  visualDensity: VisualDensity.compact,
                                ),
                              TextButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _isMultiSelect = !_isMultiSelect;
                                    if (!_isMultiSelect)
                                      _selectedVideos.clear();
                                  });
                                },
                                icon: Icon(
                                  _isMultiSelect
                                      ? Icons.close_rounded
                                      : Icons.download_done_rounded,
                                  size: 16,
                                ),
                                label: Text(
                                  _isMultiSelect ? 'Done' : 'Batch',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                style: TextButton.styleFrom(
                                  foregroundColor: _isMultiSelect
                                      ? AppColors.primary
                                      : (isDark
                                            ? Colors.white60
                                            : Colors.black54),
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                              ),
                              if (_activeSearchQuery.isNotEmpty)
                                TextButton(
                                  onPressed: _clearSearch,
                                  child: const Text(
                                    'Clear',
                                    style: TextStyle(color: AppColors.primary),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),

                          // Minimal text-only feed filters — no icons, no emoji vibe.
                          if (_activeSearchQuery.isEmpty)
                            SizedBox(
                              height: 36,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _categories.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 6),
                                itemBuilder: (context, index) {
                                  final cat = _categories[index];
                                  final selected = cat == _selectedCategory;

                                  return Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: () => setState(
                                        () => _selectedCategory = cat,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                      splashColor: AppColors.primary.withValues(
                                        alpha: 0.08,
                                      ),
                                      highlightColor: AppColors.primary
                                          .withValues(alpha: 0.04),
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 220,
                                        ),
                                        curve: Curves.easeOutCubic,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: selected
                                              ? AppColors.primary.withValues(
                                                  alpha: isDark ? 0.16 : 0.10,
                                                )
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                        child: Text(
                                          cat,
                                          style: TextStyle(
                                            color: selected
                                                ? (isDark
                                                      ? AppColors.primaryLight
                                                      : AppColors.primaryDark)
                                                : (isDark
                                                      ? AppColors
                                                            .darkTextSecondary
                                                      : AppColors
                                                            .lightTextSecondary),
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            fontSize: 12.5,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),

                          const SizedBox(height: 14),
                        ],
                      ),
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
                      : displayedVideos.isEmpty
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
