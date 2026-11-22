/// Typed results decoded from a Zangetsu JS provider's return values.
///
/// These mirror the shapes the providers emit from `search()`, `getHome()`,
/// `getDetail()` and `getVideoSources()`, so the rest of the app never has to
/// touch raw JSON.
library;

import '../../models/movie_model.dart';

/// Normalize a resolution only when the provider supplies one.
String providerResolution(
  String quality, {
  Iterable<String> labels = const [],
}) {
  final explicitHeight = RegExp(
    r'^(2160|1440|1080|720|576|540|480|360|240|144)p?$',
    caseSensitive: false,
  ).firstMatch(quality.trim());
  if (explicitHeight != null) return '${explicitHeight[1]}p';
  for (final value in [quality, ...labels]) {
    final height = RegExp(
      r'\b(2160|1440|1080|720|576|540|480|360|240|144)p\b',
      caseSensitive: false,
    ).firstMatch(value);
    if (height != null) return '${height[1]}p';
    if (RegExp(r'\b4[ .-]?k\b|\bUHD\b', caseSensitive: false).hasMatch(value)) {
      return '2160p';
    }
  }
  return 'Auto';
}

class ProviderStream {
  final String url;
  final String quality;
  final String container; // 'hls' | 'mp4'
  final String label;
  final Map<String, String> headers;
  final List<ProviderSub> subtitles;

  ProviderStream({
    required this.url,
    this.quality = 'auto',
    this.container = 'mp4',
    this.label = '',
    this.headers = const {},
    this.subtitles = const [],
  });

  factory ProviderStream.fromJson(Map<String, dynamic> j) {
    final h = j['headers'];
    final headers = <String, String>{};
    if (h is Map) {
      h.forEach((k, v) => headers[k.toString()] = v?.toString() ?? '');
    }
    final subs = <ProviderSub>[];
    if (j['subtitles'] is List) {
      for (final s in (j['subtitles'] as List)) {
        if (s is Map)
          subs.add(ProviderSub.fromJson(Map<String, dynamic>.from(s)));
      }
    }
    return ProviderStream(
      url: (j['url'] ?? '').toString(),
      quality: (j['quality'] ?? 'auto').toString(),
      container: (j['container'] ?? 'mp4').toString(),
      label: (j['label'] ?? '').toString(),
      headers: headers,
      subtitles: subs,
    );
  }
}

class ProviderSub {
  final String url;
  final String lang;
  final String label;
  final String format;
  ProviderSub.fromJson(Map<String, dynamic> j)
    : url = (j['url'] ?? '').toString(),
      lang = (j['lang'] ?? '').toString(),
      label = (j['label'] ?? j['lang'] ?? 'Subtitles').toString(),
      format = (j['format'] ?? 'srt').toString();
}

class ProviderEpisode {
  final String id;
  final int number;
  final String url;
  final String title;
  final int? season;
  final String? group;
  ProviderEpisode({
    required this.id,
    required this.number,
    required this.url,
    required this.title,
    this.season,
    this.group,
  });

  factory ProviderEpisode.fromJson(Map<String, dynamic> j) => ProviderEpisode(
    id: (j['id'] ?? '').toString(),
    number: int.tryParse((j['number'] ?? 1).toString()) ?? 1,
    url: (j['url'] ?? '').toString(),
    title: (j['title'] ?? 'Episode').toString(),
    season: int.tryParse('${j['season'] ?? ''}'),
    group: j['group']?.toString(),
  );
}

class ProviderMeta {
  final String id;
  final String title;
  final String cover;
  final String url; // provider detail permalink (→ getDetail / getVideoSources)
  final String type; // 'movie' | 'series'
  final String sourceId;
  final String description;
  final List<String> genres;
  final List<String> catalogGroups;
  final String year;
  final List<ProviderEpisode> episodes;

  ProviderMeta({
    required this.id,
    required this.title,
    required this.cover,
    required this.url,
    required this.type,
    required this.sourceId,
    this.description = '',
    this.genres = const [],
    this.catalogGroups = const [],
    this.year = '',
    this.episodes = const [],
  });

  factory ProviderMeta.fromJson(Map<String, dynamic> j) {
    final genres = <String>[];
    if (j['genres'] is List) {
      for (final g in (j['genres'] as List)) {
        genres.add(g.toString());
      }
    }
    final eps = <ProviderEpisode>[];
    if (j['episodes'] is List) {
      for (final e in (j['episodes'] as List)) {
        if (e is Map)
          eps.add(ProviderEpisode.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    final typeRaw = (j['type'] ?? '').toString().trim().toLowerCase();
    return ProviderMeta(
      id: (j['id'] ?? j['url'] ?? '').toString(),
      title: (j['title'] ?? 'Untitled').toString(),
      cover: (j['cover'] ?? j['poster'] ?? '').toString(),
      url: (j['url'] ?? j['id'] ?? '').toString(),
      type: switch (typeRaw) {
        _ when isLiveTvType(typeRaw) => 'liveTv',
        'series' || 'tv' || 'anime' || 'tvseries' => 'series',
        'movie' || 'film' || 'documentary' => 'movie',
        _ => 'unknown',
      },
      sourceId: (j['sourceId'] ?? '').toString(),
      description: (j['description'] ?? j['overview'] ?? '').toString(),
      genres: genres,
      catalogGroups: [
        ...?(j['sections'] as List?)?.whereType<String>(),
        if (j['groupTitle'] case final String group) group,
        if (j['country'] case final String country) 'Country: $country',
        if (j['language'] case final String language) 'Language: $language',
      ],
      year: (j['year'] ?? '').toString(),
      episodes: eps,
    );
  }
}

/// One home row from `getHome()` — a titled shelf of [ProviderMeta].
class ProviderHomeRow {
  final String title;
  final List<ProviderMeta> items;
  ProviderHomeRow({required this.title, required this.items});

  factory ProviderHomeRow.fromJson(Map<String, dynamic> j) {
    final items = <ProviderMeta>[];
    if (j['items'] is List) {
      for (final it in (j['items'] as List)) {
        if (it is Map)
          items.add(ProviderMeta.fromJson(Map<String, dynamic>.from(it)));
      }
    }
    return ProviderHomeRow(title: (j['title'] ?? '').toString(), items: items);
  }
}
