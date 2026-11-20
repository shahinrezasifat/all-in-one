import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/movie_model.dart';
import '../screens/movie_player_screen.dart';
import '../services/download_manager.dart';
import '../services/extractor_service.dart';
import '../services/movie_repository_service.dart';
import '../services/permission_service.dart';
import '../services/preference_service.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../services/stream_fallback_service.dart';
import '../services/watch_history_service.dart';
import '../theme/app_colors.dart';
import 'movie_card.dart';
import 'movie_source_picker_sheet.dart';
import 'remote_image.dart';

class MovieDetailSheet extends StatefulWidget {
  final MovieItem movie;
  final bool selectedSourceOnly;

  /// Fired when cross-repository resolution proves this title has NO playable
  /// stream in any repo — the list screen uses it to drop the movie for good.
  final VoidCallback? onUnplayable;

  const MovieDetailSheet({
    super.key,
    required this.movie,
    this.onUnplayable,
    this.selectedSourceOnly = false,
  });

  static void show(
    BuildContext context,
    MovieItem movie, {
    VoidCallback? onUnplayable,
    bool selectedSourceOnly = false,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MovieDetailSheet(
        movie: movie,
        onUnplayable: onUnplayable,
        selectedSourceOnly: selectedSourceOnly,
      ),
    );
  }

  @override
  State<MovieDetailSheet> createState() => _MovieDetailSheetState();
}

class _MovieDetailSheetState extends State<MovieDetailSheet> {
  MovieSource? _selectedSource;

  /// The resolution the user tapped in the format list — carried into the
  /// source picker so it only offers sources for that exact format.
  _ResPick? _selectedResPick;

  // REAL playable streams resolved live across EVERY active repository
  // (JS providers run getDetail â†’ getVideoSources; other repos are title-
  // searched and their closest match resolved too). Sizes are probed lazily
  // so each resolution can honestly show its smallest-MB file.
  List<MovieSource> _allSources = const [];
  bool _resolving = false;
  bool _sizesProbing = false;

  // Selected language key (e.g. 'bn', 'hi', 'en', 'dual', 'multi', 'ta', 'te', etc.)
  String? _selectedLanguageKey;

  /// Resolutions ticked for a MULTI download (e.g. 2160p AND 1080p at once).
  /// Empty = plain single-selection behaviour.
  final Set<String> _checkedResolutions = {};

  List<MovieSource> get _effectiveSources {
    final list = _allSources.isNotEmpty
        ? _allSources
        : widget.movie.sources
              .where((s) => s.downloadUrl.isNotEmpty || s.streamUrl.isNotEmpty)
              .toList();
    return list.map(_enrichSourceWithRepo).toList();
  }

  MovieSource _enrichSourceWithRepo(MovieSource s) {
    if (s.repoName.isNotEmpty && s.repoId.isNotEmpty) return s;

    String repoName = s.repoName;
    String repoId = s.repoId;

    try {
      final repos = MovieRepositoryService.instance.repositories;
      for (final r in repos) {
        if (s.providerId.isNotEmpty &&
            r.providers.any(
              (p) => p.id.toLowerCase() == s.providerId.toLowerCase(),
            )) {
          repoName = r.name;
          repoId = r.id;
          break;
        }
        if (s.serverName.toLowerCase().contains(r.name.toLowerCase()) ||
            r.name.toLowerCase().contains(s.serverName.toLowerCase())) {
          repoName = r.name;
          repoId = r.id;
          break;
        }
      }
    } catch (_) {}

    if (repoName.isEmpty) {
      if (s.isFastBDIX ||
          s.serverName.toLowerCase().contains('bdix') ||
          s.providerId.contains('bd')) {
        repoName = "Redowan's BDIX Repository";
        repoId = 'cs_redowan_bdix';
      } else if (s.providerName.toLowerCase().contains('hdhub') ||
          s.providerName.toLowerCase().contains('4k')) {
        repoName = 'Zangetsu Official JS Providers';
        repoId = 'zangetsu_official_js';
      } else if (s.providerName.toLowerCase().contains('vegamovies') ||
          s.providerName.toLowerCase().contains('hindi')) {
        repoName = 'VegaMovies Dual Audio Repo';
        repoId = 'vegamovies_repo';
      } else if (s.providerName.toLowerCase().contains('uhd')) {
        repoName = 'UHD Ultra Cinema Repo';
        repoId = 'uhd_ultra_repo';
      } else if (s.providerName.toLowerCase().contains('torbox')) {
        repoName = 'TorBox Debrid Repo';
        repoId = 'torbox_debrid_repo';
      } else if (widget.movie.repoName.isNotEmpty) {
        repoName = widget.movie.repoName;
        repoId = widget.movie.repoId;
      } else {
        repoName = 'Community CloudStream Repo';
        repoId = 'cs_community';
      }
    }

    return s.copyWith(repoName: repoName, repoId: repoId);
  }

