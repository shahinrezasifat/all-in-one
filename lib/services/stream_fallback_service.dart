import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/movie_model.dart';
import 'inner_tube_service.dart';
import 'movie_repository_service.dart';

/// Result of probing one provider/server stream for connectivity + validity.
class ProviderStreamReport {
  final MovieSource source;
  final bool reachable;
  final bool validStream;
  final int latencyMs;
  final String statusText;

  const ProviderStreamReport({
    required this.source,
    required this.reachable,
    required this.validStream,
    required this.latencyMs,
    this.statusText = '',
  });

  /// Higher is better: playable stream first, then reachability, then latency,
  /// with small boosts for BDIX mirrors and the title's native provider.
  double get score {
    double s = 0;
    if (validStream) s += 10000;
    if (reachable) s += 5000;
    if (latencyMs > 0) s -= latencyMs.clamp(0, 4000) * 1.5;
    if (source.isFastBDIX) s += 1500;
    final res = source.resolution.toLowerCase();
    if (res.contains('4k') || res.contains('2160')) {
      s += 400;
    } else if (res.contains('1080')) {
      s += 300;
    } else if (res.contains('720')) {
      s += 200;
    }
    return s;
  }
}

/// Multi-Provider Fallback engine for movie playback.
///
/// For a given title it:
///  1. Discovers every candidate stream offered by ALL installed & active
///     providers/repositories (not just the provider the movie was opened from).
///  2. Probes each candidate in parallel for connectivity + stream validity
///     (HTTP Range request, content-type sniffing, latency measurement).
///  3. Ranks the results so the player tries the fastest healthy server first
///     and automatically falls forward to the next provider on failure.
class StreamFallbackService {
  static final StreamFallbackService instance = StreamFallbackService._();
  StreamFallbackService._();

  final http.Client _client = http.Client();

  // Validation cache: title key -> reports (TTL 5 minutes)
  final Map<String, _ValidationCacheEntry> _cache = {};
  static const Duration _cacheTtl = Duration(minutes: 5);

  static const Map<String, String> _headers = {
    'User-Agent': _userAgent,
    'Accept': '*/*',
    'Connection': 'close',
  };

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  static bool _isGoogleVideoUrl(String url) =>
      url.contains('googlevideo.com') || url.contains('youtube.com');

  /// Headers the native player should send with a stream request. Many CDNs
  /// reject raw ExoPlayer/AVPlayer requests (403) unless a browser-like
  /// User-Agent and same-origin Referer are present.
  static Map<String, String> streamHeadersFor(String url) {
    final headers = <String, String>{};
    // YouTube/googlevideo stream URLs (audio & video) are signed by one
    // specific InnerTube client, so the player must present that same
    // identity or the CDN silently returns 403 and nothing decodes.
    if (_isGoogleVideoUrl(url)) {
      headers['User-Agent'] = InnerTubeService.userAgentForUrl(url);
      return headers;
    }
    headers['User-Agent'] = _userAgent;
    try {
      final uri = Uri.parse(url);
      if ((uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        final origin =
            '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
        headers['Referer'] = '$origin/';
        // Several IPTV/Xtream CDNs require Origin in addition to Referer.
        headers['Origin'] = origin;
        headers['Accept'] = '*/*';
      }
    } catch (_) {}
    return headers;
  }

  static String sourceKey(MovieSource s) =>
      '${(s.streamUrl.isNotEmpty ? s.streamUrl : s.downloadUrl).trim()}|${s.serverName}';

  String _normalizeTitle(String t) =>
      t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u0980-\u09ff]'), '');

  String _cacheKey(MovieItem movie, int season, int episode) =>
      '${_normalizeTitle(movie.title)}|$season|$episode';

  void clearCache() => _cache.clear();

