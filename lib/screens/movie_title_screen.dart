import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../services/download_manager.dart';
import '../services/permission_service.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../services/provider_engine/provider_models.dart';
import '../theme/app_colors.dart';
import '../widgets/remote_image.dart';
import 'movie_player_screen.dart';

class MovieTitleScreen extends StatefulWidget {
  const MovieTitleScreen({super.key, required this.movie});

  final MovieItem movie;

  @override
  State<MovieTitleScreen> createState() => _MovieTitleScreenState();
}

class _MovieTitleScreenState extends State<MovieTitleScreen> {
  final _engine = ProviderEngineService.instance;
  final _episodeFormats = <ProviderEpisode, Future<List<MovieSource>>>{};
  final _expandedEpisodes = <ProviderEpisode, bool>{};
  late Future<List<ProviderEpisode>> _episodes = _engine.episodesFor(
    widget.movie,
  );
  Future<List<MovieSource>>? _movieFormats;
  bool _queuing = false;
  int _seasonIndex = 0;

  // ---------------------------------------------------------------------------
  // Theme helpers
  // ---------------------------------------------------------------------------
  bool get _dark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => _dark ? AppColors.primaryLight : AppColors.primaryDark;
  Color get _accentSoft => _accent.withValues(alpha: .12);
  Color get _secondaryText =>
      _dark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
  Color get _primaryText =>
      _dark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary;

  Future<List<MovieSource>> _formats([ProviderEpisode? episode]) => _engine
      .resolveStreams(widget.movie, episode: episode, keepAllFormats: true);

  String _episodeLabel(ProviderEpisode episode) {
    final number = episode.season == null
        ? 'Episode ${episode.number}'
        : 'Season ${episode.season} · Episode ${episode.number}';
    final name = episode.title.trim();
    return [
      number,
      if (name.isNotEmpty && name != 'Episode' && name != number) name,
      if (episode.group case final String group when group.isNotEmpty) group,
    ].join(' · ');
  }

