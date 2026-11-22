import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/movie_model.dart';
import 'provider_models.dart';

class CloudStreamRuntime {
  static const _channel = MethodChannel('snaptube_pure/cloudstream');
  static final _formatListeners = <int, void Function(MovieSource)>{};
  static int _nextFormatRequest = 0;

  static Future<void> _onPlatformCall(MethodCall call) async {
    if (call.method != 'resolvedFormat') return;
    final arguments = call.arguments as Map<Object?, Object?>;
    final listener = _formatListeners[arguments['requestId']];
    final row = arguments['format'];
    if (listener != null && row is Map<Object?, Object?>) {
      listener(_unscopedSource(row));
    }
  }

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool canRun(MovieProvider provider) =>
      provider.scriptUrl.isNotEmpty ||
      (supported && provider.cloudStreamUrl.isNotEmpty);

  static Future<void> install(String repoId, MovieProvider provider) =>
      _channel.invokeMethod<void>('install', {
        'repoId': repoId,
        'providerId': provider.id,
        'url': provider.cloudStreamUrl,
      });

  static Future<void> delete(String repoId, [String? providerId]) =>
      _channel.invokeMethod<void>('delete', {
        'repoId': repoId,
        'providerId': providerId,
      });

  static Future<List<MovieItem>> catalog(
    MovieRepository repo,
    MovieProvider provider,
    String query,
    int page,
  ) async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'catalog',
      {
        'repoId': repo.id,
        'providerId': provider.id,
        'query': query,
        'packageUrl': provider.cloudStreamUrl,
        'page': page,
      },
    );
    final items = <String, MovieItem>{};
    for (final row in rows ?? const []) {
      final url = row['url'];
      if (url is! String || url.isEmpty) continue;
      final type = row['type'] as String? ?? '';
      final groups = <String>{
        ...?items[url]?.catalogGroups,
        ...(row['sections'] as List?)?.whereType<String>() ?? const <String>[],
      };
      final genres = <String>{
        ...?items[url]?.genres,
        ..._sectionGenres(
          (row['sections'] as List?)?.whereType<String>() ?? const [],
        ),
        if (type == 'Anime' || type == 'AnimeMovie' || type == 'OVA') 'Anime',
        if (type == 'Cartoons') 'Animation',
        if (type == 'Documentary') 'Documentary',
      };
      items[url] = MovieItem(
        id: url,
        title: row['title'] as String,
        posterUrl: row['poster'] as String? ?? '',
        backdropUrl: row['poster'] as String? ?? '',
        year: 0,
        rating: 0,
        quality: '',
        genres: genres.toList(),
        catalogGroups: groups.toList(),
        synopsis: '',
        duration: '',
        sources: const [],
        detailUrl: url,
        episodeUrl: row['apiName'] as String,
        type: switch (type) {
          _ when isLiveTvType(type) || groups.any(isLiveTvType) => 'liveTv',
          'TvSeries' ||
          'Anime' ||
          'AsianDrama' ||
          'Cartoons' ||
          'OVA' => 'series',
          'Movie' || 'AnimeMovie' || 'Documentary' || 'Torrent' => 'movie',
          _ => 'unknown',
        },
        repoId: repo.id,
        repoName: repo.name,
        providerId: provider.id,
        providerName: provider.name,
      );
    }
    return items.values.toList();
  }

  static Iterable<String> _sectionGenres(Iterable<String> sections) {
    const genres = [
      'Action',
      'Adventure',
      'Animation',
      'Anime',
      'Comedy',
      'Crime',
      'Documentary',
      'Drama',
      'Family',
      'Fantasy',
      'History',
      'Horror',
      'Mystery',
      'Music',
      'Romance',
      'Science Fiction',
      'Thriller',
      'War',
      'Biography',
      'Sport',
      'Martial Arts',
      'Superhero',
      'Western',
    ];
    final labels = sections
        .join(' / ')
        .toLowerCase()
        .replaceAll(RegExp(r'sci[ -]?fi'), 'science fiction');
    return genres.where(
      (genre) => RegExp(r'\b' + genre.toLowerCase() + r'\b').hasMatch(labels),
    );
  }

  static Future<List<String>> genresFor(MovieItem item) async {
    final tags = await _channel.invokeListMethod<String>('genres', {
      'repoId': item.repoId,
      'providerId': item.providerId,
      'apiName': item.episodeUrl,
      'url': item.detailUrl,
    });
    return _sectionGenres(tags ?? const []).toList();
  }

  static Future<List<ProviderEpisode>> episodes(MovieItem item) async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'episodes',
      {
        'repoId': item.repoId,
        'providerId': item.providerId,
        'apiName': item.episodeUrl,
        'url': item.detailUrl,
      },
    );
    return [
      for (final row in rows ?? const [])
        if (row['url'] is String && (row['url'] as String).isNotEmpty)
          ProviderEpisode.fromJson(Map<String, dynamic>.from(row)),
    ];
  }

  static Future<List<MovieSource>> resolve(
    MovieItem item, {
    String? episodeData,
    void Function(List<MovieSource>)? onFormats,
  }) async {
    final requestId = onFormats == null ? null : ++_nextFormatRequest;
    MovieSource withProvider(MovieSource source) => source.copyWith(
      repoId: item.repoId,
      repoName: item.repoName,
      providerId: item.providerId,
      providerName: item.providerName,
    );
    if (requestId != null && onFormats != null) {
      if (_formatListeners.isEmpty) {
        _channel.setMethodCallHandler(_onPlatformCall);
      }
      _formatListeners[requestId] = (source) {
        if (_isWebUrl(source.downloadUrl)) onFormats([withProvider(source)]);
      };
    }
    try {
      final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'resolve',
        {
          'repoId': item.repoId,
          'providerId': item.providerId,
          'apiName': item.episodeUrl,
          'url': item.detailUrl,
          if (episodeData != null) 'episodeData': episodeData,
          if (requestId != null) 'requestId': requestId,
        },
      );
      return [
        for (final row in rows ?? const [])
          if (_isWebUrl(row['url'])) withProvider(_unscopedSource(row)),
      ];
    } finally {
      if (requestId != null) _formatListeners.remove(requestId);
    }
  }

  static bool _isWebUrl(Object? url) =>
      url is String &&
      (url.startsWith('http://') || url.startsWith('https://'));

  static MovieSource _unscopedSource(Map<Object?, Object?> row) {
    final url = row['url'] as String? ?? '';
    final name = row['name'] as String? ?? '';
    return MovieSource(
      serverName: name,
      resolution: providerResolution(
        (row['quality'] ?? '').toString(),
        labels: [name],
      ),
      downloadUrl: url,
      fileSize: '',
      format: row['hls'] == true ? 'm3u8' : _fileFormat(url),
      headers: Map<String, String>.from(row['headers'] as Map? ?? const {}),
    );
  }

  static String _fileFormat(String url) {
    final extension = Uri.tryParse(url)?.path.split('.').last.toLowerCase();
    return switch (extension) {
      'm3u8' ||
      'mpd' ||
      'mkv' ||
      'webm' ||
      'mov' ||
      'avi' ||
      'ts' => extension!,
      _ => 'mp4',
    };
  }
}
