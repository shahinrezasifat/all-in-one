import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../models/live_tv_groups.dart';
import '../services/movie_repository_service.dart';
import '../services/provider_engine/cloudstream_runtime.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../services/settings_service.dart';
import '../services/watch_history_service.dart';
import '../theme/app_colors.dart';
import '../widgets/home_banner.dart';
import '../widgets/looping_control_content.dart';
import '../widgets/movie_card.dart';
import '../widgets/remote_image.dart';
import 'movie_player_screen.dart';
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
  bool _loadingGenres = false;
  final _genreLookups = <String>{};
  ColorScheme get _colors => Theme.of(context).colorScheme;
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

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
    if (mounted) setState(() {});
  }

  bool _isAdult(_Source source) =>
      source.repo.isAdult || source.provider.isAdult;

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
        _channelCountry = null;
        _channelLanguage = null;
      }
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
        title: const Text('Choose source type'),
        content: Text(
          'Open ${source.provider.name} as a movie catalog or as IPTV channels?',
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(dialogContext, _SourceMode.movies),
            icon: const Icon(Icons.movie_outlined),
            label: const Text('Movies'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, _SourceMode.iptv),
            icon: const Icon(Icons.live_tv_outlined),
            label: const Text('IPTV'),
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
          builder: (_) => MoviePlayerScreen(
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
    final uri = Uri.tryParse(channel.detailUrl);
    final path = uri?.path.toLowerCase() ?? '';
    final extension = path.split('.').last;
    const formats = ['m3u8', 'mpd', 'ts'];
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
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _source?.provider.name ?? '',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 3),
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
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
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
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Center(
            child: _loading
                ? const CircularProgressIndicator()
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
                          child: const Text('Load more channels'),
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
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(heading, style: Theme.of(context).textTheme.labelLarge),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                for (final label in <String?>[null, ...values])
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
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
                  color: _isDark ? AppColors.darkCard : AppColors.lightCard,
                  child: Padding(
                    padding: const EdgeInsets.all(13),
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
            const SizedBox(height: 5),
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
      MaterialPageRoute(builder: (_) => const ZangetsuProvidersHubScreen()),
    );
  }

  Future<void> _pickSource() async {
    final sources = _movieSources.toList();
    final selected = await showModalBottomSheet<_Source>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Choose a source',
                        style: TextStyle(
                          color: _colors.onSurface,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close_rounded, color: _colors.onSurface),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Movies and the home banner follow the source you pick.',
                  style: TextStyle(
                    color: _colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                if (sources.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Install a source in Provider Hub.',
                      style: TextStyle(color: _colors.onSurface),
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
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final source = sources[index];
                        final active =
                            source.repo.id == _source?.repo.id &&
                            source.provider.id == _source?.provider.id;
                        return Material(
                          color: active
                              ? AppColors.primary.withValues(alpha: .18)
                              : _colors.surfaceContainerHigh,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            leading: ProviderLogo(provider: source.provider),
                            title: Text(
                              source.provider.name,
                              style: TextStyle(
                                color: active
                                    ? _colors.primary
                                    : _colors.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              _isAdult(source)
                                  ? '18+ · ${source.repo.name}'
                                  : source.repo.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: _colors.onSurfaceVariant),
                            ),
                            trailing: active
                                ? Icon(
                                    Icons.check_circle_rounded,
                                    color: _colors.primary,
                                  )
                                : Icon(
                                    Icons.chevron_right_rounded,
                                    color: _colors.onSurfaceVariant,
                                  ),
                            onTap: () => Navigator.pop(context, source),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _openProviderHub();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _colors.onSurface,
                  ),
                  icon: const Icon(Icons.extension_outlined, size: 18),
                  label: const Text('Manage sources in Provider Hub'),
                ),
              ],
            ),
          ),
        );
      },
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
        if (mounted && _query.isNotEmpty) _reset(source, '');
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
          return MapEntry(movie.detailUrl, const <String>[]);
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
      builder: (context) => _genreSheet(
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
    final secondary = _isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
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
                    ? const Color(0xE61E1928)
                    : const Color(0xE8FFFFFF),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: _isDark
                      ? const Color(0x2AFFFFFF)
                      : const Color(0x99FFFFFF),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: _isDark ? .5 : .18),
                    blurRadius: 40,
                    spreadRadius: -10,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: _isDark
                              ? Colors.white.withValues(alpha: .26)
                              : Colors.black.withValues(alpha: .18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
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
                        const SizedBox(width: 12),
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
                              const SizedBox(height: 2),
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
                          icon: const Icon(Icons.close_rounded),
                          style: IconButton.styleFrom(
                            backgroundColor: accent.withValues(alpha: .09),
                            foregroundColor: secondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    if (canDiscover)
                      _genreActionCard(
                        icon: Icons.auto_awesome_rounded,
                        title: 'Find more genres',
                        subtitle: 'Scan titles for extra tags',
                        accent: accent,
                        secondary: secondary,
                        onTap: () => Navigator.pop(context, '?'),
                      ),
                    if (canDiscover) const SizedBox(height: 12),
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
                      const SizedBox(height: 12),
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
                      const SizedBox(height: 4),
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                child: Icon(icon, size: 17, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isDark
            ? Colors.white.withValues(alpha: .05)
            : Colors.white.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: .14)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: accent),
          const SizedBox(width: 12),
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
        ? Colors.white
        : (_isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected
            ? accent
            : (_isDark
                  ? Colors.white.withValues(alpha: .06)
                  : Colors.white.withValues(alpha: .82)),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? accent : accent.withValues(alpha: .20),
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: .32),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(Icons.check_rounded, size: 14, color: text),
                  const SizedBox(width: 6),
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

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final bannerMovies = _isLiveTvMode ? const <MovieItem>[] : _bannerMovies();
    final history = WatchHistoryService.instance.history;
    final visible = _visibleItems;
    final filtered = _category != null || _genre != null;

    return Scaffold(
      backgroundColor: _isDark ? AppColors.darkBg : AppColors.lightBg,
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
          CustomScrollView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(child: _movieHeader()),
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
                SliverToBoxAdapter(child: _categoryTiles()),
                if (history.isNotEmpty)
                  SliverToBoxAdapter(child: _continueWatching(history)),
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
                  SliverToBoxAdapter(child: _emptyState(filtered: filtered)),
                if (visible.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 150,
                            childAspectRatio: .62,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 14,
                          ),
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
                                onPressed: filtered ? _loadMoreMatches : _load,
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
                child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
              ),
            ],
          ),
          if (_searchOpen) _searchOverlay(),
        ],
      ),
    );
  }

  Widget _movieHeader() => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _isLiveTvMode ? 'Live TV' : 'Movies',
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
            ),
          ),
          IconButton(
            tooltip: _isLiveTvMode ? 'Search channels' : 'Search movies',
            iconSize: 16,
            color: _isDark ? AppColors.primaryLight : AppColors.primaryDark,
            icon: const Icon(Icons.search_rounded),
            onPressed: () => setState(() => _searchOpen = true),
          ),
          IconButton(
            tooltip: 'Change movie source',
            iconSize: 16,
            color: _isDark ? AppColors.primaryLight : AppColors.primaryDark,
            icon: const Icon(Icons.layers_outlined),
            onPressed: _pickSource,
          ),
        ],
      ),
    ),
  );

  Widget _searchOverlay() => Positioned(
    top: MediaQuery.paddingOf(context).top + 12,
    left: 14,
    right: 14,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: _colors.surface.withValues(alpha: .97),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .5),
            blurRadius: 24,
            offset: const Offset(0, 10),
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
                      ? AppColors.primaryGradient
                      : AppColors.crimsonGradient,
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
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _focus,
              autofocus: true,
              cursorColor: AppColors.primaryLight,
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
                _debounce = Timer(const Duration(milliseconds: 320), () {
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

  Widget _categoryTiles() {
    final tiles = [
      ('Movies', Icons.movie_outlined, 'movie'),
      ('Series', Icons.tv_rounded, 'series'),
      ('Anime', Icons.animation_rounded, 'anime'),
      ('Genres', Icons.category_outlined, 'genres'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Row(
            children: [
              for (final (label, icon, key) in tiles)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Material(
                      color:
                          _category == key ||
                              (key == 'genres' && _genre != null)
                          ? _colors.primary.withValues(alpha: .15)
                          : (_isDark ? AppColors.darkCard : Colors.white),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          if (key == 'genres') {
                            _pickGenres();
                          } else {
                            setState(() {
                              _category = _category == key ? null : key;
                              _genre = null;
                            });
                            if (_category != null && _visibleItems.isEmpty) {
                              unawaited(_loadMoreMatches());
                            }
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          child: LoopingControlContent(
                            interval: const Duration(seconds: 10),
                            delay: Duration(
                              milliseconds:
                                  900 *
                                  tiles.indexWhere((tile) => tile.$3 == key),
                            ),
                            child: Column(
                              children: [
                                if (key == 'genres' && _loadingGenres)
                                  const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                else
                                  Icon(icon, size: 20, color: _colors.primary),
                                const SizedBox(height: 4),
                                Text(
                                  label,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium,
                                ),
                              ],
                            ),
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
        title: const Text('Remove from Continue Watching?'),
        content: Text(item.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
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
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
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
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: history.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
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
                              accentColor: AppColors.primaryLight,
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: 3,
                              child: LinearProgressIndicator(
                                value: item.progress,
                                backgroundColor: Colors.white30,
                                color: AppColors.accentRed,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 5),
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
    padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
    child: Row(
      children: [
        Container(
          width: 4,
          height: 24,
          decoration: BoxDecoration(
            gradient: AppColors.primaryGradient,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 10),
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
        const SizedBox(width: 8),
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
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
    child: Column(
      children: [
        Icon(
          _failed ? Icons.cloud_off_rounded : Icons.search_off_rounded,
          size: 40,
          color: _colors.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
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
        const SizedBox(height: 6),
        Text(
          filtered && _hasMore && !_failed
              ? 'Load more titles to keep looking in this source.'
              : 'Try another source or search for a specific title.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _colors.onSurfaceVariant, fontSize: 12.5),
        ),
        const SizedBox(height: 14),
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
              icon: const Icon(Icons.swap_horiz_rounded, size: 17),
              label: const Text('Change source'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _retry({VoidCallback? onPressed}) => FilledButton.tonalIcon(
    icon: const Icon(Icons.refresh_rounded),
    label: const Text('Retry'),
    onPressed: onPressed ?? _load,
  );
}
