import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/site_model.dart';
import '../models/video_item.dart';
import '../services/bookmark_service.dart';
import '../services/download_manager.dart';
import '../services/permission_service.dart';
import '../services/preference_service.dart';
import '../services/search_service.dart';
import '../services/speech_service.dart';
import '../services/live_score_service.dart';
import '../services/trending_engine_service.dart';
import '../theme/app_palette.dart';
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
  List<LiveMatch> _liveMatches = [];

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
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      // No free-floating timers in widget tests (fake_async reports them).
      _cacheLiveScoresSilently();
    } else {
      unawaited(
        Future<void>.delayed(
          const Duration(seconds: 3),
          _loadLiveScores,
        ),
      );
    }

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
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Column(
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: context.palette.primary,
                ),
              ),
              SizedBox(height: 10),
              Text(
                'Finding fresh videos…',
                style: TextStyle(fontSize: 12, color: context.palette.onPrimary),
              ),
            ],
          ),
        ),
      );
    }
    if (!_hasMoreFeed) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'You’re caught up.',
            style: TextStyle(
              fontSize: 12,
              color: context.palette.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return SizedBox(height: 8);
  }

  Future<void> _handleFastDownload({String? customUrl}) async {
    if (_isExtracting) return;
    final url = (customUrl ?? _searchController.text).trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Enter a YouTube or website URL.')),
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
        !['http', 'https'].contains(uri.scheme) ||
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

  Future<void> _cacheLiveScoresSilently() =>
      LiveScoreService.instance.fetch();

  Future<void> _loadLiveScores() async {
    final matches = await LiveScoreService.instance.fetch();
    if (mounted && matches.isNotEmpty) setState(() => _liveMatches = matches);
  }

  Color _teamColor(String teamName) {
    final t = teamName.toUpperCase().trim();
    if (t.contains('SRH') || t.contains('SUNRISERS')) return const Color(0xFFF26522);
    if (t.contains('RCB') || t.contains('ROYAL')) return const Color(0xFFEC1C24);
    if (t.contains('KKR') || t.contains('KNIGHT')) return const Color(0xFF805AD5);
    if (t.contains('MI') || t.contains('MUMBAI')) return const Color(0xFF005AFF);
    if (t.contains('CSK') || t.contains('CHENNAI')) return const Color(0xFFF59E0B);
    if (t.contains('RR') || t.contains('RAJASTHAN')) return const Color(0xFFEC4899);
    if (t.contains('DC') || t.contains('DELHI')) return const Color(0xFF3B82F6);
    if (t.contains('PBKS') || t.contains('PUNJAB')) return const Color(0xFFEF4444);
    if (t.contains('GT') || t.contains('GUJARAT')) return const Color(0xFF10B981);
    if (t.contains('LSG') || t.contains('LUCKNOW')) return const Color(0xFF06B6D4);

    final hash = teamName.codeUnits.fold(0, (prev, elem) => prev + elem);
    final hues = [
      Colors.indigo,
      Colors.teal,
      Colors.deepOrange,
      Colors.purple,
      Colors.blue,
      Colors.amber.shade800,
    ];
    return hues[hash % hues.length];
  }

  Widget _teamAvatar(String teamName) {
    final color = _teamColor(teamName);
    final initial = teamName.trim().isNotEmpty
        ? (teamName.trim().length >= 3
            ? teamName.trim().substring(0, 3).toUpperCase()
            : teamName.trim().toUpperCase())
        : 'T';

    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: color,
            fontSize: initial.length >= 3 ? 8 : 9.5,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _buildLiveSection() {
    final p = context.palette;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_liveMatches.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.redAccent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Live Scores',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.3,
                ),
              ),
              const Spacer(),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () async {
                    final fresh = await LiveScoreService.instance.fetch(force: true);
                    if (mounted) setState(() => _liveMatches = fresh);
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: p.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: p.primary.withValues(alpha: 0.22)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh_rounded, size: 14, color: p.primary),
                        const SizedBox(width: 4),
                        Text(
                          'Refresh',
                          style: TextStyle(
                            color: p.primary,
                            fontSize: 11,
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
        ),
        SizedBox(
          height: 122,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _liveMatches.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final m = _liveMatches[index];
              final isLive = m.status.toLowerCase().contains('live') ||
                  m.status.toLowerCase().contains('progress') ||
                  m.status.toLowerCase().contains('inning');

              return Container(
                width: 250,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDark
                        ? [const Color(0xFF1E2230), const Color(0xFF141722)]
                        : [Colors.white, const Color(0xFFF6F8FA)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isLive
                        ? Colors.redAccent.withValues(alpha: 0.45)
                        : (isDark ? const Color(0x22FFFFFF) : Colors.grey.shade300),
                    width: isLive ? 1.5 : 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.06),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Card Top Row: Title & Status Badge
                    Row(
                      children: [
                        Icon(
                          Icons.sports_cricket_rounded,
                          size: 13,
                          color: p.textSecondary,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            m.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                          decoration: BoxDecoration(
                            color: isLive
                                ? Colors.redAccent.withValues(alpha: 0.18)
                                : p.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isLive) ...[
                                Container(
                                  width: 5,
                                  height: 5,
                                  decoration: const BoxDecoration(
                                    color: Colors.redAccent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                isLive ? 'LIVE' : m.status.toUpperCase(),
                                style: TextStyle(
                                  color: isLive ? Colors.redAccent : p.primary,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 6),

                    // Team A Score Row
                    Row(
                      children: [
                        _teamAvatar(m.teamA),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            m.teamA,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Text(
                          m.scoreA,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 4),

                    // Team B Score Row
                    Row(
                      children: [
                        _teamAvatar(m.teamB),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            m.teamB,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Text(
                          m.scoreB,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Free Android voice input; silent cancel leaves the field untouched.
  Future<void> _voiceSearch() async {
    final spoken = await SpeechService.instance.recognize();
    if (spoken == null || spoken.isEmpty || !mounted) return;
    _searchController.text = spoken;
    _refreshSearchField();
    await _submitSearchOrLink(spoken);
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
        SnackBar(content: Text('Copy a video link to paste it here.')),
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
        : <String>[];
    final accent = dark ? context.palette.primary : context.palette.primary;
    final surface = dark ? context.palette.card : context.palette.card;
    final border = dark ? context.palette.border : context.palette.border;
    final muted = dark
        ? context.palette.textSecondary
        : context.palette.textSecondary;

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
                  color: context.palette.shadowAt(dark ? .22 : .06),
                  blurRadius: 16,
                  spreadRadius: -6,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.search_rounded, color: accent, size: 22),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      decoration: InputDecoration(
                        hintText: 'Search videos or paste a link',
                        hintStyle: TextStyle(
                          color: dark
                              ? context.palette.textSecondary
                              : context.palette.textSecondary,
                          fontSize: 14,
                        ),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
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
                        color: dark ? context.palette.textSecondary : context.palette.textSecondary,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  IconButton(
                    tooltip: 'Paste link',
                    onPressed: _isExtracting ? null : _pasteSearchLink,
                    icon: Icon(Icons.link_rounded, size: 19, color: accent),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: 'Voice search',
                    onPressed: _isExtracting ? null : _voiceSearch,
                    icon: Icon(Icons.mic_rounded, size: 19, color: accent),
                    visualDensity: VisualDensity.compact,
                  ),
                  SizedBox(width: 2),
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
                          gradient: context.palette.primaryGradient,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: context.palette.tint(context.palette.primary, .26),
                              blurRadius: 10,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: _isExtracting
                            ? Center(
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: context.palette.card,
                                  ),
                                ),
                              )
                            : Tooltip(
                                message: 'Search videos',
                                child: Icon(
                                  Icons.arrow_forward_rounded,
                                  color: context.palette.textPrimary,
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
          SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: border),
              boxShadow: [
                BoxShadow(
                  color: context.palette.shadowAt(dark ? .20 : .07),
                  blurRadius: 18,
                  spreadRadius: -8,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 2),
                    child: Text(
                      'RECENT SEARCHES',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                        color: dark
                            ? context.palette.textSecondary
                            : context.palette.textSecondary,
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
        duration: Duration(seconds: 2),
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
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: context.palette.surface,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.download_rounded,
                        color: context.palette.primary,
                        size: 24,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Choose Format for ${_selectedVideos.length} Selected Downloads',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Select format option before downloading. Downloads will start after tapping the button below.',
                    style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
                  ),
                  SizedBox(height: 16),

                  Text(
                    'Video Formats',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: context.palette.primary,
                    ),
                  ),
                  SizedBox(height: 4),
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
                        padding: EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSel
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              color: isSel ? context.palette.primary : context.palette.textSecondary,
                              size: 20,
                            ),
                            SizedBox(width: 10),
                            Text(
                              f['label'] as String,
                              style: TextStyle(
                                fontWeight: isSel
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSel ? context.palette.primary : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),

                  SizedBox(height: 10),
                  Text(
                    'Audio Formats (MP3)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: context.palette.info,
                    ),
                  ),
                  SizedBox(height: 4),
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
                        padding: EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSel
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              color: isSel ? context.palette.info : context.palette.textSecondary,
                              size: 20,
                            ),
                            SizedBox(width: 10),
                            Text(
                              f['label'] as String,
                              style: TextStyle(
                                fontWeight: isSel
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSel ? context.palette.info : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),

                  SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _executeBatchDownload(selectedFormat, isAudioFormat);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.palette.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: Icon(
                        Icons.download_done_rounded,
                        color: context.palette.onPrimary,
                      ),
                      label: Text(
                        'Start Batch Download ($selectedFormat)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: context.palette.textPrimary,
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
        backgroundColor: context.palette.primary,
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
      padding: EdgeInsets.fromLTRB(16, 20, 16, 12),
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
                icon: Icon(Icons.bookmark_add_outlined, size: 18),
                label: Text('Add bookmark'),
                style: FilledButton.styleFrom(
                  foregroundColor: accent,
                  backgroundColor: accent.withValues(alpha: dark ? .17 : .09),
                  padding: EdgeInsets.symmetric(horizontal: 13),
                  textStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 6),
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
        ],
      ),
    );
  }

  Widget _buildPromoCards() {
    return const SizedBox.shrink();
  }

  Widget _buildFeedHeader({
    required bool showingResults,
    required Color accent,
  }) {
    final p = context.palette;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!showingResults)
                  Row(
                    children: [
                      Icon(
                        Icons.whatshot_rounded,
                        size: 13,
                        color: accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'DISCOVER',
                        style: TextStyle(
                          color: accent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 2),
                Text(
                  showingResults
                      ? 'Results for "$_activeSearchQuery"'
                      : 'Trending now',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!showingResults) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _loadingMoreFeed ? null : _refreshFeed,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: accent.withValues(alpha: 0.25),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: accent,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                setState(() {
                  _isMultiSelect = !_isMultiSelect;
                  if (!_isMultiSelect) _selectedVideos.clear();
                });
              },
              borderRadius: BorderRadius.circular(20),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 38,
                padding: EdgeInsets.symmetric(
                  horizontal: _isMultiSelect ? 12 : 0,
                ),
                constraints: const BoxConstraints(minWidth: 38),
                decoration: BoxDecoration(
                  color: _isMultiSelect
                      ? accent
                      : accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: accent.withValues(alpha: 0.35),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _isMultiSelect
                          ? Icons.check_rounded
                          : Icons.playlist_add_check_rounded,
                      size: 18,
                      color: _isMultiSelect ? Colors.white : accent,
                    ),
                    if (_isMultiSelect) ...[
                      const SizedBox(width: 5),
                      const Text(
                        'Done',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (showingResults) ...[
            const SizedBox(width: 8),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _clearSearch,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: p.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: p.border),
                  ),
                  child: Text(
                    'Clear',
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = context.palette.primary;
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
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: _buildSearchPanel(),
                    ),
                  ),
                  if (!showingResults)
                    SliverToBoxAdapter(child: _buildQuickAccess(accent))
                  else
                    SliverToBoxAdapter(child: SizedBox(height: 14)),
                  if (!showingResults) ...[
                    SliverToBoxAdapter(child: _buildPromoCards()),
                    if (_liveMatches.isNotEmpty)
                      SliverToBoxAdapter(child: _buildLiveSection()),
                  ],
                  SliverToBoxAdapter(
                    child: _buildFeedHeader(
                      showingResults: showingResults,
                      accent: accent,
                    ),
                  ),

                  // Video Feed List
                  _isSearching
                      ? SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(
                              child: Column(
                                children: [
                                  CircularProgressIndicator(
                                    color: context.palette.primary,
                                  ),
                                  SizedBox(height: 16),
                                  Text('Searching YouTube & web for videos...'),
                                ],
                              ),
                            ),
                          ),
                        )
                      : showingResults && displayedVideos.isEmpty
                      ? SliverToBoxAdapter(
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
                          padding: EdgeInsets.symmetric(horizontal: 16),
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
                  padding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: context.palette.card,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: context.palette.shadowAt(isDark ? 0.4 : 0.15,),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.close_rounded, size: 20),
                        onPressed: () {
                          setState(() {
                            _selectedVideos.clear();
                            _isMultiSelect = false;
                          });
                        },
                      ),
                      Text(
                        'Selected: ${_selectedVideos.length} items',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      Spacer(),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: context.palette.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: Icon(
                          Icons.download_rounded,
                          color: context.palette.onPrimary,
                          size: 18,
                        ),
                        label: Text(
                          'Download Selected',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: context.palette.textPrimary,
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
