import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../models/movie_source_language.dart';
import '../services/download_manager.dart';
import '../services/permission_service.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../services/provider_engine/provider_models.dart';
import '../theme/app_palette.dart';
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
  late Future<List<ProviderEpisode>> _episodes;
  Future<List<MovieSource>>? _movieFormats;
  List<MovieSource> _discoveredMovieFormats = [];
  int _formatRequest = 0;
  final _selectedLanguages = <ProviderEpisode?, String>{};

  @override
  void initState() {
    super.initState();
    _episodes = widget.movie.isSeries
        ? _engine.episodesFor(widget.movie)
        : Future.value([]);
    if (!widget.movie.isSeries) _movieFormats = _loadMovieFormats();
  }

  Future<List<MovieSource>> _loadMovieFormats() async {
    final request = ++_formatRequest;
    _discoveredMovieFormats = [];
    final seen = <(String, String, String)>{};
    final pending = Queue<MovieSource>();
    var running = 0;

    void publish(List<MovieSource> formats) {
      if (!mounted || request != _formatRequest || formats.isEmpty) return;
      setState(() {
        _discoveredMovieFormats = [..._discoveredMovieFormats, ...formats];
      });
    }

    Future<void> checkManifests() async {
      running++;
      try {
        while (mounted && request == _formatRequest && pending.isNotEmpty) {
          final formats = await _engine.adaptiveMovieFormats(
            pending.removeFirst(),
          );
          publish(formats);
        }
      } finally {
        running--;
      }
    }

    void inspect(List<MovieSource> formats) {
      if (!mounted || request != _formatRequest) return;
      for (final source in formats) {
        if (source.format.toLowerCase() == 'm3u8' &&
            source.streamUrl.isNotEmpty &&
            seen.add((
              source.streamUrl,
              source.serverName,
              source.providerId,
            ))) {
          pending.add(source);
        }
      }
      while (running < 3 && pending.isNotEmpty) {
        unawaited(checkManifests());
      }
    }

    inspect(widget.movie.sources);
    final formats = await _engine.resolveStreams(
      widget.movie,
      keepAllFormats: true,
      onFormats: (formats) {
        publish(formats);
        inspect(formats);
      },
    );
    inspect(formats);
    return formats;
  }

  bool _queuing = false;
  int _seasonIndex = 0;

  // ---------------------------------------------------------------------------
  // Theme helpers
  // ---------------------------------------------------------------------------
  bool get _dark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => _dark ? context.palette.primary : context.palette.primary;
  Color get _accentSoft => _accent.withValues(alpha: .12);
  Color get _secondaryText =>
      _dark ? context.palette.textSecondary : context.palette.textSecondary;
  Color get _primaryText =>
      _dark ? context.palette.textPrimary : context.palette.textPrimary;

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
        seasonNumber: episode?.season,
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

  Future<Map<String, Map<String, List<MovieSource>>>> _seasonOptions(
    List<ProviderEpisode> episodes,
  ) async {
    final results = List<List<MovieSource>>.filled(episodes.length, []);
    var next = 0;
    Future<void> resolveEpisodes() async {
      while (mounted && next < episodes.length) {
        final index = next++;
        results[index] = await _engine.episodeDownloadFormats(
          widget.movie,
          episodes[index],
        );
      }
    }

    await Future.wait(
      List.generate(episodes.length.clamp(1, 4), (_) {
        return resolveEpisodes();
      }),
    );
    final byEpisode = [
      for (final formats in results)
        <String, Map<String, MovieSource>>{
          for (final language
              in formats.expand(movieSourceLanguageKeys).toSet())
            language: {
              for (final source in formats.reversed)
                if (movieSourceLanguageKeys(source).contains(language))
                  episodeDownloadResolution(source): source,
            },
        },
    ];
    if (byEpisode.isEmpty) return {};
    int height(String label) => int.tryParse(label.replaceAll('p', '')) ?? 0;
    final options = <String, Map<String, List<MovieSource>>>{};
    for (final language in byEpisode.first.keys) {
      if (!byEpisode.every((sources) => sources.containsKey(language)))
        continue;
      final perEpisode = [for (final sources in byEpisode) sources[language]!];
      final common =
          perEpisode.first.keys
              .where(
                (quality) =>
                    quality != 'Auto' &&
                    perEpisode.every((sources) => sources.containsKey(quality)),
              )
              .toList()
            ..sort((a, b) => height(b).compareTo(height(a)));
      options[language] = common.isNotEmpty
          ? {
              for (final quality in common)
                quality: [for (final sources in perEpisode) sources[quality]!],
            }
          : {
              'Auto': [
                for (final sources in perEpisode)
                  sources[sources.keys.reduce(
                    (a, b) => height(a) >= height(b) ? a : b,
                  )]!,
              ],
            };
    }
    return options;
  }

  Future<void> _downloadSeason(
    String seasonName,
    List<ProviderEpisode> episodes,
  ) async {
    if (_queuing || episodes.isEmpty) return;
    var options = _seasonOptions(episodes);
    String? selectedLanguage;
    final choice =
        await showModalBottomSheet<
          ({String language, String resolution, List<MovieSource> sources})
        >(
          context: context,
          backgroundColor: Colors.transparent,
          elevation: 0,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (sheetContext) {
            final sheetTheme = Theme.of(sheetContext);
            final sheetDark = sheetTheme.brightness == Brightness.dark;
            final sheetSurface = sheetDark ? context.palette.card : context.palette.card;
            final sheetBorder = sheetDark
                ? context.palette.border
                : context.palette.border;
            final accent = sheetDark
                ? context.palette.primary
                : context.palette.primary;
            final secondary = sheetDark
                ? context.palette.textSecondary
                : context.palette.textSecondary;
            final soft = sheetDark
                ? context.palette.tint(context.palette.card, .04)
                : context.palette.background;

            return FractionallySizedBox(
              heightFactor: .68,
              child: Container(
                decoration: BoxDecoration(
                  color: sheetSurface,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: context.palette.shadowAt(sheetDark ? .45 : .14,),
                      blurRadius: 28,
                      spreadRadius: -8,
                      offset: Offset(0, -6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  child: StatefulBuilder(
                    builder: (context, update) {
                      Widget chip(String label) => Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: accent.withValues(alpha: .18),
                          ),
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            color: accent,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );

                      Widget optionTile({
                        required IconData icon,
                        required String title,
                        String? subtitle,
                        required VoidCallback onTap,
                        Widget? trailing,
                      }) {
                        return Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: onTap,
                              borderRadius: BorderRadius.circular(16),
                              splashColor: accent.withValues(alpha: .10),
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 11,
                                ),
                                decoration: BoxDecoration(
                                  color: soft,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: sheetBorder),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 42,
                                      height: 42,
                                      decoration: BoxDecoration(
                                        color: accent.withValues(alpha: .14),
                                        borderRadius: BorderRadius.circular(13),
                                      ),
                                      child: Icon(
                                        icon,
                                        color: accent,
                                        size: 20,
                                      ),
                                    ),
                                    SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            title,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: sheetDark
                                                  ? context.palette.card
                                                  : context.palette.textPrimary,
                                            ),
                                          ),
                                          if (subtitle != null) ...[
                                            SizedBox(height: 2),
                                            Text(
                                              subtitle,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                color: secondary,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    trailing ??
                                        Container(
                                          width: 28,
                                          height: 28,
                                          decoration: BoxDecoration(
                                            color: accent.withValues(
                                              alpha: .10,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              9,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.chevron_right_rounded,
                                            size: 18,
                                            color: accent,
                                          ),
                                        ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }

                      return FutureBuilder(
                        future: options,
                        builder: (_, snapshot) {
                          final data = snapshot.data;
                          final language = selectedLanguage;
                          final choosingLanguage = language == null;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: Container(
                                  width: 40,
                                  height: 4,
                                  margin: EdgeInsets.only(top: 10),
                                  decoration: BoxDecoration(
                                    color: secondary.withValues(alpha: .35),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  20,
                                  16,
                                  20,
                                  12,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!choosingLanguage)
                                      Padding(
                                        padding: EdgeInsets.only(
                                          right: 12,
                                        ),
                                        child: Container(
                                          width: 38,
                                          height: 38,
                                          decoration: BoxDecoration(
                                            color: accent.withValues(
                                              alpha: .12,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: IconButton(
                                            tooltip: 'Choose another language',
                                            icon: Icon(
                                              Icons.arrow_back_rounded,
                                              size: 19,
                                              color: accent,
                                            ),
                                            onPressed: () => update(
                                              () => selectedLanguage = null,
                                            ),
                                          ),
                                        ),
                                      ),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            choosingLanguage
                                                ? 'Choose language'
                                                : 'Choose resolution',
                                            style: sheetTheme
                                                .textTheme
                                                .titleLarge
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: -.4,
                                                ),
                                          ),
                                          SizedBox(height: 8),
                                          Wrap(
                                            spacing: 6,
                                            runSpacing: 6,
                                            children: [
                                              chip(seasonName),
                                              chip(
                                                '${episodes.length} episodes',
                                              ),
                                              if (!choosingLanguage)
                                                chip(
                                                  movieSourceLanguageLabels[language]!,
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (choosingLanguage)
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          gradient: context.palette.primaryGradient,
                                          borderRadius: BorderRadius.circular(
                                            15,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: context.palette.primary
                                                  .withValues(alpha: .28),
                                              blurRadius: 12,
                                              offset: Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: Icon(
                                          Icons.language_rounded,
                                          color: context.palette.onPrimary,
                                          size: 22,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Container(
                                        height: 4,
                                        decoration: BoxDecoration(
                                          gradient: context.palette.primaryGradient,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: 5),
                                    Expanded(
                                      child: Container(
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: choosingLanguage
                                              ? sheetBorder
                                              : context.palette.primary,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: 10),
                                    Text(
                                      choosingLanguage ? '1 / 2' : '2 / 2',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: secondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: 12),
                              Divider(height: 1, color: sheetBorder),
                              Expanded(
                                child:
                                    snapshot.connectionState !=
                                        ConnectionState.done
                                    ? Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            CircularProgressIndicator(
                                              color: context.palette.primary,
                                            ),
                                            SizedBox(height: 14),
                                            Text(
                                              'Checking formats for every episode…',
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                color: secondary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : data == null || data.isEmpty
                                    ? Center(
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 28,
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.cloud_off_rounded,
                                                size: 38,
                                                color: secondary,
                                              ),
                                              SizedBox(height: 12),
                                              Text(
                                                snapshot.hasError
                                                    ? 'Could not check formats for all episodes.'
                                                    : 'No language is available for every episode in this season.',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: secondary,
                                                ),
                                              ),
                                              SizedBox(height: 14),
                                              FilledButton.icon(
                                                onPressed: () => update(() {
                                                  options = _seasonOptions(
                                                    episodes,
                                                  );
                                                }),
                                                icon: Icon(
                                                  Icons.refresh_rounded,
                                                  size: 16,
                                                ),
                                                label: Text('Try again'),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: EdgeInsets.fromLTRB(
                                          20,
                                          14,
                                          20,
                                          20,
                                        ),
                                        itemCount: choosingLanguage
                                            ? [
                                                if (data.containsKey('hi'))
                                                  'hi',
                                                ...data.keys.where(
                                                  (k) => k != 'hi',
                                                ),
                                              ].length
                                            : data[language]!.length,
                                        itemBuilder: (_, index) {
                                          if (choosingLanguage) {
                                            final keys = [
                                              if (data.containsKey('hi')) 'hi',
                                              ...data.keys.where(
                                                (k) => k != 'hi',
                                              ),
                                            ];
                                            final key = keys[index];
                                            return optionTile(
                                              icon: Icons.language_rounded,
                                              title:
                                                  movieSourceLanguageLabels[key]!,
                                              subtitle:
                                                  '${data[key]!.length} qualities available',
                                              onTap: () => update(
                                                () => selectedLanguage = key,
                                              ),
                                            );
                                          }
                                          final entry = data[language]!.entries
                                              .elementAt(index);
                                          return optionTile(
                                            icon: Icons.download_rounded,
                                            title: entry.key == 'Auto'
                                                ? 'Automatic quality'
                                                : entry.key,
                                            subtitle: entry.key == 'Auto'
                                                ? 'Quality varies by episode'
                                                : '${entry.value.length} episode sources',
                                            trailing: Container(
                                              padding:
                                                  EdgeInsets.symmetric(
                                                    horizontal: 9,
                                                    vertical: 5,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: accent.withValues(
                                                  alpha: .10,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Icon(
                                                Icons.download_rounded,
                                                size: 15,
                                                color: accent,
                                              ),
                                            ),
                                            onTap: () =>
                                                Navigator.pop(sheetContext, (
                                                  language: language,
                                                  resolution: entry.key,
                                                  sources: entry.value,
                                                )),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
    if (!mounted || choice == null || _queuing) return;
    setState(() => _queuing = true);
    final permission = PermissionService.instance;
    try {
      if (!await permission.hasStoragePermission() &&
          !await permission.requestStoragePermission()) {
        if (mounted)
          _message('Storage permission is required to save downloads.');
        return;
      }
      await DownloadManager.instance.startSeasonDownload(
        series: widget.movie,
        seasonName: seasonName,
        language: choice.language,
        resolution: choice.resolution,
        episodes: [
          for (var i = 0; i < episodes.length; i++)
            (episode: episodes[i], source: choice.sources[i]),
        ],
      );
      if (mounted) _message('${episodes.length} episodes added to Downloads');
    } catch (_) {
      if (mounted) _message('Could not queue this season.');
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
            duration: Duration(milliseconds: 200),
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
                        offset: Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              icon,
              size: 19,
              color: highlighted
                  ? context.palette.card
                  : (onPressed == null ? _secondaryText : _accent),
            ),
          ),
        ),
      ),
    );
  }

  String _sourceName(MovieSource source) {
    final name = source.serverName.trim();
    return name.isEmpty ? 'Source' : name;
  }

  String _quality(MovieSource source) {
    final normalized = providerResolution(source.resolution);
    return normalized == 'Auto' ? source.resolution.trim() : normalized;
  }

  Widget _sourceRow(
    String quality,
    List<MovieSource> sources,
    ProviderEpisode? episode,
    List<MovieSource> formats,
  ) {
    final theme = Theme.of(context);
    final primary = sources.first;
    final downloadable = sources
        .where((source) => source.downloadUrl.isNotEmpty)
        .firstOrNull;
    final containers = sources
        .map((source) => source.format.toUpperCase())
        .toSet();
    final alternatives = sources.length > 1;
    final size = downloadable?.fileSize.trim();
    final subtitle = [
      containers.join(' / '),
      if (alternatives)
        '${sources.length} sources'
      else if (size != null && size.isNotEmpty)
        size,
    ].join(' · ');
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: alternatives
                  ? () => _showFormatSources(quality, sources, episode, formats)
                  : null,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: _accentSoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        quality == '2160p' ? '4K' : quality,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: _accent,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _secondaryText,
                        ),
                      ),
                    ),
                    if (alternatives)
                      Icon(
                        Icons.expand_more_rounded,
                        size: 18,
                        color: _secondaryText,
                      ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(width: 8),
          _actionButton(
            icon: Icons.play_arrow_rounded,
            tooltip: 'Play ${primary.resolution} from ${_sourceName(primary)}',
            highlighted: true,
            onPressed: () => _play(primary, formats, episode),
          ),
          SizedBox(width: 6),
          _actionButton(
            icon: Icons.download_rounded,
            tooltip: downloadable == null
                ? 'Download the original stream from its source row'
                : 'Download ${downloadable.resolution} from ${_sourceName(downloadable)}',
            onPressed: _queuing || downloadable == null
                ? null
                : () => _download(downloadable, episode),
          ),
        ],
      ),
    );
  }

  void _showFormatSources(
    String quality,
    List<MovieSource> sources,
    ProviderEpisode? episode,
    List<MovieSource> formats,
  ) {
    final nameCounts = <String, int>{};
    for (final source in sources) {
      final name = _sourceName(source);
      nameCounts.update(name, (count) => count + 1, ifAbsent: () => 1);
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * .65,
          ),
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            shrinkWrap: true,
            children: [
              ListTile(title: Text('$quality sources')),
              for (final (index, source) in sources.indexed)
                ListTile(
                  title: Text(
                    nameCounts[_sourceName(source)] == 1
                        ? _sourceName(source)
                        : '${_sourceName(source)} · Link ${index + 1}',
                  ),
                  subtitle: Text(
                    [
                      source.format.toUpperCase(),
                      if (_quality(source).toLowerCase() == 'auto' ||
                          _quality(source).isEmpty)
                        'Resolution not reported'
                      else if (source.hlsVariantResolution
                          case final dimensions?)
                        dimensions.replaceFirst('x', ' × ')
                      else
                        _quality(source),
                      if (source.fileSize.isNotEmpty) source.fileSize,
                    ].join(' · '),
                  ),
                  leading: Icon(Icons.play_arrow_rounded),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _play(source, formats, episode);
                  },
                  trailing: source.downloadUrl.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Download from ${_sourceName(source)}',
                          icon: Icon(Icons.download_rounded),
                          onPressed: _queuing
                              ? null
                              : () {
                                  Navigator.of(sheet).pop();
                                  _download(source, episode);
                                },
                        ),
                ),
            ],
          ),
        ),
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
      final waiting = snapshot.connectionState != ConnectionState.done;
      final discovered = [
        if (episode == null) ...widget.movie.sources,
        if (episode == null) ..._discoveredMovieFormats,
        ...?snapshot.data,
      ];
      (String, String, String) manifest(MovieSource source) =>
          (source.streamUrl, source.serverName, source.providerId);
      final expandedManifests = {
        for (final source in discovered)
          if (source.hlsVariantResolution != null) manifest(source),
      };
      final formats = {
        for (final source in discovered)
          if (source.hlsVariantResolution != null ||
              !expandedManifests.contains(manifest(source)) ||
              (source.downloadUrl.isNotEmpty &&
                  source.downloadUrl != source.streamUrl))
            if (source.streamUrl.isNotEmpty || source.downloadUrl.isNotEmpty)
              (
                source.resolution.toLowerCase(),
                source.hlsVariantResolution,
                source.downloadUrl,
                source.format,
                source.serverName,
                source.streamUrl.isNotEmpty
                    ? source.streamUrl
                    : source.downloadUrl,
              ): source,
      }.values.toList();
      if (waiting && formats.isEmpty) {
        return _surface(
          padding: EdgeInsets.all(16),
          borderRadius: BorderRadius.circular(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 16, color: _accent),
                  SizedBox(width: 8),
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
              SizedBox(height: 12),
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
      if (formats.isEmpty) {
        return _surface(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          borderRadius: BorderRadius.circular(18),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded, size: 20, color: _secondaryText),
              SizedBox(width: 12),
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
              TextButton(onPressed: retry, child: Text('Retry')),
            ],
          ),
        );
      }
      final languages = <String, List<MovieSource>>{};
      for (final source in formats) {
        for (final language in movieSourceLanguageKeys(source)) {
          languages.putIfAbsent(language, () => []).add(source);
        }
      }
      final requestedLanguage = _selectedLanguages[episode];
      final activeLanguage = languages.containsKey(requestedLanguage)
          ? requestedLanguage!
          : languages.containsKey('hi')
          ? 'hi'
          : languages.keys.first;
      final selectedSources = languages[activeLanguage]!;
      final qualities = <String, List<MovieSource>>{};
      for (final source in selectedSources) {
        final quality = _quality(source);
        qualities
            .putIfAbsent(quality.isEmpty ? 'Auto' : quality, () => [])
            .add(source);
      }
      int height(String quality) =>
          int.tryParse(quality.replaceAll('p', '')) ?? 0;
      final order = qualities.keys.toList()
        ..sort((a, b) => height(b).compareTo(height(a)));
      final languageOrder = [
        if (languages.containsKey('hi')) 'hi',
        ...languages.keys.where((language) => language != 'hi'),
      ];
      return _surface(
        padding: EdgeInsets.all(12),
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final language in languageOrder)
                    Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(movieSourceLanguageLabels[language]!),
                        selected: language == activeLanguage,
                        showCheckmark: false,
                        selectedColor: _accentSoft,
                        side: BorderSide(
                          color: _accent.withValues(
                            alpha: language == activeLanguage ? .44 : .15,
                          ),
                        ),
                        labelStyle: TextStyle(
                          color: language == activeLanguage
                              ? _accent
                              : _primaryText,
                          fontWeight: FontWeight.w700,
                        ),
                        onSelected: (_) => setState(
                          () => _selectedLanguages[episode] = language,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: 6),
            if (waiting)
              LinearProgressIndicator(
                minHeight: 2,
                color: _accent,
                backgroundColor: _accentSoft,
                semanticsLabel: 'Checking for more formats',
              )
            else
              Divider(height: 1, color: _accent.withValues(alpha: .13)),
            SizedBox(height: 5),
            for (final quality in order)
              _sourceRow(
                quality,
                qualities[quality]!,
                episode,
                selectedSources,
              ),
          ],
        ),
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
          initialSeason: episode?.season ?? 1,
          initialEpisode: episode?.number ?? 1,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Hero + section headers
  // ---------------------------------------------------------------------------

  Widget _titleHeader(bool series, {VoidCallback? downloadSeason}) {
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
          color: context.palette.shadowAt(_dark ? .27 : .12),
          blurRadius: 20,
          offset: Offset(0, 8),
        ),
      ],
      child: Stack(
        children: [
          Positioned.fill(
            child: SmartNetworkImage(
              url: movie.backdropUrl,
              fallbackUrl: movie.posterUrl,
              fit: BoxFit.cover,
              placeholderColor: context.palette.background,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    context.palette.scrimAt(0.086),
                    context.palette.scrimAt(0.675),
                    context.palette.scrimAt(0.980),
                  ],
                  stops: [0, .48, 1],
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 72, 16, 16),
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
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        metadata.join(' · '),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: context.palette.onScrim,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        movie.title,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: context.palette.onScrim,
                          fontWeight: FontWeight.w800,
                          height: 1.12,
                        ),
                      ),
                      if (movie.providerName.trim().isNotEmpty) ...[
                        SizedBox(height: 8),
                        Text(
                          movie.providerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: context.palette.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (series)
            Positioned(
              top: 12,
              right: 12,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: downloadSeason,
                  borderRadius: BorderRadius.circular(24),
                  child: Opacity(
                    opacity: downloadSeason == null ? .55 : 1,
                    child: Container(
                      height: 38,
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        gradient: downloadSeason == null
                            ? null
                            : context.palette.primaryGradient,
                        color: downloadSeason == null ? context.palette.textSecondary : null,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: context.palette.tint(context.palette.card, .28),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: context.palette.tint(context.palette.primary, .42),
                            blurRadius: 14,
                            offset: Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: context.palette.tint(context.palette.card, .18),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.download_rounded,
                              size: 13,
                              color: context.palette.onScrim,
                            ),
                          ),
                          SizedBox(width: 7),
                          Text(
                            'Full season',
                            style: TextStyle(
                              color: context.palette.onScrim,
                              fontWeight: FontWeight.w800,
                              fontSize: 11.5,
                              letterSpacing: .1,
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
            padding: EdgeInsets.only(left: 8),
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
        shape: Border(),
        collapsedShape: Border(),
        iconColor: _accent,
        collapsedIconColor: _secondaryText,
        tilePadding: EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        childrenPadding: EdgeInsets.fromLTRB(14, 0, 14, 14),
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
                padding: EdgeInsets.only(top: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.subtitles_rounded,
                      size: 12,
                      color: _secondaryText,
                    ),
                    SizedBox(width: 4),
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
          duration: Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: _surface(
            padding: EdgeInsets.all(8),
            borderRadius: BorderRadius.circular(12),
            color: _accentSoft,
            shadows: [],
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
    backgroundColor: _dark ? context.palette.background : context.palette.background,
    appBar: AppBar(
      title: Text(widget.movie.isSeries ? 'Series details' : 'Movie details'),
      backgroundColor: _dark ? context.palette.background : context.palette.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    body: SafeArea(
      top: false,
      child: FutureBuilder<List<ProviderEpisode>>(
        future: _episodes,
        builder: (context, snapshot) {
          final loadingEpisodes =
              widget.movie.isSeries &&
              snapshot.connectionState != ConnectionState.done;
          final episodes = snapshot.data ?? <ProviderEpisode>[];
          final seasons = <int?, List<ProviderEpisode>>{};
          for (final episode in episodes) {
            seasons.putIfAbsent(episode.season, () => []).add(episode);
          }
          final seasonNumbers = seasons.keys.toList();
          final selectedSeason = seasonNumbers.elementAtOrNull(_seasonIndex);
          final selectedEpisodes =
              seasons[selectedSeason] ?? <ProviderEpisode>[];
          final seasonName = selectedSeason == null && seasonNumbers.length > 1
              ? 'Other episodes'
              : 'Season ${selectedSeason ?? 1}';
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _titleHeader(
                    widget.movie.isSeries || episodes.isNotEmpty,
                    downloadSeason: _queuing || selectedEpisodes.isEmpty
                        ? null
                        : () => _downloadSeason(seasonName, selectedEpisodes),
                  ),
                  SizedBox(height: 22),
                  _sectionHeader(
                    widget.movie.isSeries ? 'Episodes' : 'Available formats',
                    count: episodes.isEmpty ? null : episodes.length,
                  ),
                  SizedBox(height: 10),
                  if (seasonNumbers.length > 1) ...[
                    SizedBox(
                      height: 48,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: seasonNumbers.length,
                        separatorBuilder: (_, _) => SizedBox(width: 8),
                        itemBuilder: (_, index) {
                          final selected = index == _seasonIndex;
                          return _surface(
                            shadows: selected
                                ? [
                                    BoxShadow(
                                      color: _accent.withValues(alpha: .17),
                                      blurRadius: 6,
                                      offset: Offset(0, 2),
                                    ),
                                  ]
                                : [],
                            borderRadius: BorderRadius.circular(30),
                            color: selected
                                ? _accent
                                : (_dark
                                      ? context.palette.tint(context.palette.card, 0.078)
                                      : context.palette.tint(context.palette.card, 0.549)),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () =>
                                    setState(() => _seasonIndex = index),
                                borderRadius: BorderRadius.circular(30),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
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
                                                ? context.palette.onPrimary
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
                    SizedBox(height: 14),
                  ],
                  if (!widget.movie.isSeries)
                    _formatList(
                      _movieFormats!,
                      () => setState(() => _movieFormats = _loadMovieFormats()),
                    )
                  else if (loadingEpisodes)
                    LinearProgressIndicator(
                      semanticsLabel: 'Loading episodes',
                    )
                  else if (episodes.isEmpty)
                    ListTile(
                      title: Text(
                        snapshot.hasError
                            ? 'Could not load episodes'
                            : 'No episodes found',
                      ),
                      trailing: TextButton(
                        onPressed: () => setState(() {
                          _seasonIndex = 0;
                          _episodes = _engine.episodesFor(widget.movie);
                        }),
                        child: Text('Retry'),
                      ),
                    )
                  else
                    for (final episode in selectedEpisodes)
                      Padding(
                        padding: EdgeInsets.only(bottom: 10),
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
