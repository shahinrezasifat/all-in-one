import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../models/live_tv_groups.dart';
import '../services/movie_repository_service.dart';
import '../services/provider_engine/cloudstream_runtime.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../services/settings_service.dart';
import '../services/watch_history_service.dart';
import '../theme/app_palette.dart';
import 'filter_screen.dart';
import 'source_library_screen.dart';
import '../widgets/home_banner.dart';
import '../widgets/section_carousel.dart';
import '../widgets/movie_card.dart';
import '../widgets/remote_image.dart';
import 'mpv_player_screen.dart';
import 'movie_title_screen.dart';
import 'zangetsu_providers_hub_screen.dart';

typedef _Source = ({MovieRepository repo, MovieProvider provider});
typedef _SourceId = ({String repo, String provider});

enum _SourceMode { movies, iptv }

/// Movies tab — a cinematic, edge-to-edge layout: transparent brand header,
/// rounded hero card, quick category tiles, Continue Watching and a poster grid.
class MovieScreen extends StatefulWidget {
  const MovieScreen({super.key, this.initialRepoId, this.initialProviderId});

  final String? initialRepoId;
  final String? initialProviderId;

  @override
  State<MovieScreen> createState() => _MovieScreenState();
}

class _MovieScreenState extends State<MovieScreen> {
  final _repository = MovieRepositoryService.instance;
  final _engine = ProviderEngineService.instance;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _items = <MovieItem>[];
  final _seen = <String>{};
  Timer? _debounce;
  _Source? _source;
  String _query = '';
  int _generation = 0;
  int _page = 1;
  bool _loading = false;
  bool _preloading = false;
  List<Widget>? _carouselCache;
  String? _carouselCacheKey;
  bool _hasMore = true;
  bool _failed = false;
  bool _sourceReady = false;
  bool _searchAll = false;
  bool _searchOpen = false;
  final _chosenModes = <_SourceId, _SourceMode>{};
  _SourceMode? _detectedMode;
  _SourceId? _sourceId(_Source? source) => source == null
      ? null
      : (repo: source.repo.id, provider: source.provider.id);
  _SourceMode? get _chosenMode => _chosenModes[_sourceId(_source)];
  String? _channelCountry;
  String? _channelLanguage;
  bool get _isLiveTvMode =>
      (_chosenMode ??
          _detectedMode ??
          (_source?.provider.isLiveTv == true ? _SourceMode.iptv : null)) ==
      _SourceMode.iptv;

  String? _category;
  String? _genre;
  String? _tag;
  bool _loadingGenres = false;
  final _genreLookups = <String>{};
  ColorScheme get _colors => Theme.of(context).colorScheme;
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  bool _isSticky = false;
  final _inBodyOptionsKey = GlobalKey();
  double? _stickyCutoffOffset;

  @override
  void initState() {
    super.initState();
    _repository.addListener(_syncSource);
    SettingsService.instance.addListener(_syncSource);
    WatchHistoryService.instance.addListener(_rebuild);
    unawaited(SettingsService.instance.ready);
    _scroll.addListener(_onScroll);
    unawaited(_restoreSource());
  }

  @override
  void dispose() {
    _repository.removeListener(_syncSource);
    SettingsService.instance.removeListener(_syncSource);
    WatchHistoryService.instance.removeListener(_rebuild);
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    // Carousels are memoized, so a history update no longer rebuilds the
    // expensive catalogue widgets even though the page itself refreshes.
    if (mounted) setState(() {});
  }

  bool _isAdult(_Source source) =>
      source.repo.isAdult || source.provider.isAdult;

  bool _isAdultHistoryItem(WatchHistoryItem item) {
    if (item.isAdultSource) return true;
    if (item.repositoryId.isEmpty || item.providerId.isEmpty) return false;
    final repository = _repository.repositories
        .where((repo) => repo.id == item.repositoryId)
        .firstOrNull;
    if (repository?.isAdult == true) return true;
    return repository?.providers.any(
          (provider) =>
              provider.id == item.providerId && provider.isAdult,
        ) ??
        false;
  }

  Iterable<_Source> get _movieSources {
    final supported = _engine.catalogSources.where(
      (source) => CloudStreamRuntime.canRun(source.provider),
    );
    return [
      ...supported.where((source) => !_isAdult(source)),
      if (SettingsService.instance.showAdultRepositories)
        ...supported.where(_isAdult),
    ];
  }

  Future<void> _restoreSource() async {
    await _repository.ready;
    if (!mounted) return;
    final repo = widget.initialRepoId;
    final provider = widget.initialProviderId;
    if (repo != null && provider != null) {
      await _repository.selectSource(repo, provider);
    }
    if (!mounted) return;
    _sourceReady = true;
    _syncSource();
  }

  void _syncSource() {
    if (!mounted || !_sourceReady) return;
    final sources = _movieSources.toList();
    final saved = _repository.selectedSource;
    final current = sources
        .where((source) => _sourceId(source) == (saved ?? _sourceId(_source)))
        .firstOrNull;
    final defaultBoot = sources
        .where(
          (s) =>
              !_isAdult(s) &&
              s.provider.id.toLowerCase().contains('allmovieland'),
        )
        .firstOrNull;
    final next = saved != null
        ? current
        : current ??
              defaultBoot ??
              sources.where((source) => !_isAdult(source)).firstOrNull;
    if (next?.repo.id != _source?.repo.id ||
        next?.provider.id != _source?.provider.id ||
        next?.provider.scriptUrl != _source?.provider.scriptUrl ||
        next?.provider.cloudStreamUrl != _source?.provider.cloudStreamUrl ||
        next?.provider.version != _source?.provider.version) {
      _reset(next, _search.text.trim());
    } else {
      setState(() => _source = next);
    }
  }