  bool _isProvidedByInstalledExtension(
    MovieSource s,
    Set<String> installedIds,
    Set<String> installedNames,
  ) {
    final pid = s.providerId.toLowerCase().trim();
    final pname = s.providerName.toLowerCase().trim();
    if (pid.isEmpty && pname.isEmpty)
      return true; // generic/local sources always allowed
    return installedIds.contains(pid) ||
        installedNames.contains(pid) ||
        installedIds.contains(pname) ||
        installedNames.contains(pname);
  }

  /// Step 1: Aggregate every candidate stream for this title across ALL
  /// installed & active providers — the movie's own servers, the same title
  /// scraped from other providers, the current episode's servers (series),
  /// and the universal CDN mirrors as a guaranteed final fallback.
  List<MovieSource> discoverStreams(
    MovieItem movie, {
    MovieSource? primary,
    int season = 1,
    int episode = 1,
  }) {
    final repo = MovieRepositoryService.instance;
    final installed = repo.getInstalledActiveProviders();
    final installedIds = installed
        .map((p) => p.id.toLowerCase().trim())
        .toSet();
    final installedNames = installed
        .map((p) => p.name.toLowerCase().trim())
        .toSet();

    // A live provider item (has a detail permalink) already carries REAL,
    // freshly-resolved streams from its JS scraper. Those must always be
    // played — never gate them behind the installed-extension allow-list.
    final isProviderItem = movie.detailUrl.trim().isNotEmpty;

    final candidates = <MovieSource>[];
    final seenUrls = <String>{};

    void add(MovieSource s) {
      final url = s.streamUrl.isNotEmpty ? s.streamUrl : s.downloadUrl;
      if (url.isEmpty) return;
      if (!isProviderItem &&
          !_isProvidedByInstalledExtension(s, installedIds, installedNames)) {
        return;
      }
      // Dedupe by URL + server so one dead CDN edge is only tested once.
      final dedupeKey = s.streamUrl.isNotEmpty ? s.streamUrl : s.downloadUrl;
      final combo = '$dedupeKey|${s.serverName}';
      if (seenUrls.contains(combo)) return;
      seenUrls.add(combo);
      candidates.add(s);
    }

    // 1. The user's explicitly chosen server first (fastest path on retry).
    if (primary != null) add(primary);

    // 2. Current episode servers for series.
    if (movie.isSeries) {
      for (final s in movie.seasons) {
        if (s.seasonNumber != season) continue;
        for (final ep in s.episodes) {
          if (ep.episodeNumber != episode) continue;
          ep.sources.forEach(add);
        }
      }
    }

    // 3. Every server listed on this movie item.
    movie.sources.forEach(add);

    // 4. Cross-provider sweep: same title offered by any OTHER installed
    //    provider/repository in the unified catalog.
    final normTitle = _normalizeTitle(movie.title);
    for (final m in repo.getAllMovies()) {
      if (_normalizeTitle(m.title) == normTitle) {
        m.sources.forEach(add);
      }
    }

    // 5. Explicit per-provider lookup so every single installed extension is
    //    asked for this title, maximizing the chance of a working stream.
    for (final p in installed) {
      for (final m in repo.getMoviesForProvider(p.id)) {
        if (_normalizeTitle(m.title) == normTitle) {
          m.sources.forEach(add);
        }
      }
    }

    // NOTE: No fake "universal" sample-clip mirrors are appended. If the real
    // provider servers all fail, playback must report failure — it must NEVER
    // silently fall back to a demo clip or a trailer.

    return candidates;
  }

  /// Step 2: Probe one candidate for connectivity + stream validity.
  /// Uses a Range GET (first 16 KB) so large files are never fully downloaded.
  Future<ProviderStreamReport> probe(
    MovieSource s, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final url = (s.streamUrl.isNotEmpty ? s.streamUrl : s.downloadUrl).trim();
    if (url.isEmpty) {
      return ProviderStreamReport(
        source: s,
        reachable: false,
        validStream: false,
        latencyMs: 0,
        statusText: 'No URL',
      );
    }

    // Local file (downloaded copy / desktop path)
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      final exists = await File(url).exists();
      return ProviderStreamReport(
        source: s,
        reachable: exists,
        validStream: exists,
        latencyMs: 0,
        statusText: exists ? 'Local file' : 'File missing',
      );
    }