  // Plain labels only — no flag/globe/film emoji in the UI.
  static const Map<String, String> _languageMeta = {
    'bn': 'Bangla',
    'hi': 'Hindi',
    'dual': 'Dual Audio',
    'multi': 'Multi Audio',
    'en': 'English',
    'ta': 'Tamil',
    'te': 'Telugu',
    'ml': 'Malayalam',
    'kn': 'Kannada',
    'ko': 'Korean',
    'ja': 'Japanese',
    'es': 'Spanish',
    'fr': 'French',
    'ar': 'Arabic',
    'tr': 'Turkish',
    'orig': 'Original Audio',
    'all': 'All Sources',
  };

  static List<String> _detectLanguageKeys(MovieSource s, MovieItem movie) {
    final keys = <String>{};

    final text = [
      s.serverName,
      s.providerName,
      s.providerId,
      s.repoName,
      s.repoId,
      s.resolution,
      movie.title,
      ...movie.genres,
      ...movie.audioTracks,
    ].join(' ').toLowerCase();

    // 1. Dual Audio / 2Audio
    if (text.contains('dual') ||
        text.contains('2audio') ||
        text.contains('dual-audio') ||
        text.contains('dual audio')) {
      keys.add('dual');
    }

    // 2. Multi Audio
    if (text.contains('multi') ||
        text.contains('multi-audio') ||
        text.contains('all audio') ||
        text.contains('multi audio')) {
      keys.add('multi');
    }

    // 3. Bangla / Bengali / BDIX
    if (s.isFastBDIX ||
        text.contains('bangla') ||
        text.contains('bengali') ||
        text.contains('bdix') ||
        text.contains('dhaka') ||
        text.contains('bd ') ||
        s.providerId.contains('bd') ||
        s.repoId.contains('bd') ||
        s.providerId.contains('circle') ||
        s.providerId.contains('samonline')) {
      keys.add('bn');
    }

    // 4. Hindi
    if (text.contains('hindi') ||
        text.contains('hin') ||
        text.contains('bollywood') ||
        s.providerId.contains('hdhub') ||
        s.providerId.contains('vegamovies') ||
        s.providerId.contains('katmovie') ||
        s.providerId.contains('bolly') ||
        s.providerId.contains('multimovies')) {
      keys.add('hi');
    }

    // 5. English
    if (text.contains('english') ||
        text.contains('eng') ||
        text.contains('hollywood') ||
        s.providerId.contains('uhdmovies') ||
        s.providerId.contains('fourkhd') ||
        s.providerId.contains('yts') ||
        s.providerId.contains('vidsrc')) {
      keys.add('en');
    }

    // 6. Tamil
    if (text.contains('tamil') ||
        text.contains('tam') ||
        text.contains('kollywood') ||
        s.providerId.contains('isaimini') ||
        s.providerId.contains('tamilmv')) {
      keys.add('ta');
    }

    // 7. Telugu
    if (text.contains('telugu') ||
        text.contains('tel') ||
        text.contains('tollywood') ||
        s.providerId.contains('ibomma')) {
      keys.add('te');
    }

    // 8. Malayalam
    if (text.contains('malayalam') ||
        text.contains('mal') ||
        text.contains('mollywood')) {
      keys.add('ml');
    }

    // 9. Kannada
    if (text.contains('kannada') ||
        text.contains('kan') ||
        text.contains('sandalwood')) {
      keys.add('kn');
    }

    // 10. Korean
    if (text.contains('korean') ||
        text.contains('kor') ||
        text.contains('kdrama') ||
        s.providerId.contains('dramacool') ||
        s.providerId.contains('kissasian')) {
      keys.add('ko');
    }

    // 11. Japanese
    if (text.contains('japanese') ||
        text.contains('jap') ||
        text.contains('anime') ||
        s.providerId.contains('ani') ||
        s.providerId.contains('gogo') ||
        s.providerId.contains('zoro')) {
      keys.add('ja');
    }

    // 12. Spanish
    if (text.contains('spanish') ||
        text.contains('espanol') ||
        text.contains('castellano') ||
        text.contains('latino')) {
      keys.add('es');
    }

    // 13. French
    if (text.contains('french') ||
        text.contains('francais') ||
        text.contains('vostfr') ||
        text.contains('vf')) {
      keys.add('fr');
    }

    // 14. Arabic
    if (text.contains('arabic') ||
        text.contains('3rabi') ||
        text.contains('ar')) {
      keys.add('ar');
    }

    // 15. Turkish
    if (text.contains('turkish') ||
        text.contains('turkce') ||
        text.contains('dizi')) {
      keys.add('tr');
    }

    // Check provider's declared language
    if (keys.isEmpty && s.providerId.isNotEmpty) {
      try {
        final providers = MovieRepositoryService.instance
            .getInstalledActiveProviders();
        final p = providers.firstWhere(
          (prov) => prov.id.toLowerCase() == s.providerId.toLowerCase(),
          orElse: () => const MovieProvider(id: '', name: ''),
        );
        if (p.language.isNotEmpty) {
          keys.add(p.language.toLowerCase());
        }
      } catch (_) {}
    }

    // Check movie audioTracks
    if (keys.isEmpty && movie.audioTracks.isNotEmpty) {
      for (final track in movie.audioTracks) {
        final t = track.toLowerCase();
        if (t.contains('bangla') || t.contains('bengali')) keys.add('bn');
        if (t.contains('hindi')) keys.add('hi');
        if (t.contains('dual')) keys.add('dual');
        if (t.contains('multi')) keys.add('multi');
        if (t.contains('tamil')) keys.add('ta');
        if (t.contains('telugu')) keys.add('te');
        if (t.contains('english')) keys.add('en');
      }
    }

    if (keys.isEmpty) {
      keys.add('orig');
    }

    return keys.toList();
  }