  Future<void> _download(MovieSource source, ProviderEpisode? episode) async {
    if (_queuing) return;
    setState(() => _queuing = true);
    final permission = PermissionService.instance;
    try {
      if (!await permission.hasStoragePermission() &&
          !await permission.requestStoragePermission()) {
        if (mounted) {
          _message('Storage permission is required to save downloads.');
        }
        return;
      }
      if (!mounted) return;
      await DownloadManager.instance.startMovieDownload(
        movie: widget.movie,
        source: source,
        customTitle: episode == null
            ? widget.movie.title
            : '${widget.movie.title} - ${_episodeLabel(episode)}',
      );
      if (mounted) _message('Download queued');
    } catch (_) {
      if (mounted) _message('Could not start this download.');
    } finally {
      if (mounted) setState(() => _queuing = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  // ---------------------------------------------------------------------------
  // Surfaces
  // ---------------------------------------------------------------------------

  Widget _surface({
    required Widget child,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(18)),
    Color? color,
    List<BoxShadow>? shadows,
  }) {
    final palette = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: Material(
        color: color ?? palette.surfaceContainer,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Format list
  // ---------------------------------------------------------------------------

  Widget _actionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool highlighted = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(13),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: highlighted ? _accent : _accentSoft,
              borderRadius: BorderRadius.circular(13),
              boxShadow: highlighted
                  ? [
                      BoxShadow(
                        color: _accent.withValues(alpha: .30),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              icon,
              size: 19,
              color: highlighted
                  ? Colors.white
                  : (onPressed == null ? _secondaryText : _accent),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sourceRow(
    MovieSource source,
    String server,
    ProviderEpisode? episode,
    List<MovieSource> formats,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [_accentSoft, _accent.withValues(alpha: .05)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              source.resolution,
              style: theme.textTheme.labelLarge?.copyWith(
                color: _accent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.format.toUpperCase(),
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (source.fileSize.isNotEmpty)
                  Text(
                    source.fileSize,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _secondaryText,
                    ),
                  ),
              ],
            ),
          ),
          _actionButton(
            icon: Icons.play_arrow_rounded,
            tooltip: 'Play ${source.resolution} from $server',
            onPressed: () => _play(source, formats, episode),
          ),
          const SizedBox(width: 8),
          _actionButton(
            icon: Icons.download_rounded,
            tooltip: 'Download ${source.resolution} from $server',
            highlighted: true,
            onPressed: _queuing ? null : () => _download(source, episode),
          ),
        ],
      ),
    );
  }

  Widget _formatList(
    Future<List<MovieSource>> future,
    VoidCallback retry, {
    ProviderEpisode? episode,
  }) => FutureBuilder<List<MovieSource>>(
    future: future,
    builder: (context, snapshot) {
      final theme = Theme.of(context);
      if (snapshot.connectionState != ConnectionState.done) {
        return _surface(
          padding: const EdgeInsets.all(16),
          borderRadius: BorderRadius.circular(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 16, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Finding available sources…',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _secondaryText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  color: _accent,
                  backgroundColor: _accentSoft,
                ),
              ),
            ],
          ),
        );
      }
      final formats = snapshot.data ?? const <MovieSource>[];
      if (formats.isEmpty) {
        return _surface(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          borderRadius: BorderRadius.circular(18),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded, size: 20, color: _secondaryText),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  snapshot.hasError
                      ? 'Could not load formats.'
                      : 'No downloadable formats were found.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: _secondaryText,
                  ),
                ),
              ),
              TextButton(onPressed: retry, child: const Text('Retry')),
            ],
          ),
        );
      }
      final servers = <String, List<MovieSource>>{};
      for (final source in formats) {
        final name = source.serverName.trim();
        servers
            .putIfAbsent(name.isEmpty ? 'Available formats' : name, () => [])
            .add(source);
      }
      return Column(
        children: [
          for (final server in servers.entries) ...[
            _surface(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              borderRadius: BorderRadius.circular(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: _accentSoft,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Icon(
                          Icons.dns_rounded,
                          size: 17,
                          color: _accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          server.key,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: .2,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _accentSoft,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${server.value.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: _accent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Divider(
                      height: 1,
                      color: _accent.withValues(alpha: .12),
                    ),
                  ),
                  for (final source in server.value)
                    _sourceRow(source, server.key, episode, formats),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      );
    },
  );

  void _play(
    MovieSource source,
    List<MovieSource> formats,
    ProviderEpisode? episode,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MoviePlayerScreen(
          movie: widget.movie.copyWith(
            title: episode == null
                ? widget.movie.title
                : '${widget.movie.title} · ${_episodeLabel(episode)}',
            sources: formats,
          ),
          initialSource: source,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Hero + section headers
  // ---------------------------------------------------------------------------

  Widget _titleHeader(bool series) {
    final movie = widget.movie;
    final theme = Theme.of(context);
    final metadata = [
      series ? 'Series' : 'Movie',
      if (movie.year > 0) movie.year.toString(),
      if (movie.quality.trim().isNotEmpty) movie.quality,
    ];
    return _surface(
      borderRadius: BorderRadius.circular(24),
      shadows: [
        BoxShadow(
          color: Colors.black.withValues(alpha: _dark ? .27 : .12),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ],
      child: Stack(
        children: [
          Positioned.fill(
            child: SmartNetworkImage(
              url: movie.backdropUrl,
              fallbackUrl: movie.posterUrl,
              fit: BoxFit.cover,
              placeholderColor: const Color(0xFF321A22),
            ),
          ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x160E090B),
                    Color(0xAC160E12),
                    Color(0xFA100A0D),
                  ],
                  stops: [0, .48, 1],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 72, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SmartNetworkImage(
                  url: movie.posterUrl,
                  fallbackUrl: movie.backdropUrl,
                  width: 74,
                  height: 108,
                  fit: BoxFit.cover,
                  borderRadius: BorderRadius.circular(12),
                  fallbackInitials: SmartNetworkImage.initialsFor(movie.title),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        metadata.join(' · '),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: const Color(0xFFFFBDCB),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        movie.title,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          height: 1.12,
                        ),
                      ),
                      if (movie.providerName.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          movie.providerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String label, {int? count}) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (count != null)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              count == 1 ? '1 episode' : '$count episodes',
              style: theme.textTheme.labelMedium?.copyWith(
                color: _secondaryText,
              ),
            ),
          ),
      ],
    );
  }

  Widget _episodeCard(ProviderEpisode episode) {
    final theme = Theme.of(context);
    final expanded = _expandedEpisodes[episode] ?? false;
    final title = episode.title.trim().isEmpty || episode.title == 'Episode'
        ? 'Episode ${episode.number}'
        : episode.title;
    return _surface(
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(22),
      child: ExpansionTile(
        key: ObjectKey(episode),
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: _accent,
        collapsedIconColor: _secondaryText,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        initiallyExpanded: expanded,
        onExpansionChanged: (value) {
          setState(() => _expandedEpisodes[episode] = value);
          if (value && !_episodeFormats.containsKey(episode)) {
            setState(() {
              _episodeFormats[episode] = _formats(episode);
            });
          }
        },
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _accentSoft,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Center(
            child: Text(
              '${episode.number}',
              style: theme.textTheme.labelLarge?.copyWith(
                color: _accent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        title: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -.2,
          ),
        ),
        subtitle: (episode.group == null || episode.group!.trim().isEmpty)
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.subtitles_rounded,
                      size: 12,
                      color: _secondaryText,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        episode.group!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _secondaryText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        trailing: AnimatedRotation(
          turns: expanded ? .5 : 0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: _surface(
            padding: const EdgeInsets.all(8),
            borderRadius: BorderRadius.circular(12),
            color: _accentSoft,
            shadows: const [],
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: _accent,
            ),
          ),
        ),
        children: [
          if (_episodeFormats[episode] case final future?)
            _formatList(
              future,
              () => setState(() {
                _episodeFormats[episode] = _formats(episode);
              }),
              episode: episode,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _dark ? AppColors.darkBg : AppColors.lightBg,
    appBar: AppBar(
      title: Text(widget.movie.isSeries ? 'Series details' : 'Movie details'),
      backgroundColor: _dark ? AppColors.darkBg : AppColors.lightBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    body: SafeArea(
      top: false,
      child: FutureBuilder<List<ProviderEpisode>>(
        future: _episodes,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: _surface(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi_off_rounded, size: 30, color: _accent),
                    const SizedBox(height: 12),
                    Text(
                      'Could not load title details',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: () => setState(() {
                        _seasonIndex = 0;
                        _episodes = _engine.episodesFor(widget.movie);
                      }),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          final episodes = snapshot.data!;
          final seasons = <int?, List<ProviderEpisode>>{};
          for (final episode in episodes) {
            seasons.putIfAbsent(episode.season, () => []).add(episode);
          }
          final seasonNumbers = seasons.keys.toList();
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _titleHeader(widget.movie.isSeries || episodes.isNotEmpty),
                  const SizedBox(height: 22),
                  _sectionHeader(
                    episodes.isEmpty ? 'Available formats' : 'Episodes',
                    count: episodes.isEmpty ? null : episodes.length,
                  ),
                  const SizedBox(height: 10),
                  if (seasonNumbers.length > 1) ...[
                    SizedBox(
                      height: 48,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: seasonNumbers.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (_, index) {
                          final selected = index == _seasonIndex;
                          return _surface(
                            shadows: selected
                                ? [
                                    BoxShadow(
                                      color: _accent.withValues(alpha: .28),
                                      blurRadius: 14,
                                      offset: const Offset(0, 5),
                                    ),
                                  ]
                                : const [],
                            borderRadius: BorderRadius.circular(30),
                            color: selected
                                ? _accent
                                : (_dark
                                      ? const Color(0x14FFFFFF)
                                      : const Color(0x8CFFFFFF)),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () =>
                                    setState(() => _seasonIndex = index),
                                borderRadius: BorderRadius.circular(30),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 8,
                                  ),
                                  child: Center(
                                    child: Text(
                                      seasonNumbers[index] == null
                                          ? 'Other episodes'
                                          : 'Season ${seasonNumbers[index]}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(
                                            color: selected
                                                ? Colors.white
                                                : _primaryText,
                                            fontWeight: selected
                                                ? FontWeight.w800
                                                : FontWeight.w600,
                                          ),
                                    ),
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
                  if (episodes.isEmpty)
                    _formatList(
                      _movieFormats ??= _formats(),
                      () => setState(() {
                        _movieFormats = _formats();
                      }),
                    )
                  else
                    for (final episode in seasons[seasonNumbers[_seasonIndex]]!)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _episodeCard(episode),
                      ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}
