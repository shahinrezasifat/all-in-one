import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/movie_model.dart';
import '../movie_repository_service.dart';
import 'cloudstream_runtime.dart';
import 'provider_context.dart';
import 'provider_models.dart';

/// Runs the user's Zangetsu JS providers inside QuickJS and turns their
/// `search` / `getHome` / `getDetail` / `getVideoSources` results into the
/// app's own [MovieItem] / [MovieSource] models — this is what makes REAL repo
/// movies (and their real streams) play, instead of sample clips or trailers.
class ProviderEngineService {
  ProviderEngineService._();
  static final ProviderEngineService instance = ProviderEngineService._();

  final http.Client _client = http.Client();

  // providerId → live JS context (one QuickJS runtime each, cached).
  final Map<String, ProviderContext> _contexts = {};

  final Map<String, Future<ProviderContext>> _opening = {};

  static const Duration _netTimeout = Duration(seconds: 15);

  /// Providers that failed a source scan are parked briefly so a sweep over
  /// hundreds of repos doesn't re-pay the same dead request every time.
  static final Map<String, DateTime> _deadProviderUntil = {};

  bool _providerUsable(String id) {
    final until = _deadProviderUntil[id];
    return until == null || !DateTime.now().isBefore(until);
  }

  Future<String> _getText(String url) async {
    final res = await _client
        .get(
          Uri.parse(url),
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
          },
        )
        .timeout(_netTimeout);
    if (res.statusCode < 200 || res.statusCode >= 400) {
      throw StateError('HTTP ${res.statusCode} for $url');
    }
    return utf8.decode(res.bodyBytes);
  }

  Iterable<({MovieRepository repo, MovieProvider provider})>
  get catalogSources sync* {
    for (final repo in MovieRepositoryService.instance.enabledRepositories) {
      for (final provider in repo.providers) {
        if (provider.isInstalled && provider.isEnabled) {
          yield (repo: repo, provider: provider);
        }
      }
    }
  }

  Future<List<String>> activeJsProviderIds({String? filter}) async {
    await MovieRepositoryService.instance.ready;
    final id = filter?.trim().toLowerCase();
    return catalogSources
        .where(
          (s) =>
              s.provider.scriptUrl.isNotEmpty &&
              !s.repo.isAdult &&
              !s.provider.isAdult,
        )
        .where(
          (s) =>
              id == null ||
              id.isEmpty ||
              id == 'all' ||
              s.provider.id.toLowerCase() == id,
        )
        .map((s) => s.provider.id.toLowerCase())
        .toSet()
        .toList();
  }

  Future<ProviderContext> _openContext(
    MovieRepository repo,
    MovieProvider provider,
  ) async {
    final key =
        '${repo.id}|${provider.id}|${provider.version}|${provider.scriptUrl}';
    final cached = _contexts[key];
    if (cached != null) return cached;
    return _opening.putIfAbsent(key, () async {
      try {
        // Provider scripts are evaluated with network access — never accept a
        // cleartext source that could be replaced in transit.
        final scriptUri = Uri.tryParse(provider.scriptUrl);
        final localScript =
            scriptUri != null &&
            const {
              'localhost',
              '127.0.0.1',
              '[::1]',
              '10.0.2.2',
            }.contains(scriptUri.host);
        if (scriptUri == null ||
            (scriptUri.scheme != 'https' &&
                !(scriptUri.scheme == 'http' && localScript)) ||
            scriptUri.host.isEmpty) {
          throw StateError('Provider scripts must be served over HTTPS');
        }
        final js = await _getText(scriptUri.toString());
        final ctx = ProviderContext(
          id: provider.id,
          name: provider.name,
          jsSource: js,
        );
        try {
          await ctx.bootstrap();
        } catch (_) {
          ctx.dispose();
          rethrow;
        }
        return _contexts[key] = ctx;
      } finally {
        _opening.remove(key);
      }
    });
  }

  Future<void> installExtension(String repoId, String providerId) async {
    final service = MovieRepositoryService.instance;
    await service.ready;
    final repo = service.repositories.firstWhere((r) => r.id == repoId);
    final provider = repo.providers.firstWhere((p) => p.id == providerId);
    if (!CloudStreamRuntime.canRun(provider)) {
      throw StateError('Unsupported extension format');
    }
    if (provider.cloudStreamUrl.isNotEmpty) {
      await CloudStreamRuntime.install(repoId, provider);
    } else {
      await _openContext(repo, provider);
    }
    await service.installExtension(repoId, providerId);
  }

  Future<ProviderContext?> _contextFor(
    String providerId, {
    String? repoId,
  }) async {
    await MovieRepositoryService.instance.ready;
    final source = catalogSources
        .where(
          (s) =>
              s.provider.id.toLowerCase() == providerId.toLowerCase().trim() &&
              (repoId == null || s.repo.id == repoId),
        )
        .firstOrNull;
    if (source == null) return null;
    try {
      return await _openContext(source.repo, source.provider);
    } catch (_) {
      return null;
    }
  }

  Future<List<MovieItem>> fetchCatalog({
    required String repoId,
    required String providerId,
    String query = '',
    int page = 1,
  }) async {
    await MovieRepositoryService.instance.ready;
    final source = catalogSources.firstWhere(
      (s) => s.repo.id == repoId && s.provider.id == providerId,
    );
    if (source.provider.cloudStreamUrl.isNotEmpty) {
      return CloudStreamRuntime.catalog(
        source.repo,
        source.provider,
        query,
        page,
      );
    }
    if (source.provider.scriptUrl.trim().isEmpty) return const [];
    if (source.provider.scriptUrl.isNotEmpty) {
      try {
        final ctx = await _openContext(source.repo, source.provider);
        final metas = query.isEmpty
            ? await ctx.browse(page: page)
            : await ctx.search(query, page: page);
        final seen = <String>{};
        final results = [
          for (final meta in metas)
            if (meta.url.isNotEmpty && seen.add(meta.url))
              movieItemFromMeta(meta).copyWith(
                providerId: source.provider.id,
                providerName: source.provider.name,
                repoId: source.repo.id,
                repoName: source.repo.name,
              ),
        ];
        if (results.isNotEmpty) return results;
      } catch (_) {
        // Fall back to genuine repo items
      }
    }

    final repoService = MovieRepositoryService.instance;
    return repoService.searchMovies(
      query,
      providerFilter: source.provider.id.isNotEmpty
          ? source.provider.id
          : source.provider.name,
    );
  }

  /// Live catalog page built from the real providers. No query → provider
  /// home shelves; with query → provider search. Results are tagged with their
  /// provider so playback resolves streams from the right context.
  Future<List<MovieItem>> fetchProviderMovies({
    String query = '',
    String category = 'All',
    int page = 0,
    String? providerFilter,
  }) async {
    final ids = await activeJsProviderIds(filter: providerFilter);
    if (ids.isEmpty) return const [];

    final searchTerms = <String>[];
    final useHome =
        query.isEmpty && page == 0 && (category == 'All' || category.isEmpty);

    if (query.isNotEmpty) {
      searchTerms.add(query);
    } else if (!useHome) {
      // Category browsing → one real search per category seed.
      final term = _categoryTerm(category, page);
      if (term != null) searchTerms.add(term);
    }

    final metas = <ProviderMeta>[];
    if (useHome) {
      final results = await Future.wait(
        ids.map((id) async {
          final ctx = await _contextFor(id);
          if (ctx == null) return <ProviderHomeRow>[];
          try {
            return await ctx.getHome();
          } catch (_) {
            return <ProviderHomeRow>[];
          }
        }),
      );
      for (final rows in results) {
        for (final row in rows) {
          for (final m in row.items) {
            metas.add(m);
          }
        }
      }
    } else {
      final jobs = <Future<List<ProviderMeta>>>[];
      for (final id in ids) {
        for (final term in searchTerms) {
          jobs.add(() async {
            final ctx = await _contextFor(id);
            if (ctx == null) return <ProviderMeta>[];
            try {
              return await ctx.search(term, page: page + 1);
            } catch (_) {
              return <ProviderMeta>[];
            }
          }());
        }
      }
      final results = await Future.wait(jobs);
      for (final list in results) {
        metas.addAll(list);
      }
    }

    return _dedupeToItems(metas);
  }

  String? _categoryTerm(String category, int page) {
    final c = category.toLowerCase();
    const map = <String, List<String>>{
      'trending': ['action', 'adventure', 'comedy'],
      'movies': ['movie', 'action', 'thriller'],
      'series': ['web series', 'season'],
      'anime': ['anime'],
      '4k uhd': ['4k', 'uhd'],
      'bangla (bdix)': ['bangla'],
      'bollywood': ['bollywood', 'hindi dubbed'],
      'top rated': ['hollywood', 'drama'],
    };
    for (final e in map.entries) {
      if (c.contains(e.key.split(' ').first) || c == e.key) {
        final list = e.value;
        return list[page % list.length];
      }
    }
    return null;
  }

  List<MovieItem> _dedupeToItems(List<ProviderMeta> metas) {
    final seen = <String>{};
    final items = <MovieItem>[];
    for (final m in metas) {
      final key = (m.url.isNotEmpty ? m.url : m.title).toLowerCase().trim();
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      items.add(movieItemFromMeta(m));
    }
    return items;
  }

  MovieItem movieItemFromMeta(ProviderMeta m) {
    final year =
        int.tryParse(
          RegExp(r'(\d{4})').firstMatch(m.year)?.group(1) ?? m.year,
        ) ??
        0;
    final providerName =
        _contexts.values
            .where((ctx) => ctx.id == m.sourceId)
            .firstOrNull
            ?.name ??
        m.sourceId;
    return MovieItem(
      id: m.url.isNotEmpty ? m.url : m.id,
      title: m.title,
      posterUrl: m.cover,
      backdropUrl: m.cover,
      year: year,
      rating: 0.0,
      quality: '',
      genres: m.genres.isEmpty ? const ['Cinema'] : m.genres,
      type: m.type,
      catalogGroups: m.catalogGroups,
      synopsis: m.description,
      duration: year > 0 ? '$year' : 'HD',
      repoId: '',
      repoName: 'Providers',
      providerId: m.sourceId,
      providerName: providerName,
      detailUrl: m.url,
      sources: const [],
    );
  }

  // ── stream resolution (the real playback path) ─────────────────────────────
  /// Resolve every real, playable stream for a live provider item by running
  /// the provider's `getDetail` → `getVideoSources`. Returns [] when the movie
  /// genuinely has no resolvable source (the UI must then NOT play a trailer).
  bool _isCloudStream(MovieItem item) => catalogSources.any(
    (s) =>
        s.repo.id == item.repoId &&
        s.provider.id == item.providerId &&
        s.provider.cloudStreamUrl.isNotEmpty,
  );

  Future<List<ProviderEpisode>> episodesFor(MovieItem item) async {
    await MovieRepositoryService.instance.ready;
    if (_isCloudStream(item)) return CloudStreamRuntime.episodes(item);
    final ctx = await _contextFor(item.providerId, repoId: item.repoId);
    if (ctx == null) throw StateError('Source unavailable');
    return (await ctx.getEpisodes(item.detailUrl))
        .where((episode) => episode.url.isNotEmpty)
        .toList();
  }

  Future<List<MovieSource>> resolveStreams(
    MovieItem item, {
    ProviderEpisode? episode,
    bool keepAllFormats = false,
    void Function(List<MovieSource>)? onFormats,
  }) async {
    if (item.detailUrl.isEmpty) return const [];
    await MovieRepositoryService.instance.ready;
    if (_isCloudStream(item)) {
      return CloudStreamRuntime.resolve(
        item,
        episodeData: episode?.url,
        onFormats: onFormats,
      );
    }
    final ctx = await _contextFor(
      item.providerId,
      repoId: item.repoId.isEmpty ? null : item.repoId,
    );
    if (ctx == null) return const [];

    final versions = <String, String>{};
    final storedUrl = episode?.url ?? item.episodeUrl;
    if (storedUrl.isNotEmpty) {
      versions[storedUrl] = episode?.title ?? '';
    } else {
      try {
        final episodes = await ctx.getEpisodes(item.detailUrl);
        final choices = keepAllFormats && !item.isSeries
            ? episodes
            : episodes.take(1);
        for (final version in choices) {
          if (version.url.isNotEmpty) versions[version.url] = version.title;
        }
      } catch (_) {
        // Some providers accept the detail URL directly.
      }
      if (versions.isEmpty) versions[item.detailUrl] = '';
    }

    final out = <MovieSource>[];
    final seen = <String>{};
    final entries = versions.entries.toList(growable: false);
    var next = 0;
    Future<void> resolveVersion() async {
      while (next < entries.length) {
        final version = entries[next++];
        List<ProviderStream> streams;
        try {
          streams = await ctx.getVideoSources(version.key);
        } catch (_) {
          continue;
        }
        final formats = <MovieSource>[];
        for (final stream in streams) {
          if (stream.url.isEmpty ||
              (!keepAllFormats && !seen.add(stream.url))) {
            continue;
          }
          formats.add(
            movieSourceFromStream(
              stream,
              item,
              ctx,
              versionLabel: item.isSeries || episode != null
                  ? ''
                  : version.value,
            ),
          );
        }
        out.addAll(formats);
        if (formats.isNotEmpty) onFormats?.call(formats);
      }
    }

    await Future.wait(
      List.generate(entries.length.clamp(1, 3), (_) => resolveVersion()),
    );
    return out;
  }

  MovieSource movieSourceFromStream(
    ProviderStream s,
    MovieItem item,
    ProviderContext ctx, {
    String versionLabel = '',
  }) {
    final q = providerResolution(s.quality, labels: [s.label, versionLabel]);
    final uriPath = Uri.tryParse(s.url)?.path.toLowerCase() ?? '';
    return MovieSource(
      serverName: s.label.isNotEmpty ? s.label : '${ctx.name} $q',
      resolution: q,
      downloadUrl: s.url,
      streamUrl: s.url,
      fileSize: '',
      format: switch (s.container.toLowerCase()) {
        'hls' || 'm3u8' => 'm3u8',
        'dash' || 'mpd' => 'mpd',
        'mkv' || 'webm' || 'mov' || 'avi' || 'ts' => s.container.toLowerCase(),
        _ when uriPath.endsWith('.m3u8') => 'm3u8',
        _ when uriPath.endsWith('.mpd') => 'mpd',
        _ => 'mp4',
      },
      providerId: ctx.id,
      providerName: ctx.name,
      headers: s.headers,
    );
  }

  Future<List<MovieSource>> episodeDownloadFormats(
    MovieItem movie,
    ProviderEpisode episode,
  ) async {
    final sources = await resolveStreams(
      movie,
      episode: episode,
      keepAllFormats: true,
    ).timeout(const Duration(seconds: 25));
    final seen = <(String, String, String, String?)>{};
    final downloadable = sources.where((source) {
      final uri = Uri.tryParse(source.downloadUrl);
      return uri != null &&
          const {'http', 'https'}.contains(uri.scheme) &&
          seen.add((
            source.downloadUrl,
            source.serverName,
            source.resolution,
            source.hlsVariantResolution,
          ));
    }).toList();
    final formats = List<List<MovieSource>>.filled(
      downloadable.length,
      const [],
    );
    var next = 0;
    Future<void> inspectManifests() async {
      while (next < downloadable.length) {
        final index = next++;
        final source = downloadable[index];
        final variants =
            source.hlsVariantResolution == null &&
                source.streamUrl == source.downloadUrl &&
                source.format.toLowerCase() == 'm3u8'
            ? await adaptiveMovieFormats(source)
            : const <MovieSource>[];
        formats[index] = variants.isEmpty ? [source] : variants;
      }
    }

    await Future.wait(
      List.generate(downloadable.length.clamp(1, 3), (_) => inspectManifests()),
    );
    return formats.expand((sources) => sources).toList();
  }

  /// Read only master-playlist metadata. Keep the original manifest URL so
  /// playback can select the video track while retaining alternate audio.
  Future<List<MovieSource>> adaptiveMovieFormats(MovieSource source) async {
    final url = Uri.tryParse(source.streamUrl);
    if (source.format.toLowerCase() != 'm3u8' ||
        url == null ||
        !const {'http', 'https'}.contains(url.scheme)) {
      return const [];
    }

    final client = http.Client();
    Future<String> readMaster() async {
      final request = http.Request('GET', url)..headers.addAll(source.headers);
      final response = await client.send(request);
      if (response.statusCode != 200) return '';
      const limit = 96 * 1024;
      final buffer = BytesBuilder(copy: false);
      await for (final data in response.stream) {
        final remaining = limit - buffer.length;
        buffer.add(
          data.length <= remaining ? data : data.sublist(0, remaining),
        );
        if (buffer.length >= limit) break;
      }
      return utf8.decode(buffer.takeBytes(), allowMalformed: true);
    }

    try {
      final playlist = await readMaster().timeout(const Duration(seconds: 3));
      if (!playlist.trimLeft().startsWith('#EXTM3U')) return const [];
      final variants = <int, String>{};
      final resolution = RegExp(r'(?:^|[:,])RESOLUTION=(\d+)x(\d+)(?:,|$)');
      for (final line in const LineSplitter().convert(playlist)) {
        if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
        final match = resolution.firstMatch(line);
        if (match == null) continue;
        final width = int.parse(match[1]!);
        final height = int.parse(match[2]!);
        final widescreen = const {
          3840: 2160,
          2560: 1440,
          1920: 1080,
          1280: 720,
          854: 480,
          640: 360,
        }[width];
        final labelHeight = widescreen != null && height < widescreen
            ? widescreen
            : height;
        variants.putIfAbsent(labelHeight, () => '${width}x$height');
      }
      final sorted = variants.keys.toList()..sort((a, b) => b.compareTo(a));
      return [
        for (final height in sorted)
          source.copyWith(
            resolution: '${height}p',
            downloadUrl: source.streamUrl,
            fileSize: '',
            hlsVariantResolution: variants[height],
          ),
      ];
    } on Exception {
      return const [];
    } finally {
      client.close();
    }
  }

  // ── cross-repository resolution ────────────────────────────────────────────
  Future<String> repoNameFor(String providerId) async {
    await MovieRepositoryService.instance.ready;
    return catalogSources
            .where(
              (s) =>
                  s.provider.id.toLowerCase() ==
                  providerId.toLowerCase().trim(),
            )
            .firstOrNull
            ?.repo
            .name ??
        '';
  }

  /// Resolve EVERY playable stream for a title across ALL active repositories.
  ///
  /// The item's own provider is asked through its detail permalink; each other
  /// runnable JS provider is searched by the (cleaned) title, its closest
  /// match is opened, and its real streams are collected too. Sources that
  /// carry a repo/provider tag let the UI group them into per-repo filters —
  /// a title genuinely offered by no repo yields [], which the caller uses to
  /// hide/remove the movie from the list.
  Future<List<MovieSource>> resolveStreamsEverywhere(MovieItem item) async {
    final all = <MovieSource>[];
    final seenUrls = <String>{};

    void addAll(List<MovieSource> sources) {
      for (final s in sources) {
        final url = s.downloadUrl.isNotEmpty ? s.downloadUrl : s.streamUrl;
        if (url.isEmpty || seenUrls.contains(url)) continue;
        seenUrls.add(url);
        all.add(s);
      }
    }

    // 1) The item's own provider, via its permalink (fastest, exact match).
    if (item.detailUrl.isNotEmpty) {
      final own = await resolveStreams(item);
      final repoName = await repoNameFor(item.providerId);
      addAll(
        own
            .map(
              (s) => repoName.isNotEmpty && s.repoName.isEmpty
                  ? s.copyWith(repoName: repoName)
                  : s,
            )
            .toList(),
      );
    }

    // 2) Active providers search: by title search → best match → streams.
    final title = cleanSearchTitle(item.title);
    if (title.isEmpty) return all;
    await MovieRepositoryService.instance.ready;
    final ids = await activeJsProviderIds();
    final jobs = ids
        .where(
          (id) =>
              item.detailUrl.isEmpty ||
              id.toLowerCase() != item.providerId.toLowerCase(),
        )
        .map((id) async {
          try {
            final ctx = await _contextFor(id);
            if (ctx == null) return <MovieSource>[];
            var metas = await ctx.search(title);
            // Fallback for sequels/numbers (e.g. "Jailer 2" -> "Jailer") if unreleased
            if (metas.isEmpty) {
              final rootTitle = title.replaceAll(RegExp(r'\s+\d+$'), '').trim();
              if (rootTitle.isNotEmpty && rootTitle != title) {
                metas = await ctx.search(rootTitle);
              }
            }
            if (metas.isEmpty) return <MovieSource>[];
            final best = metas.reduce(
              (a, b) => titleScore(title, a.title) >= titleScore(title, b.title)
                  ? a
                  : b,
            );
            // Accept a real match (lenient threshold so localized titles match)
            if (titleScore(title, best.title) < 0.4) return <MovieSource>[];
            var episodeUrl = best.url;
            if (episodeUrl.isEmpty && best.episodes.isNotEmpty) {
              episodeUrl = best.episodes.first.url;
            }
            if (episodeUrl.isEmpty) return <MovieSource>[];
            final streams = await ctx.getVideoSources(episodeUrl);
            final repoName = await repoNameFor(id);
            return streams
                .where((s) => s.url.isNotEmpty)
                .map(
                  (s) => movieSourceFromStream(
                    s,
                    item,
                    ctx,
                  ).copyWith(repoName: repoName),
                )
                .toList();
          } catch (_) {
            return <MovieSource>[];
          }
        })
        .toList();
    for (final list in await Future.wait(jobs)) {
      addAll(list);
    }
    return all;
  }

  /// Progressive, bounded sweep across every active repository.
  ///
  /// Unlike [resolveStreamsEverywhere] (one giant `Future.wait` over all repos),
  /// this feeds [onBatch] the moment each provider answers, so a picker can
  /// list results live instead of freezing until all of them finish. Dead or
  /// failing providers are parked, and a global budget stops the sweep.
  Future<void> resolveStreamsProgressively(
    MovieItem item, {
    required Future<void> Function(List<MovieSource> sources) onBatch,
    int concurrency = 10,
    Duration perProviderTimeout = const Duration(seconds: 6),
    Duration totalBudget = const Duration(seconds: 30),
  }) async {
    await MovieRepositoryService.instance.ready;
    final title = cleanSearchTitle(item.title);
    if (title.isEmpty) return;

    // 0) LOCAL CATALOG — covers CloudStream repos, which have no runnable JS
    //    index and are therefore invisible to activeJsProviderIds(). Match the
    //    title across every ENABLED repo's catalogued sources and tag each with
    //    that repo's own name. Instant, no network.
    final repoService = MovieRepositoryService.instance;
    final enabledIds = repoService.enabledRepositories
        .map((r) => r.id.toLowerCase().trim())
        .toSet();
    final enabledNames = repoService.enabledRepositories
        .map((r) => r.name.toLowerCase().trim())
        .toSet();
    final catalogSources = <MovieSource>[];
    final seenCatalog = <String>{};
    for (final m in repoService.getAllMovies()) {
      final repoOk =
          enabledIds.contains(m.repoId.toLowerCase().trim()) ||
          enabledNames.contains(m.repoName.toLowerCase().trim());
      if (!repoOk) continue;
      if (titleScore(title, cleanSearchTitle(m.title)) < 0.4) continue;
      final repoLabel = m.repoName.isNotEmpty ? m.repoName : m.repoId;
      for (final s in m.sources) {
        final url = s.downloadUrl.isNotEmpty ? s.downloadUrl : s.streamUrl;
        if (url.isEmpty || seenCatalog.contains(url)) continue;
        seenCatalog.add(url);
        catalogSources.add(s.copyWith(repoName: repoLabel));
      }
    }
    if (catalogSources.isNotEmpty) await onBatch(catalogSources);

    final skip = item.detailUrl.isEmpty
        ? <String>{}
        : {item.providerId.toLowerCase().trim()};
    final queue = (await activeJsProviderIds())
        .where((id) => !skip.contains(id.toLowerCase().trim()))
        .where(_providerUsable)
        .toList();

    final deadline = DateTime.now().add(totalBudget);
    var cursor = 0;

    Future<void> worker() async {
      while (DateTime.now().isBefore(deadline) && cursor < queue.length) {
        final id = queue[cursor++];
        try {
          final sources = await _resolveForProvider(
            item,
            id,
            title,
          ).timeout(perProviderTimeout);
          if (sources.isNotEmpty) await onBatch(sources);
        } catch (_) {
          _deadProviderUntil[id] = DateTime.now().add(
            const Duration(minutes: 5),
          );
        }
      }
    }

    final workers = List.generate(
      concurrency < queue.length ? concurrency : queue.length,
      (_) => worker(),
    );
    await Future.wait(workers);
  }

  /// True when at least the first byte of [s] can really be fetched. Used by
  /// the picker to hide links that are dead/unplayable instead of offering
  /// sources that would fail on download.
  static Future<bool> probeSource(MovieSource s) async {
    final url = s.downloadUrl.isNotEmpty ? s.downloadUrl : s.streamUrl;
    if (url.isEmpty) return false;
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(s.headers)
        ..headers['Range'] = 'bytes=0-0'
        ..headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
      final res = await client.send(req).timeout(const Duration(seconds: 4));
      final ok = res.statusCode >= 200 && res.statusCode < 400;
      try {
        await res.stream.drain().timeout(const Duration(seconds: 2));
      } catch (_) {}
      return ok;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// One provider's genuine streams for a title (search → best match → streams).
  Future<List<MovieSource>> _resolveForProvider(
    MovieItem item,
    String id,
    String title,
  ) async {
    final ctx = await _contextFor(id);
    if (ctx == null) return const [];
    var metas = await ctx.search(title);
    if (metas.isEmpty) {
      final root = title.replaceAll(RegExp(r'\s+\d+$'), '').trim();
      if (root.isNotEmpty && root != title) metas = await ctx.search(root);
    }
    if (metas.isEmpty) return const [];
    final best = metas.reduce(
      (a, b) =>
          titleScore(title, a.title) >= titleScore(title, b.title) ? a : b,
    );
    if (titleScore(title, best.title) < 0.4) return const [];
    var url = best.url;
    if (url.isEmpty && best.episodes.isNotEmpty) {
      url = best.episodes.first.url;
    }
    if (url.isEmpty) return const [];
    final streams = await ctx.getVideoSources(url);
    final repoName = await repoNameFor(id);
    return streams
        .where((s) => s.url.isNotEmpty)
        .map(
          (s) =>
              movieSourceFromStream(s, item, ctx).copyWith(repoName: repoName),
        )
        .toList();
  }

  /// Strips quality/year/noise tokens from a catalog title so cross-repo
  /// searches use the real name: "Movie Name (2024) 1080p HD" → "Movie Name".
  static String cleanSearchTitle(String title) {
    var t = title
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(
          RegExp(
            r'\b(\d{3,4}p|4k|uhd|hd|sd|bluray|web-?rip|hdcam|pdvd|x264|x265|hevc|avc|dual|audio|subtitles?|uncut|extended|imax|dolby|atmos|5\.1|10\.bit|batch\s*\d+)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\b(19|20)\d{2}\b'), ' ')
        .replaceAll(RegExp(r'[^a-zA-Z0-9 :]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (t.length > 80) t = t.substring(0, 80).trim();
    return t;
  }

  /// 0..1 overlap between the wanted title and a candidate — token-based so
  /// "Avengers Endgame" matches "Avengers: Endgame (Hindi)" across sites.
  static double titleScore(String wanted, String candidate) {
    final a = wanted
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((s) => s.isNotEmpty)
        .toSet();
    final b = candidate
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((s) => s.isNotEmpty)
        .toSet();
    if (a.isEmpty || b.isEmpty) return 0;
    final hit = a.intersection(b).length / a.length;
    return a.containsAll(b) ? hit : hit * 0.9;
  }

  void dispose() {
    for (final c in _contexts.values) {
      c.dispose();
    }
    _contexts.clear();
    try {
      _client.close();
    } catch (_) {}
  }
}