  static List<String> _sourceLanguageKeys(MovieSource source) {
    final label = '${source.serverName} ${source.resolution}'.toLowerCase();
    const aliases = {
      'bn': r'bangla|bengali|ben',
      'hi': r'hindi|hin',
      'en': r'english|eng',
      'dual': r'dual|2[ ._-]*audio',
      'multi': r'multi|all[ ._-]+audio',
      'ta': r'tamil|tam',
      'te': r'telugu|tel',
      'ml': r'malayalam|mal',
      'kn': r'kannada|kan',
      'ko': r'korean|kor',
      'ja': r'japanese|jpn',
      'es': r'spanish|español|espanol|spa',
      'fr': r'french|français|francais|fra',
      'ar': r'arabic|ara',
      'tr': r'turkish|tur',
    };
    final keys = [
      for (final entry in aliases.entries)
        if (RegExp(r'\b(?:' + entry.value + r')\b').hasMatch(label)) entry.key,
    ];
    return keys.isEmpty ? const ['orig'] : keys;
  }

  /// Groups all real sources across every repository into language options
  List<_LanguageOption> _getAvailableLanguages() {
    if (_effectiveSources.isEmpty) return const [];

    final map = <String, List<MovieSource>>{};
    for (final s in _effectiveSources) {
      final keys = widget.selectedSourceOnly
          ? _sourceLanguageKeys(s)
          : _detectLanguageKeys(s, widget.movie);
      for (final k in keys) {
        map.putIfAbsent(k, () => []).add(s);
      }
    }

    final options = <_LanguageOption>[];
    const preferredOrder = [
      'bn',
      'hi',
      'dual',
      'multi',
      'en',
      'ta',
      'te',
      'ml',
      'kn',
      'ko',
      'ja',
      'es',
      'fr',
      'ar',
      'tr',
      'orig',
    ];

    for (final key in preferredOrder) {
      if (map.containsKey(key)) {
        options.add(
          _LanguageOption(
            key: key,
            label: _languageMeta[key] ?? key.toUpperCase(),
            sources: map[key]!,
          ),
        );
      }
    }

    for (final entry in map.entries) {
      if (!preferredOrder.contains(entry.key)) {
        options.add(
          _LanguageOption(
            key: entry.key,
            label: _languageMeta[entry.key] ?? entry.key.toUpperCase(),
            sources: entry.value,
          ),
        );
      }
    }

    if (options.length > 1 && !widget.selectedSourceOnly) {
      options.add(
        _LanguageOption(
          key: 'all',
          label: 'All Sources',
          sources: _effectiveSources,
        ),
      );
    }

    return options;
  }

  /// Sources belonging to the selected language
  List<MovieSource> get _currentPool {
    if (_effectiveSources.isEmpty) return const [];
    final langs = _getAvailableLanguages();
    if (langs.isEmpty) return _effectiveSources;

    final key = _selectedLanguageKey ?? langs.first.key;
    final opt = langs.firstWhere(
      (l) => l.key == key,
      orElse: () => langs.first,
    );
    return opt.sources;
  }

  String get _selectedLanguageName {
    final langs = _getAvailableLanguages();
    if (langs.isEmpty) return '';
    final key = _selectedLanguageKey ?? langs.first.key;
    final opt = langs.firstWhere(
      (l) => l.key == key,
      orElse: () => langs.first,
    );
    return opt.label;
  }

  /// The source the Play/Download buttons will use — the user's tapped pick
  /// (if it still belongs to the active pool), else the top resolution
  /// of the active language pool.
  MovieSource get _activeSource {
    final pool = _currentPool;
    final sel = _selectedSource;
    if (sel != null &&
        pool.any(
          (s) =>
              identical(s, sel) ||
              ((s.downloadUrl.isNotEmpty && s.downloadUrl == sel.downloadUrl) ||
                  (s.streamUrl.isNotEmpty && s.streamUrl == sel.streamUrl)),
        )) {
      return sel;
    }
    final picks = _resolutionPicks();
    if (picks.isNotEmpty) return picks.first.best;
    if (pool.isNotEmpty) return pool.first;
    return const MovieSource(
      serverName: 'No source',
      resolution: '-',
      downloadUrl: '',
      fileSize: '',
    );
  }

  @override
  void initState() {
    super.initState();
    // Any baked-in source with a real url is immediately usable while the
    // live cross-repo sweep runs in the background.
    final baked = widget.movie.sources
        .where((s) => s.downloadUrl.isNotEmpty || s.streamUrl.isNotEmpty)
        .toList();
    if (baked.isNotEmpty) {
      _allSources = baked;
      _selectedSource = baked.first;
    }
    _resolveStreams();
  }