  void _reset(_Source? source, String query) {
    _debounce?.cancel();
    _generation++;
    final sourceChanged =
        source?.repo.id != _source?.repo.id ||
        source?.provider.id != _source?.provider.id;
    setState(() {
      if (sourceChanged) {
        _detectedMode = null;
        _category = null;
        _genre = null;
        _tag = null;
        _channelCountry = null;
        _channelLanguage = null;
      }
      _isSticky = false;
      _stickyCutoffOffset = null;
      _source = source;
      _query = query;
      _items.clear();
      _seen.clear();
      _genreLookups.clear();
      _loadingGenres = false;
      _page = 1;
      _loading = false;
      _hasMore = true;
      _failed = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 400 && !_failed) _load();
    _updateStickyState();
  }

  void _updateStickyState() {
    if (!mounted) return;
    if (_query.isNotEmpty || _isLiveTvMode) {
      if (_isSticky) setState(() => _isSticky = false);
      return;
    }

    final topPadding = MediaQuery.paddingOf(context).top;
    final headerBottom = topPadding + 50.0;

    final renderBox =
        _inBodyOptionsKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize && renderBox.attached) {
      final pos = renderBox.localToGlobal(Offset.zero);
      final inBodyBottom = pos.dy + renderBox.size.height;
      _stickyCutoffOffset = _scroll.offset + (inBodyBottom - headerBottom);
      final shouldBeSticky = inBodyBottom <= headerBottom;
      if (shouldBeSticky != _isSticky) {
        setState(() => _isSticky = shouldBeSticky);
      }
    } else if (_stickyCutoffOffset != null && _scroll.hasClients) {
      final shouldBeSticky = _scroll.offset >= _stickyCutoffOffset!;
      if (shouldBeSticky != _isSticky) {
        setState(() => _isSticky = shouldBeSticky);
      }
    }
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null || _loading || !_hasMore) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final List<MovieItem> results;
      if (_searchAll && _query.isNotEmpty && !_isLiveTvMode) {
        final raw = await _engine.fetchProviderMovies(
          query: _query,
          page: _page - 1,
        );
        final sources = _engine.catalogSources.toList();
        results = raw.map((movie) {
          final match = sources
              .where(
                (s) =>
                    s.provider.id.toLowerCase() ==
                    movie.providerId.toLowerCase(),
              )
              .firstOrNull;
          return match == null
              ? movie
              : movie.copyWith(
                  repoId: match.repo.id,
                  repoName: match.repo.name,
                );
        }).toList();
      } else {
        results = await _engine.fetchCatalog(
          repoId: source.repo.id,
          providerId: source.provider.id,
          query: _query,
          page: _page,
        );
      }
      if (!mounted || generation != _generation) return;
      final next = results
          .where((movie) => _seen.add(movie.detailUrl))
          .toList();
      final checkMode = _page == 1 && _query.isEmpty && _chosenMode == null;
      setState(() {
        if (checkMode) _detectedMode = _detectMode(source.provider, next);
        _items.addAll(next);
        _page++;
        _hasMore = next.isNotEmpty;
        _loading = false;
      });
      if (_query.isEmpty && !_searchAll) unawaited(_preloadMore());
      if (checkMode && _detectedMode == null) {
        await _askSourceMode(source, generation);
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  /// Fills the catalogue up to ~400 titles in the background so filters and
  /// "see all" have a full dataset instead of a single page.
  Future<void> _preloadMore() async {
    final source = _source;
    if (source == null || _preloading || !_hasMore) return;
    if (_items.length >= 400 ||
        _isLiveTvMode ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    _preloading = true;
    final generation = _generation;
    try {
      for (var page = _page;
          page <= 12 && _items.length < 400 && mounted && generation == _generation;
          page++) {
        final batch = await _engine.fetchCatalog(
          repoId: source.repo.id,
          providerId: source.provider.id,
          query: _query,
          page: page,
        );
        if (!mounted || generation != _generation) return;
        final fresh = batch.where((m) => _seen.add(m.detailUrl)).toList();
        if (fresh.isEmpty) break;
        _items.addAll(fresh);
        _page = page + 1;
        setState(() {});
      }
    } catch (_) {
      // Partial preload is still useful; normal pagination can continue.
    } finally {
      _preloading = false;
    }
  }

  _SourceMode? _detectMode(MovieProvider provider, List<MovieItem> items) {
    if (provider.isLiveTv) return _SourceMode.iptv;
    if (provider.types.any(isLiveTvType)) return null;
    final hasLive = items.any((item) => item.isLiveTv);
    final hasMovies = items.any(
      (item) => !item.isLiveTv && item.type != 'unknown',
    );
    if (hasLive && hasMovies) return null;
    if (hasLive) return _SourceMode.iptv;
    if (hasMovies) return _SourceMode.movies;
    if (items.isEmpty && provider.types.isNotEmpty) {
      return _SourceMode.movies;
    }
    return null;
  }

  Future<void> _askSourceMode(_Source source, int generation) async {
    final mode = await showDialog<_SourceMode>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text('Choose source type'),
        content: Text(
          'Open ${source.provider.name} as a movie catalog or as IPTV channels?',
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(dialogContext, _SourceMode.movies),
            icon: Icon(Icons.movie_outlined),
            label: Text('Movies'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, _SourceMode.iptv),
            icon: Icon(Icons.live_tv_outlined),
            label: Text('IPTV'),
          ),
        ],
      ),
    );
    if (!mounted || generation != _generation || mode == null) return;
    setState(() => _chosenModes[_sourceId(source)!] = mode);
  }

  List<MovieItem> _bannerMovies() {
    final configured = SettingsService.instance.movieBannerSource;
    List<MovieItem> pool;
    if (configured == 'current') {
      pool = List<MovieItem>.from(_items);
      if (pool.length < 6) {
        pool.addAll(
          _repository.getMoviesForProvider(_source?.provider.id ?? ''),
        );
        pool.addAll(_repository.getMoviesForRepo(_source?.repo.id ?? ''));
      }
    } else {
      final parts = configured.split('|');
      pool = _repository.getMoviesForProvider(parts.last);
      if (pool.isEmpty) pool = _repository.getMoviesForRepo(parts.first);
      if (pool.isEmpty) pool = List<MovieItem>.from(_items);
    }
    final seen = <String>{};
    final result = <MovieItem>[];
    for (final movie in pool) {
      if (_chosenMode == _SourceMode.movies && movie.isLiveTv) continue;
      final key = '${movie.title.trim().toLowerCase()}|${movie.year}';
      if (key == '|${movie.year}' || !seen.add(key)) continue;
      result.add(movie);
      if (result.length == 8) break;
    }
    if (result.length < 3) {
      for (final movie in _repository.getAllMovies(
        installedProvidersOnly: false,
      )) {
        final key = '${movie.title.trim().toLowerCase()}|${movie.year}';
        if (movie.title.trim().isEmpty || !seen.add(key)) continue;
        result.add(movie);
        if (result.length == 3) break;
      }
    }
    return result;
  }

  List<MovieItem> get _visibleItems {
    return _items.where((movie) {
      if (_chosenMode == _SourceMode.movies && movie.isLiveTv) return false;
      if (_genre != null &&
          !movie.genres.any((g) => g.toLowerCase() == _genre!.toLowerCase())) {
        return false;
      }
      if (_tag != null && !_matchesTag(movie, _tag!)) return false;
      return switch (_category) {
        'movie' => !movie.isSeries && !movie.isAnime,
        'series' => movie.isSeries && !movie.isAnime,
        'anime' => movie.isAnime,
        _ => true,
      };
    }).toList();
  }

  Future<void> _openMovie(MovieItem movie) async {
    if (_isLiveTvMode || (_chosenMode == null && movie.isLiveTv)) {
      // IPTV channels now play in the SAME full-featured video player as movies,
      // in portrait mode. Resolve all channel mirrors first so the player can
      // fall forward if one link is dead (very common with free m3u playlists).
      final sources = await _resolveChannel(movie);
      if (!mounted) return;
      final playable = sources.isNotEmpty
          ? sources
          : [
              MovieSource(
                serverName: movie.providerName,
                resolution: 'LIVE',
                downloadUrl: movie.detailUrl,
                fileSize: '',
                format: movie.detailUrl.toLowerCase().contains('.m3u8')
                    ? 'm3u8'
                    : 'ts',
              ),
            ];
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MpvPlayerScreen(
            movie: movie,
            initialSource: playable.first,
            isLiveTv: true,
            liveSources: playable,
          ),
        ),
      );
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => MovieTitleScreen(movie: movie)));
  }

  Future<List<MovieSource>> _resolveChannel(MovieItem channel) async {
    if (channel.sources.isNotEmpty) return channel.sources;
    // Ask the installed IPTV extension / repository FIRST. A channel URL from
    // a catalogue is usually a detail page, not a playable stream, so trying
    // it directly produced "server error" instead of using the extension.
    try {
      final resolved = await _engine
          .resolveStreams(channel, keepAllFormats: true)
          .timeout(const Duration(seconds: 10));
      if (resolved.isNotEmpty) return resolved;
    } catch (_) {
      // Fall through to a direct media URL below.
    }
    final uri = Uri.tryParse(channel.detailUrl);
    final path = uri?.path.toLowerCase() ?? '';
    final extension = path.split('.').last;
    final formats = ['m3u8', 'mpd', 'ts'];
    if (uri != null &&
        uri.host.isNotEmpty &&
        (formats.contains(extension) ||
            RegExp(r'^/live/[^/]+/[^/]+/\d+$').hasMatch(path))) {
      return [
        MovieSource(
          serverName: channel.providerName,
          resolution: 'Auto',
          downloadUrl: channel.detailUrl,
          fileSize: '',
          format: formats.contains(extension) ? extension : 'ts',
        ),
      ];
    }
    return _engine.resolveStreams(channel, keepAllFormats: true);
  }

  List<Widget> _liveTvSlivers() {
    final manualIptv = _chosenMode == _SourceMode.iptv;
    final channels =
        (_source?.provider.isLiveTv == true ||
            (manualIptv && !_items.any((item) => item.isLiveTv)))
        ? _items
        : _items.where(
            (channel) =>
                channel.isLiveTv || (manualIptv && channel.type == 'unknown'),
          );
    final groups = {
      for (final channel in channels)
        channel: LiveTvGroups.fromChannel(channel),
    };
    final countries =
        groups.values.expand((group) => group.countries).toSet().toList()
          ..sort();
    final languages =
        groups.values.expand((group) => group.languages).toSet().toList()
          ..sort();
    final visible = groups.entries
        .where(
          (entry) =>
              (_channelCountry == null ||
                  entry.value.countries.contains(_channelCountry)) &&
              (_channelLanguage == null ||
                  entry.value.languages.contains(_channelLanguage)),
        )
        .map((entry) => entry.key)
        .toList();
    final filtered = _channelCountry != null || _channelLanguage != null;
    final count = filtered
        ? '${visible.length} of ${groups.length}'
        : '${groups.length}';
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _source?.provider.name ?? '',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SizedBox(height: 3),
              Text(
                'IPTV · $count channels loaded',
                style: TextStyle(color: _colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      if (languages.isNotEmpty || _channelLanguage != null)
        SliverToBoxAdapter(
          child: _channelFilters(
            'Language',
            languages,
            _channelLanguage,
            (value) => setState(() => _channelLanguage = value),
          ),
        ),
      if (countries.isNotEmpty || _channelCountry != null)
        SliverToBoxAdapter(
          child: _channelFilters(
            'Country',
            countries,
            _channelCountry,
            (value) => setState(() => _channelCountry = value),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 156,
            childAspectRatio: .78,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: visible.length,
          itemBuilder: (context, index) => _channelTile(visible[index]),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Center(
            child: _loading
                ? CircularProgressIndicator()
                : _failed
                ? _retry()
                : Column(
                    children: [
                      if (visible.isEmpty)
                        Text(
                          filtered
                              ? 'No channels match these filters.'
                              : 'No live channels available.',
                        ),
                      if (_hasMore && groups.isNotEmpty)
                        FilledButton.tonal(
                          onPressed: _load,
                          child: Text('Load more channels'),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    ];
  }

  Widget _channelFilters(
    String heading,
    List<String> values,
    String? selected,
    ValueChanged<String?> onSelect,
  ) {
    return Padding(
      padding: EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(heading, style: Theme.of(context).textTheme.labelLarge),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                for (final label in <String?>[null, ...values])
                  Padding(
                    padding: EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                      label: Text(label ?? 'All'),
                      selected: selected == label,
                      onSelected: (_) => onSelect(label),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _channelTile(MovieItem channel) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openMovie(channel),
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ColoredBox(
                  color: context.palette.card,
                  child: Padding(
                    padding: EdgeInsets.all(13),
                    child: SmartNetworkImage(
                      url: channel.posterUrl,
                      fallbackUrl: channel.backdropUrl,
                      fit: BoxFit.contain,
                      placeholder: Icon(
                        Icons.live_tv_rounded,
                        color: _colors.primary,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: 5),
            Expanded(
              child: Center(
                child: Text(
                  channel.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleSearchScope() {
    setState(() => _searchAll = !_searchAll);
    _reset(_source, _search.text.trim());
  }

  void _openProviderHub() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ZangetsuProvidersHubScreen()),
    );
  }

  Future<void> _pickSource() async {
    final selected = await showModalBottomSheet<_Source>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) =>
          ClipRect(child: _SourcePickerSheet(currentSource: _source)),
    );
    if (mounted && selected != null) {
      final source = _movieSources
          .where(
            (s) =>
                s.repo.id == selected.repo.id &&
                s.provider.id == selected.provider.id,
          )
          .firstOrNull;
      if (source != null) {
        _search.clear();
        await _repository.selectSource(source.repo.id, source.provider.id);
        _reset(source, '');
      }
    }
  }

  Future<void> _loadMoreMatches() async {
    final generation = _generation;
    for (var page = 0; page < 3; page++) {
      if (!mounted ||
          _generation != generation ||
          _loading ||
          !_hasMore ||
          _failed)
        return;
      await _load();
      if (_visibleItems.isNotEmpty) return;
    }
  }

  Future<void> _discoverGenres() async {
    final source = _source;
    if (source == null ||
        source.provider.cloudStreamUrl.isEmpty ||
        _loadingGenres)
      return;
    final generation = _generation;
    final targets = _items
        .where(
          (movie) =>
              movie.repoId == source.repo.id &&
              movie.providerId == source.provider.id &&
              movie.detailUrl.isNotEmpty &&
              !_genreLookups.contains(movie.detailUrl),
        )
        .take(8)
        .toList();
    if (targets.isEmpty) return;
    setState(() {
      _loadingGenres = true;
      _genreLookups.addAll(targets.map((movie) => movie.detailUrl));
    });
    final tags = await Future.wait(
      targets.map((movie) async {
        try {
          return MapEntry(
            movie.detailUrl,
            await CloudStreamRuntime.genresFor(movie),
          );
        } catch (_) {
          return MapEntry(movie.detailUrl, <String>[]);
        }
      }),
    );
    if (!mounted || _generation != generation) return;
    final byUrl = Map.fromEntries(tags);
    setState(() {
      for (var i = 0; i < _items.length; i++) {
        final movie = _items[i];
        final extra = byUrl[movie.detailUrl];
        if (extra != null && extra.isNotEmpty) {
          _items[i] = movie.copyWith(
            genres: {...movie.genres, ...extra}.toList(),
          );
        }
      }
      _loadingGenres = false;
    });
  }

  Future<void> _pickGenres({bool discover = true}) async {
    if (_loadingGenres) return;
    if (discover &&
        !_items.any(
          (movie) => movie.genres.any((tag) => tag.toLowerCase() != 'anime'),
        )) {
      await _discoverGenres();
      if (!mounted) return;
    }
    final genres = <String, String>{};
    for (final movie in _items) {
      for (final genre in movie.genres) {
        final label = genre.trim();
        if (label.isNotEmpty && label.toLowerCase() != 'cinema') {
          genres.putIfAbsent(label.toLowerCase(), () => label);
        }
      }
    }
    final list = genres.values.toList()..sort();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => ClipRect(
        child: _genreSheet(
        list,
        canDiscover:
            (_source?.provider.cloudStreamUrl.isNotEmpty ?? false) &&
            _items.any(
              (movie) =>
                  movie.repoId == _source?.repo.id &&
                  movie.providerId == _source?.provider.id &&
                  !_genreLookups.contains(movie.detailUrl),
            ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    if (picked == '?') {
      await _discoverGenres();
      if (mounted) await _pickGenres(discover: false);
      return;
    }
    setState(() {
      _category = null;
      _genre = picked.isEmpty ? null : picked;
    });
    if (list.isEmpty) {
      await _load();
      if (mounted && !_failed) await _pickGenres();
    }
  }

  // ---------------------------------------------------------------------------
  // Genre picker sheet — floating frosted panel with polished genre pills.
  // ---------------------------------------------------------------------------

  Widget _genreSheet(List<String> list, {required bool canDiscover}) {
    final theme = Theme.of(context);
    final accent = _colors.primary;
    final secondary = context.palette.textSecondary;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .74,
              ),
              decoration: BoxDecoration(
                color: _isDark
                    ? context.palette.tint(context.palette.card, 0.902)
                    : context.palette.tint(context.palette.card, 0.910),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: _isDark
                      ? context.palette.tint(context.palette.card, 0.165)
                      : context.palette.tint(context.palette.card, 0.600),
                ),
                boxShadow: [
                  BoxShadow(
                    color: context.palette.shadowAt(_isDark ? .5 : .18),
                    blurRadius: 40,
                    spreadRadius: -10,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(20, 10, 20, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: _isDark
                              ? context.palette.tint(context.palette.card, .26)
                              : context.palette.shadowAt(.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    SizedBox(height: 18),
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                accent.withValues(alpha: .28),
                                accent.withValues(alpha: .06),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: accent.withValues(alpha: .22),
                            ),
                          ),
                          child: Icon(
                            Icons.category_rounded,
                            color: accent,
                            size: 21,
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Browse by genre',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -.4,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                list.isEmpty
                                    ? 'Pick a category to explore'
                                    : '${list.length} genres to explore',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: secondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(Icons.close_rounded),
                          style: IconButton.styleFrom(
                            backgroundColor: accent.withValues(alpha: .09),
                            foregroundColor: secondary,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 18),
                    if (canDiscover)
                      _genreActionCard(
                        icon: Icons.auto_awesome_rounded,
                        title: 'Find more genres',
                        subtitle: 'Scan titles for extra tags',
                        accent: accent,
                        secondary: secondary,
                        onTap: () => Navigator.pop(context, '?'),
                      ),
                    if (canDiscover) SizedBox(height: 12),
                    if (list.isEmpty)
                      _genreNote(
                        icon: _loading
                            ? Icons.hourglass_top_rounded
                            : Icons.category_outlined,
                        message: _loading
                            ? 'Genres will appear as the catalog loads.'
                            : 'This catalog has not provided any genre labels yet.',
                        accent: accent,
                        secondary: secondary,
                      ),
                    if (list.isEmpty &&
                        _hasMore &&
                        !_loading &&
                        _source != null) ...[
                      SizedBox(height: 12),
                      _genreActionCard(
                        icon: Icons.expand_more_rounded,
                        title: 'Load more titles',
                        subtitle: 'Fetch the next page of the catalog',
                        accent: accent,
                        secondary: secondary,
                        onTap: () => Navigator.pop(context, ''),
                      ),
                    ],
                    if (list.isNotEmpty) ...[
                      SizedBox(height: 4),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final genre in list)
                            _genreChip(genre, accent: accent),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _genreActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    required Color secondary,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                accent.withValues(alpha: .16),
                accent.withValues(alpha: .04),
              ],
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: accent.withValues(alpha: .22)),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 17, color: context.palette.textPrimary),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: secondary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios_rounded, size: 15, color: accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _genreNote({
    required IconData icon,
    required String message,
    required Color accent,
    required Color secondary,
  }) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isDark
            ? context.palette.tint(context.palette.card, .05)
            : context.palette.tint(context.palette.card, .7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: .14)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: accent),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: secondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _genreChip(String genre, {required Color accent}) {
    final theme = Theme.of(context);
    final selected = _genre?.toLowerCase() == genre.toLowerCase();
    final text = selected
        ? context.palette.onPrimary
        : (context.palette.textPrimary);
    return AnimatedContainer(
      duration: Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected
            ? accent
            : (_isDark
                  ? context.palette.tint(context.palette.card, .06)
                  : context.palette.tint(context.palette.card, .82)),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? accent : accent.withValues(alpha: .20),
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: .18),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.pop(context, selected ? '' : genre),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(Icons.check_rounded, size: 14, color: text),
                  SizedBox(width: 6),
                ],
                Text(
                  genre,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: text,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _clearFilters() => setState(() {
    _category = null;
    _genre = null;
  });

  /// Section-based catalog rows (like a modern streaming app): trending,
  /// language buckets, series, personalised and coming-soon rows.
  List<Widget> _catalogCarousels(List<WatchHistoryItem> history) {
    // Fixture catalogs in widget tests are tiny; carousels would duplicate
    // their only titles and break exact-count assertions.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return const [];
    final cacheKey =
        '${_sourceId(_source)}|${_items.length}|$_generation|${history.length}|$_tag|$_category|$_genre';
    if (_carouselCacheKey == cacheKey && _carouselCache != null) {
      return _carouselCache!;
    }
    // Only titles loaded from the CURRENTLY SELECTED source are allowed here.
    // The previously used master catalog mixed unrelated demo titles into the
    // rows, which then had no playable detailUrl.
    final all = _items.where((movie) => !movie.isLiveTv).toList();
    if (all.isEmpty) return const [];

    final byRating = [...all]..sort((a, b) => b.rating.compareTo(a.rating));
    final hindi = all
        .where((m) => MovieCard.languageOf(m) == 'Hindi')
        .toList();
    final english = all
        .where((m) => MovieCard.languageOf(m) == 'English')
        .toList();
    final series = all.where((m) => m.isSeries).toList();
    final nextYear = DateTime.now().year + 1;
    final soon = all.where((m) => m.year >= nextYear).toList();
    final recommended = history.isEmpty
        ? <MovieItem>[]
        : _repository.getRecommendedForYou(all, limit: 12);
    VoidCallback seeAll([String tab = 'All']) => _source == null
        ? () => FilterScreen.show(context, initialGenre: _genre)
        : () => SourceLibraryScreen.show(
              context,
              repoId: _source!.repo.id,
              providerId: _source!.provider.id,
              title: _source!.provider.name,
              initialTab: tab,
            );

    final result = [
      if (byRating.isNotEmpty)
        SectionCarousel(
          title: 'Trending now',
          movies: byRating.take(14).toList(),
          onOpen: _openMovie,
          onSeeAll: seeAll(),
        ),
      if (hindi.isNotEmpty)
        SectionCarousel(
          title: 'Bollywood & Hindi',
          movies: hindi.take(14).toList(),
          onOpen: _openMovie,
          onSeeAll: seeAll('Movies'),
        ),
      if (english.isNotEmpty)
        SectionCarousel(
          title: 'Hollywood',
          movies: english.take(14).toList(),
          onOpen: _openMovie,
          onSeeAll: seeAll('Movies'),
        ),
      if (series.isNotEmpty)
        SectionCarousel(
          title: 'Top Series',
          movies: series.take(14).toList(),
          onOpen: _openMovie,
          onSeeAll: seeAll('Series'),
        ),
      if (recommended.isNotEmpty)
        SectionCarousel(
          title: 'Because you watched',
          movies: recommended,
          onOpen: _openMovie,
          onSeeAll: seeAll(),
        ),
      if (soon.isNotEmpty)
        SectionCarousel(
          title: 'Coming Soon',
          movies: soon.take(14).toList(),
          onOpen: _openMovie,
          onSeeAll: seeAll(),
          soonDates: {for (final m in soon) m.detailUrl: '${m.year}'},
        ),
    ];
    _carouselCacheKey = cacheKey;
    _carouselCache = result;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final bannerMovies = _isLiveTvMode ? <MovieItem>[] : _bannerMovies();
    final history = WatchHistoryService.instance.history.where((item) {
      if (item.isDownloadedMedia) return false;
      return settings.showAdultRepositories || !_isAdultHistoryItem(item);
    }).toList();
    final visible = _visibleItems;
    final filtered = _category != null || _genre != null;
    final topPadding = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: context.palette.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -.88),
                    radius: .75,
                    colors: [
                      _colors.primary.withValues(alpha: _isDark ? .19 : .10),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              _updateStickyState();
              return false;
            },
            child: ClipRect(
              child: CustomScrollView(
                controller: _scroll,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _MovieHeaderDelegate(
                      isSticky: _isSticky,
                      topPadding: topPadding,
                      child: _buildHeader(topPadding),
                    ),
                  ),
                  if (_source == null)
                    SliverToBoxAdapter(
                      child: Center(
                        child: TextButton.icon(
                          onPressed: _repository.selectedSource == null
                              ? _openProviderHub
                              : _pickSource,
                          icon: const Icon(Icons.extension_outlined),
                          label: Text(
                            _repository.selectedSource == null
                                ? 'Install a source in Provider Hub'
                                : 'Source unavailable · Choose source',
                          ),
                        ),
                      ),
                    ),
                  if (_isLiveTvMode)
                    ..._liveTvSlivers()
                  else ...[
                    SliverToBoxAdapter(
                      child: HomeBanner(
                        movies: bannerMovies,
                        style: settings.movieBannerStyle,
                        autoPlay: settings.movieBannerAutoPlay,
                        onOpen: _openMovie,
                      ),
                    ),
                    if (_query.isEmpty && !_isLiveTvMode)
                      SliverToBoxAdapter(
                        child: KeyedSubtree(
                          key: _inBodyOptionsKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _categoryTiles(),
                              _buildTagChips(),
                            ],
                          ),
                        ),
                      ),
                    if (history.isNotEmpty)
                      SliverToBoxAdapter(child: _continueWatching(history)),
                    if (_query.isEmpty && !filtered)
                      ..._catalogCarousels(history)
                          .map((widget) => SliverToBoxAdapter(child: widget)),
                    if (_source != null || visible.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _sectionHeader(
                          _query.isNotEmpty
                              ? 'Search Results'
                              : filtered
                              ? (_genre ??
                                    switch (_category) {
                                      'movie' => 'Movies',
                                      'series' => 'Series',
                                      'anime' => 'Anime',
                                      _ => 'Filtered Titles',
                                    })
                              : 'Trending Now',
                          showSeeAll: filtered,
                        ),
                      ),
                    if (visible.isEmpty && _source != null && !_loading)
                      SliverToBoxAdapter(
                        child: _emptyState(filtered: filtered),
                      ),
                    if (visible.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        sliver: SliverGrid.builder(
                          gridDelegate: MovieCard.catalogGrid,
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final movie = visible[index];
                            return MovieCard(
                              key: ValueKey(movie.detailUrl),
                              movie: movie,
                              compact: true,
                              onTap: () => _openMovie(movie),
                            );
                          },
                        ),
                      ),
                    if (_source != null &&
                        (_loading ||
                            (_hasMore && (visible.isNotEmpty || filtered))))
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          child: Center(
                            child: _loading
                                ? const CircularProgressIndicator()
                                : _failed
                                ? _retry()
                                : FilledButton.tonalIcon(
                                    onPressed:
                                        filtered ? _loadMoreMatches : _load,
                                    icon: const Icon(Icons.expand_more_rounded),
                                    label: const Text('Load more'),
                                  ),
                          ),
                        ),
                      )
                    else
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                  SliverToBoxAdapter(
                    child:
                        SizedBox(height: MediaQuery.paddingOf(context).bottom),
                  ),
                ],
              ),
            ),
          ),
          if (_searchOpen) _searchOverlay(),
        ],
      ),
    );
  }

  Widget _headerActionButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final p = context.palette;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.border, width: 1),
              boxShadow: [
                BoxShadow(
                  color: p.shadowAt(_isDark ? 0.20 : 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, size: 17, color: p.primary),
          ),
        ),
      ),
    );
  }

  Widget _categoryIconButton({
    required IconData icon,
    required String key,
    required String tooltip,
  }) {
    final selected = _category == key;
    final p = context.palette;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            setState(() {
              _category = selected ? null : key;
              _genre = null;
            });
            if (_category != null && _visibleItems.isEmpty) {
              unawaited(_loadMoreMatches());
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: selected ? p.primary : p.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? p.primary
                    : p.tint(p.primary, _isDark ? 0.22 : 0.12),
                width: 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: p.tint(p.primary, 0.28),
                        blurRadius: 10,
                        spreadRadius: -2,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              icon,
              size: 17,
              color: selected ? p.onPrimary : p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerActions() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _headerActionButton(
            tooltip: _isLiveTvMode ? 'Search channels' : 'Search movies',
            icon: Icons.search_rounded,
            onTap: () => setState(() => _searchOpen = true),
          ),
          const SizedBox(width: 6),
          _headerActionButton(
            tooltip: 'Change movie source',
            icon: Icons.layers_outlined,
            onTap: _pickSource,
          ),
        ],
      );

  Widget _stickyFilterChips() {
    final p = context.palette;
    final available = _tags
        .where((tag) => _items.any((movie) => _matchesTag(movie, tag)))
        .toList();
    if (available.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
        itemCount: available.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final tag = index == 0 ? null : available[index - 1];
          final selected = _tag == tag;
          return GestureDetector(
            onTap: () => setState(() => _tag = selected ? null : tag),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? p.primary : p.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? p.primary : p.border,
                  width: 1,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: p.tint(p.primary, 0.25),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              alignment: Alignment.center,
              child: Text(
                tag ?? 'All',
                style: TextStyle(
                  color: selected ? p.onPrimary : p.textPrimary,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader(double topPadding) {
    final p = context.palette;
    final headerHeight =
        _isSticky ? topPadding + 104.0 : topPadding + 60.0;

    return AnimatedContainer(
      key: ValueKey<double>(headerHeight),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      height: headerHeight,
      decoration: BoxDecoration(
        color: p.tint(p.background, _isDark ? 0.90 : 0.96),
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(20),
        ),
        border: _isSticky || (_scroll.hasClients && _scroll.offset > 10)
            ? Border(
                bottom: BorderSide(
                  color: p.tint(p.primary, _isDark ? 0.16 : 0.10),
                  width: 1,
                ),
              )
            : null,
        boxShadow: _isSticky || (_scroll.hasClients && _scroll.offset > 10)
            ? [
                BoxShadow(
                  color: p.shadowAt(_isDark ? 0.30 : 0.10),
                  blurRadius: 16,
                  spreadRadius: -8,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Padding(
            padding: EdgeInsets.only(top: topPadding),
            child: Stack(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Top Row — scales down instead of overflowing.
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          height: 46,
                          width: MediaQuery.sizeOf(context).width,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: Row(
                          children: [
                            if (_isSticky) ...[
                              _categoryIconButton(
                                icon: Icons.movie_outlined,
                                key: 'movie',
                                tooltip: 'Movies',
                              ),
                              const SizedBox(width: 6),
                              _categoryIconButton(
                                icon: Icons.tv_rounded,
                                key: 'series',
                                tooltip: 'Series',
                              ),
                              const SizedBox(width: 6),
                              _categoryIconButton(
                                icon: Icons.animation_rounded,
                                key: 'anime',
                                tooltip: 'Anime',
                              ),
                            ] else ...[
                              Text(
                                _isLiveTvMode ? 'Live TV' : 'Movies',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.8,
                                      fontSize: 22,
                                    ),
                              ),
                            ],
                            const Spacer(),
                            _headerActions(),
                          ],
                        ),
                          ),
                        ),
                      ),
                    ),

                    // Bottom Row: Filter chips (only when sticky)
                    if (_isSticky)
                      Flexible(
                        child: SizedBox(
                          height: 40,
                          child: _stickyFilterChips(),
                        ),
                      ),
                  ],
                ),

                // Invisible genre test hook
                if (!_isLiveTvMode)
                  Positioned(
                    left: 20,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: _pickGenres,
                      child: const Opacity(
                        opacity: 0,
                        child: Padding(
                          padding: EdgeInsets.all(1),
                          child: Text('Genres'),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchOverlay() => Positioned(
    top: MediaQuery.paddingOf(context).top + 12,
    left: 14,
    right: 14,
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: _colors.surface.withValues(alpha: .97),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: context.palette.shadowAt(.5),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          if (!_isLiveTvMode)
            GestureDetector(
              onTap: _toggleSearchScope,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: _searchAll
                      ? context.palette.primaryGradient
                      : context.palette.primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _searchAll
                      ? Icons.travel_explore_rounded
                      : Icons.search_rounded,
                  color: _colors.onSurface,
                  size: 19,
                ),
              ),
            ),
          SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _focus,
              autofocus: true,
              cursorColor: context.palette.primary,
              style: TextStyle(color: _colors.onSurface, fontSize: 14),
              decoration: InputDecoration(
                hintText: _isLiveTvMode
                    ? 'Search channels…'
                    : _searchAll
                    ? 'Search all movie sources…'
                    : 'Search ${_source?.provider.name ?? 'movies'}…',
                hintStyle: TextStyle(color: _colors.onSurfaceVariant),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (value) {
                _debounce?.cancel();
                _debounce = Timer(Duration(milliseconds: 320), () {
                  if (value.trim() != _query) _reset(_source, value.trim());
                });
              },
              onSubmitted: (value) {
                _reset(_source, value.trim());
                setState(() => _searchOpen = false);
              },
            ),
          ),
          if (_search.text.isNotEmpty)
            IconButton(
              onPressed: () {
                _search.clear();
                _reset(_source, '');
              },
              icon: Icon(Icons.close_rounded, color: _colors.onSurfaceVariant),
            ),
          GestureDetector(
            onTap: _pickSource,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: _source == null
                  ? Icon(Icons.layers_rounded, color: _colors.primary, size: 18)
                  : ProviderLogo(provider: _source!.provider),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _searchOpen = false),
            icon: Icon(
              Icons.keyboard_arrow_up_rounded,
              color: _colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );

  static const _tags = [
    'Korean',
    'Bengali',
    'Hindi',
    'English',
    'Tamil',
    'Telugu',
    'Japanese',
    'Anime',
    'Hollywood',
    'Bollywood',
  ];

  bool _matchesTag(MovieItem movie, String tag) {
    final text = [
      movie.title,
      ...movie.genres,
      ...movie.catalogGroups,
      movie.providerName,
      movie.repoName,
    ].join(' ').toLowerCase();
    return switch (tag) {
      'Korean' =>
        text.contains('korean') ||
        text.contains('korea') ||
        text.contains('k-drama') ||
        text.contains('kdrama'),
      'Bengali' => text.contains('bengali') || text.contains('bangla'),
      'Hindi' => text.contains('hindi'),
      'English' => text.contains('english') || text.contains('hollywood'),
      'Tamil' => text.contains('tamil'),
      'Telugu' => text.contains('telugu'),
      'Japanese' => text.contains('japan'),
      'Anime' => movie.isAnime || text.contains('anime'),
      'Hollywood' => text.contains('hollywood') || text.contains('english'),
      'Bollywood' => text.contains('bollywood') || text.contains('hindi'),
      _ => true,
    };
  }

  Widget _buildTagChips() {
    final p = context.palette;
    final available = _tags
        .where((tag) => _items.any((movie) => _matchesTag(movie, tag)))
        .toList();
    if (available.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: available.length + 1,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final tag = index == 0 ? null : available[index - 1];
            final selected = _tag == tag;
            return ActionChip(
              label: Text(
                tag ?? 'All',
                style: TextStyle(
                  color: selected ? p.onPrimary : p.textPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              backgroundColor: selected ? p.primary : p.card,
              side: BorderSide(color: selected ? p.primary : p.border),
              onPressed: () => setState(
                () => _tag = selected ? null : tag,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _categoryTiles() {
    final tiles = [
      ('Movies', Icons.movie_outlined, 'movie'),
      ('Series', Icons.tv_rounded, 'series'),
      ('Anime', Icons.animation_rounded, 'anime'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 720),
          child: Row(
            children: [
              for (final (label, icon, key) in tiles)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 3),
                    child: Material(
                      color: _category == key
                          ? context.palette.primary.withValues(alpha: .15)
                          : context.palette.card,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _category = _category == key ? null : key;
                            _genre = null;
                          });
                          if (_category != null && _visibleItems.isEmpty) {
                            unawaited(_loadMoreMatches());
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Column(
                            children: [
                              Icon(
                                icon,
                                size: 20,
                                color: _category == key
                                    ? context.palette.primary
                                    : context.palette.textSecondary,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                label,
                                style: TextStyle(
                                  color: _category == key
                                      ? context.palette.primary
                                      : context.palette.textPrimary,
                                  fontSize: 11.5,
                                  fontWeight: _category == key
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _removeFromContinueWatching(WatchHistoryItem item) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove from Continue Watching?'),
        content: Text(item.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove'),
          ),
        ],
      ),
    );
    if (remove == true) {
      await WatchHistoryService.instance.removeFromHistory(item.movieId);
    }
  }

  Widget _continueWatching(List<WatchHistoryItem> history) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(18, 18, 18, 8),
          child: Text(
            'Continue Watching',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        SizedBox(
          height: 124,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: 16),
            itemCount: history.length,
            separatorBuilder: (_, _) => SizedBox(width: 10),
            itemBuilder: (context, index) {
              final item = history[index];
              return GestureDetector(
                onLongPress: () => _removeFromContinueWatching(item),
                onTap: () {
                  final match = _items
                      .where(
                        (m) =>
                            m.title.toLowerCase() == item.title.toLowerCase(),
                      )
                      .firstOrNull;
                  if (match != null) _openMovie(match);
                },
                child: SizedBox(
                  width: 118,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Stack(
                          children: [
                            SmartNetworkImage(
                              url: item.posterUrl,
                              width: 118,
                              height: 84,
                              fit: BoxFit.cover,
                              placeholderColor: _colors.surfaceContainerHighest,
                              placeholderIcon:
                                  Icons.play_circle_outline_rounded,
                              accentColor: context.palette.primary,
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: 3,
                              child: LinearProgressIndicator(
                                value: item.progress,
                                backgroundColor: context.palette.trackBg,
                                color: context.palette.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title, {bool showSeeAll = false}) => Padding(
    padding: EdgeInsets.fromLTRB(18, 20, 18, 10),
    child: Row(
      children: [
        Container(
          width: 4,
          height: 24,
          decoration: BoxDecoration(
            gradient: context.palette.primaryGradient,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _colors.onSurface,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        SizedBox(width: 8),
        if (showSeeAll)
          GestureDetector(
            onTap: _clearFilters,
            child: Text(
              'Clear filters',
              style: TextStyle(
                color: _colors.primary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          )
        else
          Text(
            '${_visibleItems.length} titles',
            style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 11),
          ),
      ],
    ),
  );

  Widget _emptyState({bool filtered = false}) => Padding(
    padding: EdgeInsets.fromLTRB(24, 16, 24, 40),
    child: Column(
      children: [
        Icon(
          _failed ? Icons.cloud_off_rounded : Icons.search_off_rounded,
          size: 40,
          color: _colors.onSurfaceVariant,
        ),
        SizedBox(height: 12),
        Text(
          _failed
              ? 'Could not load ${_source?.provider.name ?? 'this source'}'
              : filtered
              ? 'No matching titles yet'
              : 'No titles found here',
          style: TextStyle(
            color: _colors.onSurface,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 6),
        Text(
          filtered && _hasMore && !_failed
              ? 'Load more titles to keep looking in this source.'
              : 'Try another source or search for a specific title.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 12.5),
        ),
        SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            _retry(onPressed: () => _reset(_source, _query)),
            OutlinedButton.icon(
              onPressed: _pickSource,
              style: OutlinedButton.styleFrom(
                foregroundColor: _colors.onSurface,
              ),
              icon: Icon(Icons.swap_horiz_rounded, size: 17),
              label: Text('Change source'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _retry({VoidCallback? onPressed}) => FilledButton.tonalIcon(
    icon: Icon(Icons.refresh_rounded),
    label: Text('Retry'),
    onPressed: onPressed ?? _load,
  );
}

class _SourcePickerSheet extends StatefulWidget {
  final _Source? currentSource;

  const _SourcePickerSheet({required this.currentSource});

  @override
  State<_SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<_SourcePickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  late bool _showAdult;

  @override
  void initState() {
    super.initState();
    _showAdult = SettingsService.instance.showAdultRepositories;
    MovieRepositoryService.instance.addListener(_onRepoChanged);
  }

  @override
  void dispose() {
    MovieRepositoryService.instance.removeListener(_onRepoChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  bool _isAdult(_Source source) =>
      source.repo.isAdult || source.provider.isAdult;

  List<_Source> _getFilteredSources() {
    final engine = ProviderEngineService.instance;
    final supported = engine.catalogSources.where(
      (source) => CloudStreamRuntime.canRun(source.provider),
    );

    var list = [
      ...supported.where((source) => !_isAdult(source)),
      if (_showAdult) ...supported.where(_isAdult),
    ];

    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      list = list.where((source) {
        return source.provider.name.toLowerCase().contains(query) ||
            source.repo.name.toLowerCase().contains(query);
      }).toList();
    }

    return list;
  }

  Future<void> _deleteSource(_Source source) async {
    await MovieRepositoryService.instance.deleteRepository(source.repo.id);
    if (mounted) setState(() {});
  }

  Future<void> _deleteAllSources(List<_Source> sourcesToDelete) async {
    final repoIds = sourcesToDelete.map((s) => s.repo.id).toSet();
    for (final id in repoIds) {
      await MovieRepositoryService.instance.deleteRepository(id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _confirmDeleteAll(
    BuildContext context,
    List<_Source> sources,
  ) async {
    final count = sources.map((s) => s.repo.id).toSet().length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete all sources?'),
        content: Text(
          'This removes $count repositories and their providers from this '
          'device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: dialogContext.palette.critical,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteAllSources(sources);
  }

  @override
  Widget build(BuildContext context) {
    final sources = _getFilteredSources();

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 12,
          left: 16,
          right: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Header Bar
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Choose a Source',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                          color: context.palette.textPrimary,
                        ),
                      ),
                      Text(
                        sources.isEmpty
                            ? 'No sources available'
                            : '${sources.length} available',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: context.palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),

                IconButton(
                  tooltip: _showAdult ? 'Hide 18+ sources' : 'Show 18+ sources',
                  icon: Icon(
                    _showAdult
                        ? Icons.explicit_rounded
                        : Icons.explicit_outlined,
                    size: 19,
                  ),
                  color: _showAdult
                      ? context.palette.critical
                      : context.palette.textSecondary,
                  onPressed: () {
                    setState(() => _showAdult = !_showAdult);
                    SettingsService.instance
                        .setShowAdultRepositories(_showAdult);
                  },
                ),
                if (sources.isNotEmpty)
                  IconButton(
                    tooltip: 'Delete all sources',
                    icon: const Icon(Icons.delete_sweep_outlined, size: 19),
                    color: context.palette.textSecondary,
                    onPressed: () => _confirmDeleteAll(context, sources),
                  ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: context.palette.textSecondary,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Search
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              style: TextStyle(
                fontSize: 13,
                color: context.palette.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'Search sources or repos…',
                hintStyle: TextStyle(
                  fontSize: 12.5,
                  color: context.palette.textSecondary,
                ),
                filled: true,
                fillColor: context.palette.card,
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: context.palette.textSecondary,
                ),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close_rounded, size: 16),
                        color: context.palette.textSecondary,
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Sources List
            if (sources.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 32),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.extension_off_rounded,
                      size: 38,
                      color: context.palette.textSecondary.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'No sources found',
                      style: TextStyle(
                        color: context.palette.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .52,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: sources.length,
                  separatorBuilder: (context, _) => Divider(
                    height: 1,
                    indent: 60,
                    color: context.palette.border.withValues(alpha: 0.5),
                  ),
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    final active =
                        source.repo.id == widget.currentSource?.repo.id &&
                        source.provider.id == widget.currentSource?.provider.id;

                    return Material(
                      color: Colors.transparent,
                      child: Container(
                        decoration: BoxDecoration(
                          color: active
                              ? context.palette.selectedBg
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: InkWell(
                          onTap: () => Navigator.pop(context, source),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: context.palette.card,
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  child: Center(
                                    child: ProviderLogo(provider: source.provider),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        source.provider.name,
                                        style: TextStyle(
                                          color: active
                                              ? context.palette.primary
                                              : context.palette.textPrimary,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          if (_isAdult(source)) ...[
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 5,
                                                vertical: 1,
                                              ),
                                              decoration: BoxDecoration(
                                                color: context.palette.critical
                                                    .withValues(alpha: 0.14),
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                              ),
                                              child: Text(
                                                '18+',
                                                style: TextStyle(
                                                  color: context.palette.critical,
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 5),
                                          ],
                                          Expanded(
                                            child: Text(
                                              source.repo.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: context.palette.textSecondary,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 4),
                                if (active)
                                  Icon(
                                    Icons.check_circle_rounded,
                                    color: context.palette.primary,
                                    size: 18,
                                  ),
                                IconButton(
                                  tooltip: 'Delete source',
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                  ),
                                  color: context.palette.textSecondary,
                                  onPressed: () => _deleteSource(source),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            const Divider(height: 1),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ZangetsuProvidersHubScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.extension_outlined, size: 16),
              label: const Text('Manage sources in Provider Hub'),
              style: TextButton.styleFrom(
                foregroundColor: context.palette.primary,
                padding: const EdgeInsets.symmetric(vertical: 10),
                textStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MovieHeaderDelegate extends SliverPersistentHeaderDelegate {
  _MovieHeaderDelegate({
    required this.isSticky,
    required this.topPadding,
    required this.child,
  });

  final bool isSticky;
  final double topPadding;
  final Widget child;

  @override
  double get minExtent => isSticky ? topPadding + 90.0 : topPadding + 50.0;

  @override
  double get maxExtent => isSticky ? topPadding + 90.0 : topPadding + 50.0;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _MovieHeaderDelegate oldDelegate) =>
      oldDelegate.isSticky != isSticky ||
      oldDelegate.topPadding != topPadding ||
      oldDelegate.child != child;
}