    final sw = Stopwatch()..start();
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(_headers);
      if (s.headers.isNotEmpty) request.headers.addAll(s.headers);
      request.headers['Range'] = 'bytes=0-16383';

      final response = await _client.send(request).timeout(timeout);
      final status = response.statusCode;
      final contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();

      // Read just enough bytes to confirm data actually flows, then cancel.
      int bytes = 0;
      final firstChunk = Completer<bool>();
      late StreamSubscription<List<int>> sub;
      sub = response.stream.listen(
        (chunk) {
          bytes += chunk.length;
          if (!firstChunk.isCompleted && bytes >= 1024)
            firstChunk.complete(true);
        },
        onDone: () {
          if (!firstChunk.isCompleted) firstChunk.complete(bytes > 0);
        },
        onError: (_) {
          if (!firstChunk.isCompleted)
            firstChunk.completeError(Exception('stream error'));
        },
      );

      bool gotData = false;
      try {
        gotData = await firstChunk.future.timeout(timeout);
      } catch (_) {
        gotData = false;
      }
      await sub.cancel();
      sw.stop();

      final reachable = status >= 200 && status < 400 && gotData;
      // An HTML body means a dead redirect/portal page, not a video stream.
      final looksLikeHtml = contentType.contains('text/html');
      final validStream = reachable && !looksLikeHtml;

      return ProviderStreamReport(
        source: s,
        reachable: reachable,
        validStream: validStream,
        latencyMs: sw.elapsedMilliseconds,
        statusText: !reachable
            ? (status >= 400 ? 'HTTP $status' : 'No data / timeout')
            : (validStream
                  ? 'OK ${sw.elapsedMilliseconds}ms'
                  : 'Not a video stream'),
      );
    } catch (e) {
      sw.stop();
      return ProviderStreamReport(
        source: s,
        reachable: false,
        validStream: false,
        latencyMs: sw.elapsedMilliseconds,
        statusText: e is TimeoutException
            ? 'Slow / unreachable'
            : 'Connection failed',
      );
    }
  }

  /// Steps 2 + 3: Validate all providers' streams for a title in parallel and
  /// return them ranked best-first. Results are cached briefly per title.
  Future<List<ProviderStreamReport>> validateAcrossProviders(
    MovieItem movie, {
    MovieSource? primary,
    int season = 1,
    int episode = 1,
    bool forceRescan = false,
  }) async {
    final key = _cacheKey(movie, season, episode);
    if (!forceRescan) {
      final cached = _cache[key];
      if (cached != null && DateTime.now().difference(cached.at) < _cacheTtl) {
        return cached.reports;
      }
    }

    final candidates = discoverStreams(
      movie,
      primary: primary,
      season: season,
      episode: episode,
    );
    if (candidates.isEmpty) return const [];

    // Probe every provider concurrently; single failures never block the rest.
    final probes = await Future.wait(
      candidates.map(
        (s) => probe(s).catchError((e) {
          debugPrint('Probe error for ${s.serverName}: $e');
          return ProviderStreamReport(
            source: s,
            reachable: false,
            validStream: false,
            latencyMs: 0,
            statusText: 'Probe crashed',
          );
        }),
      ),
    );

    probes.sort((a, b) => b.score.compareTo(a.score));
    _cache[key] = _ValidationCacheEntry(reports: probes, at: DateTime.now());
    return probes;
  }
}

class _ValidationCacheEntry {
  final List<ProviderStreamReport> reports;
  final DateTime at;
  _ValidationCacheEntry({required this.reports, required this.at});
}