  Future<void> _resolveStreams() async {
    setState(() {
      _resolving = true;
    });

    try {
      await MovieRepositoryService.instance.ready;
    } catch (_) {}

    final merged = <MovieSource>[];

    if (widget.selectedSourceOnly) {
      try {
        merged.addAll(
          await ProviderEngineService.instance.resolveStreams(widget.movie),
        );
      } catch (_) {}
    } else {
      // 1. Live sweep across all active JS providers (4K HDHub, VegaMovies, AniKoto, etc.)
      try {
        final streams = await ProviderEngineService.instance
            .resolveStreamsEverywhere(widget.movie);
        merged.addAll(streams);
      } catch (_) {}

      if (!mounted) return;

      // 2. Multi-provider fallback discovery across catalog and active extensions
      try {
        final fallbacks = StreamFallbackService.instance.discoverStreams(
          widget.movie,
        );
        for (final s in fallbacks) {
          final url = s.downloadUrl.isNotEmpty ? s.downloadUrl : s.streamUrl;
          if (url.isEmpty) continue;
          if (!merged.any(
            (m) =>
                (m.downloadUrl.isNotEmpty ? m.downloadUrl : m.streamUrl) == url,
          )) {
            merged.add(s);
          }
        }
      } catch (_) {}

      // 3. Any baked-in sources on the movie item
      for (final s in widget.movie.sources) {
        if (s.downloadUrl.isEmpty && s.streamUrl.isEmpty) continue;
        final url = s.downloadUrl.isNotEmpty ? s.downloadUrl : s.streamUrl;
        if (!merged.any(
          (m) =>
              (m.downloadUrl.isNotEmpty ? m.downloadUrl : m.streamUrl) == url,
        )) {
          merged.add(s);
        }
      }

      // 4. Cross-catalog search for identical or similar title
      if (merged.isEmpty) {
        try {
          final cleanTitle = ProviderEngineService.cleanSearchTitle(
            widget.movie.title,
          );
          final catalog = MovieRepositoryService.instance.getAllMovies();
          for (final m in catalog) {
            if (m.sources.any(
              (s) => s.downloadUrl.isNotEmpty || s.streamUrl.isNotEmpty,
            )) {
              final score = ProviderEngineService.titleScore(
                cleanTitle,
                ProviderEngineService.cleanSearchTitle(m.title),
              );
              if (score >= 0.7) {
                for (final s in m.sources) {
                  if (s.downloadUrl.isNotEmpty || s.streamUrl.isNotEmpty) {
                    final url = s.downloadUrl.isNotEmpty
                        ? s.downloadUrl
                        : s.streamUrl;
                    if (!merged.any(
                      (x) =>
                          (x.downloadUrl.isNotEmpty
                              ? x.downloadUrl
                              : x.streamUrl) ==
                          url,
                    )) {
                      merged.add(s);
                    }
                  }
                }
              }
            }
          }
        } catch (_) {}
      }

      // 5. If still empty, attempt web stream extraction
      if (merged.isEmpty) {
        try {
          final extracted = await ExtractorService.instance.resolveMovieExtract(
            widget.movie.title,
          );
          if (extracted != null && extracted.videoFormats.isNotEmpty) {
            for (final f in extracted.videoFormats) {
              final fUrl = f.url ?? '';
              if (fUrl.isEmpty) continue;
              merged.add(
                MovieSource(
                  serverName: f.note != null && f.note!.isNotEmpty
                      ? 'Web Stream (${f.note})'
                      : 'Web Stream',
                  resolution: f.label,
                  downloadUrl: fUrl,
                  streamUrl: fUrl,
                  fileSize: f.fileSize != null ? _fmtBytes(f.fileSize!) : '',
                  format: f.ext,
                  providerName: 'Online Web Stream',
                  repoName: 'Web Stream',
                ),
              );
            }
          }
        } catch (_) {}
      }
    }

    if (!mounted) return;

    setState(() {
      _allSources = merged;
      _resolving = false;
      if (merged.isNotEmpty) {
        _selectedSource ??= merged.first;
      }
    });

    if (merged.isNotEmpty) {
      _probeMissingSizes();
    }
  }

  /// HEAD/Range-probe every stream with no declared size so the resolution
  /// list can show real MB numbers and pick the smallest file per resolution.
  Future<void> _probeMissingSizes() async {
    final todo = _allSources.where((s) => s.fileSize.trim().isEmpty).toList();
    if (todo.isEmpty) return;
    setState(() => _sizesProbing = true);
    final client = http.Client();
    final updates = <MovieSource, MovieSource>{};
    await Future.wait(
      todo.map((s) async {
        final probed = await _probeSize(client, s);
        if (probed.fileSize != s.fileSize) updates[s] = probed;
      }),
    );
    client.close();
    if (!mounted) return;
    setState(() {
      if (updates.isNotEmpty) {
        _allSources = _allSources
            .map((s) => updates.containsKey(s) ? updates[s]! : s)
            .toList();
      }
      _sizesProbing = false;
    });
  }

  Future<MovieSource> _probeSize(http.Client client, MovieSource s) async {
    final url = s.downloadUrl.isNotEmpty ? s.downloadUrl : s.streamUrl;
    if (url.isEmpty || s.format == 'm3u8') return s;
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(s.headers)
        ..headers['Range'] = 'bytes=0-0'
        ..headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
      final res = await client.send(req).timeout(const Duration(seconds: 8));
      final cr = res.headers['content-range'] ?? '';
      var total =
          int.tryParse(RegExp(r'/(\d+)$').firstMatch(cr)?.group(1) ?? '') ?? 0;
      if (total <= 0) {
        total = int.tryParse(res.headers['content-length'] ?? '') ?? 0;
      }
      try {
        await res.stream.drain().timeout(const Duration(seconds: 2));
      } catch (_) {
        unawaited(res.stream.listen((_) {}).cancel());
      }
      if (total > 1024) return s.copyWith(fileSize: _fmtBytes(total));
    } catch (_) {}
    return s;
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1099511627776) {
      return '${(bytes / 1099511627776).toStringAsFixed(2)} TB';
    }
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    }
    return '${(bytes / 1048576).clamp(1, 999999).toStringAsFixed(0)} MB';
  }

  static double _sizeMb(MovieSource s) {
    final m = RegExp(
      r'([\d.]+)\s*(KB|MB|GB|TB)',
      caseSensitive: false,
    ).firstMatch(s.fileSize);
    if (m == null) return 0;
    final v = double.tryParse(m.group(1) ?? '') ?? 0;
    switch (m.group(2)!.toUpperCase()) {
      case 'KB':
        return v / 1024;
      case 'GB':
        return v * 1024;
      case 'TB':
        return v * 1024 * 1024;
      default:
        return v;
    }
  }

  static int heightOf(MovieSource s) {
    final r = s.resolution.toLowerCase();
    if (r.contains('4k') || r.contains('2160')) return 2160;
    if (r.contains('2k') || r.contains('qhd')) return 1440;
    final m = RegExp(r'(\d{3,4})p?').firstMatch(r);
    if (m != null) return int.tryParse(m.group(1)!) ?? 0;
    if (r.contains('hd') && !r.contains('480')) return 720;
    if (r.contains('sd') || r.contains('480')) return 480;
    return 0;
  }

  /// The format list for the active language: groups by resolution, picks the best/lightest
  List<_ResPick> _resolutionPicks() {
    final pool = _currentPool;
    final byHeight = <int, List<MovieSource>>{};
    for (final s in pool) {
      byHeight.putIfAbsent(heightOf(s), () => []).add(s);
    }
    final picks = <_ResPick>[];
    final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final h in heights) {
      final files = byHeight[h]!;
      files.sort((a, b) {
        if (a.isFastBDIX && !b.isFastBDIX) return -1;
        if (!a.isFastBDIX && b.isFastBDIX) return 1;
        final sa = _sizeMb(a), sb = _sizeMb(b);
        if (sa == 0 && sb != 0) return 1;
        if (sb == 0 && sa != 0) return -1;
        return sa.compareTo(sb);
      });
      final best = files.first;
      String label;
      String shortBadge;
      if (h >= 2160) {
        label = '4K UHD (2160p)';
        shortBadge = '4K';
      } else if (h == 1440) {
        label = '2K QHD (1440p)';
        shortBadge = '2K';
      } else if (h == 1080) {
        label = 'Full HD (1080p)';
        shortBadge = '1080p';
      } else if (h == 720) {
        label = 'HD (720p)';
        shortBadge = '720p';
      } else if (h == 480) {
        label = 'SD (480p)';
        shortBadge = '480p';
      } else if (h > 0) {
        label = '${h}p';
        shortBadge = '${h}p';
      } else {
        label = best.resolution.isNotEmpty && best.resolution != '-'
            ? best.resolution
            : 'Auto / HD';
        shortBadge = 'HD';
      }
      picks.add(
        _ResPick(
          label: label,
          shortBadge: shortBadge,
          height: h,
          best: best,
          fileCount: files.length,
          sources: files,
        ),
      );
    }
    return picks;
  }

  bool _isDownloading = false;

  /// Step 2 of download: a format is already picked — ask the user which
  /// repository/source actually carries this movie in that resolution, then
  /// download from the chosen source.
  Future<void> _openSourcePicker() async {
    final picks = _resolutionPicks();
    if (picks.isEmpty) return;
    final wantedHeight = _selectedResPick?.height;
    final pick = picks.firstWhere(
      (p) => wantedHeight != null
          ? p.height == wantedHeight
          : _checkedResolutions.contains(p.label),
      orElse: () => picks.first,
    );
    setState(() => _selectedSource = pick.best);
    if (!mounted) return;

    final chosen = await MovieSourcePickerSheet.show(
      context,
      movie: widget.movie,
      initialSources: pick.sources,
      height: pick.height,
      formatLabel: pick.shortBadge,
    );
    if (!mounted || chosen == null) return;
    setState(() => _selectedSource = chosen);
    await _handleDownloadSource(chosen);
  }

  Future<void> _handleDownloadSource(MovieSource source) async {
    if (_isDownloading) return;

    var s = source;
    var effectiveUrl = s.downloadUrl.isNotEmpty ? s.downloadUrl : s.streamUrl;
    if (!widget.selectedSourceOnly &&
        effectiveUrl.isEmpty &&
        _effectiveSources.isNotEmpty) {
      s = _effectiveSources.first;
      effectiveUrl = s.downloadUrl.isNotEmpty ? s.downloadUrl : s.streamUrl;
    }
    if (effectiveUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No playable download URL found for this server.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    if (s.downloadUrl.isEmpty) {
      s = s.copyWith(downloadUrl: effectiveUrl, streamUrl: effectiveUrl);
    }

    setState(() => _isDownloading = true);
    try {
      final hasPerm = await PermissionService.instance.hasStoragePermission();
      if (!hasPerm) {
        final granted = await PermissionService.instance
            .requestStoragePermission();
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Storage permission is required to save downloads.',
                ),
                backgroundColor: Colors.redAccent,
              ),
            );
          }
          return;
        }
      }
      if (!mounted) return;

      final titleToUse = widget.movie.title;
      final movieToDownload = widget.movie.copyWith(sources: _effectiveSources);

      await DownloadManager.instance.startMovieDownload(
        movie: movieToDownload,
        source: s,
        customTitle: titleToUse,
      );

      if (mounted) {
        Navigator.of(context).pop();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.darkCard,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            duration: const Duration(seconds: 4),
            content: Row(
              children: [
                const Icon(
                  Icons.download_done_rounded,
                  color: AppColors.primary,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Downloading "$titleToUse"',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${s.resolution} • ${s.repoName.isNotEmpty ? s.repoName : s.serverName}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not start download: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  MovieItem _movieWithSources() =>
      widget.movie.copyWith(sources: _effectiveSources);

  void _handleStream({double? resumePosition}) {
    if (_effectiveSources.every(
      (s) => (s.streamUrl.isNotEmpty ? s.streamUrl : s.downloadUrl).isEmpty,
    )) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No playable source resolved yet.')),
        );
      }
      return;
    }
    Navigator.pop(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MoviePlayerScreen(
          movie: _movieWithSources(),
          initialSource: _activeSource,
          initialPositionSeconds: resumePosition ?? 0.0,
        ),
      ),
    );
  }

  void _handleTrailer() {
    Navigator.pop(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MoviePlayerScreen(
          movie: widget.movie,
          initialSource: const MovieSource(
            serverName: 'Trailer',
            resolution: 'HD',
            downloadUrl: '',
            fileSize: '',
          ),
          trailerOnly: true,
        ),
      ),
    );
  }

  void _handleExternalStream() async {
    final src = _activeSource;
    final url = src.streamUrl.isNotEmpty ? src.streamUrl : src.downloadUrl;
    if (url.isNotEmpty) {
      try {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
        }
      } catch (_) {}
    }
  }

  Widget _buildMoreLikeThis(bool isDark) {
    if (!PreferenceService.instance.hasEnoughSignal) {
      return const SizedBox.shrink();
    }
    final me = widget.movie.title.toLowerCase().trim();
    final pool = MovieRepositoryService.instance
        .getAllMovies()
        .where((m) => m.title.toLowerCase().trim() != me)
        .toList();
    final similar = MovieRepositoryService.instance.getSimilarMovies(
      pool,
      fromHistory: [widget.movie],
      limit: 10,
    );
    if (similar.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.explore_rounded, size: 18, color: AppColors.primary),
            SizedBox(width: 6),
            Text(
              'More Like This',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 190,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: similar.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) =>
                SizedBox(width: 116, child: MovieCard(movie: similar[index])),
          ),
        ),
      ],
    );
  }

  Widget _buildActiveSourceBanner(bool isDark) {
    final active = _activeSource;
    final repoName = active.repoName.isNotEmpty
        ? active.repoName
        : (widget.movie.repoName.isNotEmpty
              ? widget.movie.repoName
              : 'Zangetsu JS Providers');
    final providerName = active.providerName.isNotEmpty
        ? active.providerName
        : (widget.movie.providerName.isNotEmpty
              ? widget.movie.providerName
              : 'Source Provider');
    final serverName = active.serverName.isNotEmpty
        ? active.serverName
        : providerName;
    final sourceCount = _effectiveSources.length;

    return Container(
      margin: const EdgeInsets.only(top: 14, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(Icons.dns_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'INSIDE SOURCE',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'ONLINE',
                        style: TextStyle(
                          color: Colors.green,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$providerName • $repoName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                Text(
                  'Active server: $serverName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _openSourcePicker,
            icon: const Icon(Icons.swap_horiz_rounded, size: 14),
            label: Text(
              sourceCount > 1 ? '$sourceCount Sources' : 'Change',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageSelector(bool isDark) {
    final languages = _getAvailableLanguages();
    if (languages.isEmpty) return const SizedBox.shrink();

    final activeKey = _selectedLanguageKey ?? languages.first.key;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.language_rounded,
              size: 18,
              color: AppColors.primary,
            ),
            const SizedBox(width: 6),
            const Text(
              '1. Select Audio / Language',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const Spacer(),
            Text(
              '${languages.length} Language${languages.length > 1 ? "s" : ""}',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: languages.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final lang = languages[i];
              final isSelected = lang.key == activeKey;
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: isSelected
                      ? null
                      : () => setState(() {
                          _selectedLanguageKey = lang.key;
                          _selectedResPick = null;
                          _selectedSource = null;
                          _checkedResolutions.clear();
                        }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary.withValues(
                              alpha: isDark ? 0.16 : 0.10,
                            )
                          : (isDark ? AppColors.darkCard : AppColors.lightCard),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          lang.label,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: isSelected
                                ? (isDark
                                      ? AppColors.primaryLight
                                      : AppColors.primaryDark)
                                : (isDark ? Colors.white70 : Colors.black87),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.25)
                                : (isDark
                                      ? Colors.white12
                                      : Colors.black.withValues(alpha: 0.08)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${lang.formatCount}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              color: isSelected
                                  ? Colors.white
                                  : (isDark ? Colors.white70 : Colors.black87),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResolutionCard(bool isDark, _ResPick pick, int activeHeight) {
    final s = pick.best;
    final isSelected = activeHeight == pick.height;
    final sizeText = s.fileSize.isNotEmpty ? s.fileSize : 'size unknown';

    final sourceProvider = s.providerName.isNotEmpty
        ? s.providerName
        : (s.repoName.isNotEmpty ? s.repoName : 'Server');
    final serverName = s.serverName.isNotEmpty ? s.serverName : sourceProvider;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isSelected
            ? AppColors.primary.withValues(alpha: 0.12)
            : (isDark ? AppColors.darkCard : AppColors.lightCard),
        borderRadius: BorderRadius.circular(16),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() {
            _selectedResPick = pick;
            _selectedSource = s;
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Resolution Badge
                    Container(
                      width: 54,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary
                            : (isDark
                                  ? Colors.white10
                                  : Colors.black.withValues(alpha: 0.05)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        pick.shortBadge,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: isSelected
                              ? Colors.white
                              : (isDark ? Colors.white : Colors.black87),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  pick.label,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: isSelected
                                        ? AppColors.primary
                                        : null,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (s.isFastBDIX) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.accentGold,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'BDIX',
                                    style: TextStyle(
                                      color: Colors.black,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '$sourceProvider • $serverName',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: (isDark
                                      ? Colors.white10
                                      : Colors.black.withValues(alpha: 0.05)),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  s.format.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              if (!widget.selectedSourceOnly) ...[
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    pick.fileCount > 1
                                        ? '${pick.fileCount} sources / repos available'
                                        : 'Direct Playable Server',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: isDark
                                          ? Colors.white38
                                          : Colors.black38,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // File size & selection icon
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          sizeText,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w900,
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.accentGreen,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Icon(
                          isSelected
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: isSelected ? AppColors.primary : Colors.grey,
                          size: 24,
                        ),
                      ],
                    ),
                  ],
                ),
                if (!widget.selectedSourceOnly) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.folder_special_rounded,
                        size: 13,
                        color: isSelected
                            ? AppColors.primary
                            : (isDark ? Colors.white54 : Colors.black45),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          pick.fileCount > 1
                              ? '${pick.fileCount} Repositories offering this format'
                              : 'Available in repository mirror',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: isSelected
                                ? AppColors.primary
                                : (isDark ? Colors.white60 : Colors.black54),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        'Tap Next to choose repo â†’',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? AppColors.primary
                              : (isDark ? Colors.white38 : Colors.black38),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLanguageAndFormatSection(bool isDark) {
    if (_resolving && _effectiveSources.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard : AppColors.lightCard,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: AppColors.primary,
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.selectedSourceOnly
                        ? 'Loading languages and formats…'
                        : 'Scanning all repositories for languages & formats...',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (_effectiveSources.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard : AppColors.lightCard,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accentGold.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.movie_filter_rounded,
                    color: AppColors.accentGold,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'No Streams Found Right Now',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              widget.selectedSourceOnly
                  ? 'This source has no playable formats for this title right now.'
                  : 'None of the active repositories or providers have a playable stream or download for "${widget.movie.title}" right now. This title may be an upcoming cinema release (${widget.movie.year}).',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _resolveStreams,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(
                      Icons.refresh_rounded,
                      size: 16,
                      color: AppColors.primary,
                    ),
                    label: const Text(
                      'Retry Search',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _handleTrailer,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(
                      Icons.theaters_rounded,
                      size: 16,
                      color: Colors.black,
                    ),
                    label: const Text(
                      'Watch Trailer',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final picks = _resolutionPicks();
    final activeHeight = heightOf(_activeSource);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLanguageSelector(isDark),
        const SizedBox(height: 16),
        Row(
          children: [
            const Icon(
              Icons.video_settings_rounded,
              size: 18,
              color: AppColors.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '2. Available Formats ($_selectedLanguageName)',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '(${picks.length} Format${picks.length > 1 ? "s" : ""})',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
            if (_sizesProbing) const SizedBox(width: 6),
            if (_sizesProbing)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accentGreen,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Select your format to stream or download (${_currentPool.length} streams found):',
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
        ),
        const SizedBox(height: 10),
        for (final p in picks) _buildResolutionCard(isDark, p, activeHeight),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final movie = widget.movie;

    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(
            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
            width: 1.5,
          ),
        ),
      ),
      child: Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.grey.shade400,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              children: [
                // Backdrop banner with scrim
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    children: [
                      AspectRatio(
                        aspectRatio: 16 / 9,
                        child: SmartNetworkImage(
                          url: movie.backdropUrl.isNotEmpty
                              ? movie.backdropUrl
                              : movie.posterUrl,
                          fit: BoxFit.cover,
                          placeholderColor: AppColors.darkCard,
                          placeholderIcon: Icons.movie_rounded,
                          accentColor: AppColors.primary,
                        ),
                      ),
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.9),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 16,
                        left: 16,
                        right: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              movie.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(
                                  Icons.star_rounded,
                                  color: Colors.amber,
                                  size: 18,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${movie.rating} / 10',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  '${movie.year} • ${movie.duration}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    movie.quality,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Active Source Context Banner (Zangetsu style source indicator)
                if (widget.selectedSourceOnly)
                  _buildLanguageAndFormatSection(isDark)
                else
                  _buildActiveSourceBanner(isDark),

                const SizedBox(height: 10),

                // Genres tags
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: movie.genres.map((g) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppColors.darkCard
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        g,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    );
                  }).toList(),
                ),

                const SizedBox(height: 14),

                // Synopsis
                const Text(
                  'Overview',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 6),
                Text(
                  movie.synopsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: isDark
                        ? AppColors.darkTextSecondary
                        : AppColors.lightTextSecondary,
                  ),
                ),

                const SizedBox(height: 18),

                // Personalized "More Like This"
                _buildMoreLikeThis(isDark),

                const SizedBox(height: 18),

                // Language selection first â†’ Available formats for that language
                if (!widget.selectedSourceOnly)
                  _buildLanguageAndFormatSection(isDark),

                const SizedBox(height: 24),
              ],
            ),
          ),

          // Bottom actions — two calm primaries, extras tucked into a menu.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : Colors.white,
              border: Border(
                top: BorderSide(
                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  // Stream / Play / Resume
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final history = WatchHistoryService.instance
                            .getProgress(widget.movie.id);
                        final hasProgress =
                            history != null && history.positionSeconds > 10;
                        return OutlinedButton.icon(
                          onPressed: _effectiveSources.isEmpty
                              ? null
                              : () => _handleStream(
                                  resumePosition: hasProgress
                                      ? history.positionSeconds
                                      : 0.0,
                                ),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            foregroundColor: _effectiveSources.isEmpty
                                ? Colors.grey
                                : AppColors.primary,
                          ),
                          icon: Icon(
                            hasProgress
                                ? Icons.play_circle_outline_rounded
                                : Icons.play_arrow_rounded,
                            size: 19,
                          ),
                          label: Text(
                            hasProgress
                                ? 'Resume ${history.positionFormatted}'
                                : 'Watch',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Next — choose which repo/source carries this format
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (_isDownloading || _effectiveSources.isEmpty)
                          ? null
                          : widget.selectedSourceOnly
                          ? () => _handleDownloadSource(_activeSource)
                          : _openSourcePicker,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        disabledBackgroundColor: isDark
                            ? Colors.white12
                            : Colors.grey.shade300,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: _isDownloading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              widget.selectedSourceOnly
                                  ? Icons.download_rounded
                                  : Icons.arrow_forward_rounded,
                              size: 19,
                            ),
                      label: Text(
                        _isDownloading
                            ? 'Starting…'
                            : _effectiveSources.isEmpty
                            ? 'No formats'
                            : widget.selectedSourceOnly
                            ? 'Download'
                            : 'Next',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),

                  // Trailer / external player live here instead of cluttering the bar.
                  PopupMenuButton<String>(
                    color: isDark ? AppColors.darkCard : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                    onSelected: (value) {
                      if (value == 'trailer') _handleTrailer();
                      if (value == 'external') _handleExternalStream();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem<String>(
                        value: 'trailer',
                        child: Row(
                          children: [
                            Icon(
                              Icons.theaters_outlined,
                              size: 18,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'Watch trailer',
                              style: TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'external',
                        enabled: _effectiveSources.isNotEmpty,
                        child: Row(
                          children: [
                            Icon(
                              Icons.connected_tv_outlined,
                              size: 18,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'Open in external player',
                              style: TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguageOption {
  final String key;
  final String label;
  final List<MovieSource> sources;

  const _LanguageOption({
    required this.key,
    required this.label,
    required this.sources,
  });

  int get formatCount {
    final set = <int>{};
    for (final s in sources) {
      set.add(_MovieDetailSheetState.heightOf(s));
    }
    return set.isEmpty ? sources.length : set.length;
  }
}

class _ResPick {
  final String label;
  final String shortBadge;
  final int height;
  final MovieSource best;
  final int fileCount;
  final List<MovieSource> sources;

  const _ResPick({
    required this.label,
    required this.shortBadge,
    required this.height,
    required this.best,
    required this.fileCount,
    required this.sources,
  });
}
