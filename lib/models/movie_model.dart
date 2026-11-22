bool isLiveTvType(String value) => const {
  'live',
  'livetv',
  'livestream',
  'tvchannel',
  'tvchannels',
  'iptv',
  'livechannel',
}.contains(value.toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''));

class MovieSource {
  final String serverName;
  final String resolution;
  final String downloadUrl;
  final String streamUrl;
  final String fileSize;
  final String format;
  final String? hlsVariantResolution;
  final bool isFastBDIX;
  final String repoId;
  final String repoName;
  final String providerId;
  final String providerName;
  final Map<String, String> headers;

  const MovieSource({
    required this.serverName,
    required this.resolution,
    required this.downloadUrl,
    String? streamUrl,
    required this.fileSize,
    this.format = 'mp4',
    this.hlsVariantResolution,
    this.isFastBDIX = false,
    this.repoId = '',
    this.repoName = '',
    this.providerId = '',
    this.providerName = '',
    this.headers = const {},
  }) : streamUrl = streamUrl ?? downloadUrl;

  MovieSource copyWith({
    String? serverName,
    String? resolution,
    String? downloadUrl,
    String? streamUrl,
    String? fileSize,
    String? format,
    String? hlsVariantResolution,
    bool? isFastBDIX,
    String? repoId,
    String? repoName,
    String? providerId,
    String? providerName,
    Map<String, String>? headers,
  }) => MovieSource(
    serverName: serverName ?? this.serverName,
    resolution: resolution ?? this.resolution,
    downloadUrl: downloadUrl ?? this.downloadUrl,
    streamUrl: streamUrl ?? this.streamUrl,
    fileSize: fileSize ?? this.fileSize,
    format: format ?? this.format,
    hlsVariantResolution: hlsVariantResolution ?? this.hlsVariantResolution,
    isFastBDIX: isFastBDIX ?? this.isFastBDIX,
    repoId: repoId ?? this.repoId,
    repoName: repoName ?? this.repoName,
    providerId: providerId ?? this.providerId,
    providerName: providerName ?? this.providerName,
    headers: headers ?? this.headers,
  );

  Map<String, dynamic> toJson() => {
    'serverName': serverName,
    'resolution': resolution,
    'downloadUrl': downloadUrl,
    'streamUrl': streamUrl,
    'fileSize': fileSize,
    'format': format,
    if (hlsVariantResolution != null)
      'hlsVariantResolution': hlsVariantResolution,
    'isFastBDIX': isFastBDIX,
    'repoId': repoId,
    'repoName': repoName,
    'providerId': providerId,
    'providerName': providerName,
    'headers': headers,
  };

  factory MovieSource.fromJson(Map<String, dynamic> json) => MovieSource(
    serverName: json['serverName'] as String? ?? 'Primary Server',
    resolution: json['resolution'] as String? ?? '1080p',
    downloadUrl: json['downloadUrl'] as String? ?? '',
    streamUrl:
        json['streamUrl'] as String? ?? (json['downloadUrl'] as String? ?? ''),
    fileSize: json['fileSize'] as String? ?? '1.2 GB',
    format: json['format'] as String? ?? 'mp4',
    hlsVariantResolution: json['hlsVariantResolution'] as String?,
    isFastBDIX: json['isFastBDIX'] as bool? ?? false,
    repoId: json['repoId'] as String? ?? '',
    repoName: json['repoName'] as String? ?? '',
    providerId: json['providerId'] as String? ?? '',
    providerName: json['providerName'] as String? ?? '',
    headers:
        (json['headers'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, v.toString()),
        ) ??
        const {},
  );
}

class MovieEpisode {
  final int episodeNumber;
  final String title;
  final String duration;
  final String thumbnailUrl;
  final String synopsis;
  final List<MovieSource> sources;

  const MovieEpisode({
    required this.episodeNumber,
    required this.title,
    this.duration = '45m',
    this.thumbnailUrl = '',
    this.synopsis = '',
    this.sources = const [],
  });

  Map<String, dynamic> toJson() => {
    'episodeNumber': episodeNumber,
    'title': title,
    'duration': duration,
    'thumbnailUrl': thumbnailUrl,
    'synopsis': synopsis,
    'sources': sources.map((s) => s.toJson()).toList(),
  };

  factory MovieEpisode.fromJson(Map<String, dynamic> json) => MovieEpisode(
    episodeNumber: json['episodeNumber'] as int? ?? 1,
    title: json['title'] as String? ?? 'Episode 1',
    duration: json['duration'] as String? ?? '45m',
    thumbnailUrl: json['thumbnailUrl'] as String? ?? '',
    synopsis: json['synopsis'] as String? ?? '',
    sources:
        (json['sources'] as List<dynamic>?)
            ?.map((e) => MovieSource.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
  );
}

class MovieSeason {
  final int seasonNumber;
  final String title;
  final List<MovieEpisode> episodes;

  const MovieSeason({
    required this.seasonNumber,
    required this.title,
    required this.episodes,
  });

  Map<String, dynamic> toJson() => {
    'seasonNumber': seasonNumber,
    'title': title,
    'episodes': episodes.map((e) => e.toJson()).toList(),
  };

  factory MovieSeason.fromJson(Map<String, dynamic> json) => MovieSeason(
    seasonNumber: json['seasonNumber'] as int? ?? 1,
    title: json['title'] as String? ?? 'Season 1',
    episodes:
        (json['episodes'] as List<dynamic>?)
            ?.map((e) => MovieEpisode.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
  );
}

class MovieItem {
  final String id;
  final String title;
  final String posterUrl;
  final String backdropUrl;
  final int year;
  final double rating;
  final String quality;
  final List<String> genres;
  final String type;
  final List<String> catalogGroups;
  final String synopsis;
  final String duration;
  final String repoId;
  final String repoName;
  final String providerId;
  final String providerName;

  /// Provider detail permalink — the JS provider's `getDetail()` /
  /// `getVideoSources()` input for a live (non-cached) title.
  final String detailUrl;

  /// The specific episode/source url inside [detailUrl] that streams resolve
  /// against (packed hrefs list for HDHub4u-style providers).
  final String episodeUrl;
  final List<MovieSource> sources;
  final List<MovieSeason> seasons;
  final List<String> audioTracks;
  final List<String> subtitles;

  final List<String> availableRepos;
  final List<String> availableProviders;

  const MovieItem({
    required this.id,
    required this.title,
    required this.posterUrl,
    required this.backdropUrl,
    required this.year,
    required this.rating,
    required this.quality,
    required this.genres,
    required this.type,
    this.catalogGroups = const [],
    required this.synopsis,
    required this.duration,
    required this.repoId,
    required this.repoName,
    this.providerId = '',
    this.providerName = '',
    this.detailUrl = '',
    this.episodeUrl = '',
    required this.sources,
    this.availableRepos = const [],
    this.availableProviders = const [],
    this.seasons = const [],
    this.audioTracks = const [
      'Bengali (Original)',
      'Hindi Dub',
      'English 5.1 Dolby',
    ],
    this.subtitles = const ['English', 'Bengali', 'Off'],
  });

  bool get isLiveTv => isLiveTvType(type) || catalogGroups.any(isLiveTvType);

  bool get isSeries =>
      const [
        'series',
        'tvseries',
        'tv series',
        'anime',
        'asiandrama',
        'cartoons',
        'ova',
      ].contains(type.toLowerCase().trim()) ||
      seasons.isNotEmpty;

  bool get isAnime =>
      const [
        'anime',
        'animemovie',
        'ova',
      ].contains(type.toLowerCase().trim()) ||
      genres.any((genre) => genre.toLowerCase().trim() == 'anime');

  List<String> get allRepos {
    final set = <String>{};
    if (repoName.isNotEmpty) set.add(repoName);
    set.addAll(availableRepos);
    for (final s in sources) {
      if (s.repoName.isNotEmpty) set.add(s.repoName);
    }
    return set.toList();
  }

  List<String> get allProviders {
    final set = <String>{};
    if (providerName.isNotEmpty) set.add(providerName);
    if (providerId.isNotEmpty) set.add(providerId);
    set.addAll(availableProviders);
    for (final s in sources) {
      if (s.providerName.isNotEmpty) set.add(s.providerName);
      if (s.providerId.isNotEmpty) set.add(s.providerId);
    }
    return set.toList();
  }

  MovieItem copyWith({
    String? id,
    String? title,
    String? posterUrl,
    String? backdropUrl,
    int? year,
    double? rating,
    String? quality,
    List<String>? genres,
    List<String>? catalogGroups,
    String? type,
    String? synopsis,
    String? duration,
    String? repoId,
    String? repoName,
    String? providerId,
    String? providerName,
    String? detailUrl,
    String? episodeUrl,
    List<MovieSource>? sources,
    List<MovieSeason>? seasons,
    List<String>? availableRepos,
    List<String>? availableProviders,
    List<String>? audioTracks,
    List<String>? subtitles,
  }) {
    return MovieItem(
      id: id ?? this.id,
      title: title ?? this.title,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      year: year ?? this.year,
      rating: rating ?? this.rating,
      quality: quality ?? this.quality,
      genres: genres ?? this.genres,
      catalogGroups: catalogGroups ?? this.catalogGroups,
      type: type ?? this.type,
      synopsis: synopsis ?? this.synopsis,
      duration: duration ?? this.duration,
      repoId: repoId ?? this.repoId,
      repoName: repoName ?? this.repoName,
      providerId: providerId ?? this.providerId,
      providerName: providerName ?? this.providerName,
      detailUrl: detailUrl ?? this.detailUrl,
      episodeUrl: episodeUrl ?? this.episodeUrl,
      sources: sources ?? this.sources,
      availableRepos: availableRepos ?? this.availableRepos,
      availableProviders: availableProviders ?? this.availableProviders,
      seasons: seasons ?? this.seasons,
      audioTracks: audioTracks ?? this.audioTracks,
      subtitles: subtitles ?? this.subtitles,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'posterUrl': posterUrl,
    'backdropUrl': backdropUrl,
    'year': year,
    'rating': rating,
    'quality': quality,
    'genres': genres,
    'catalogGroups': catalogGroups,
    'type': type,
    'synopsis': synopsis,
    'duration': duration,
    'repoId': repoId,
    'repoName': repoName,
    'providerId': providerId,
    'providerName': providerName,
    'detailUrl': detailUrl,
    'episodeUrl': episodeUrl,
    'availableRepos': availableRepos,
    'availableProviders': availableProviders,
    'sources': sources.map((s) => s.toJson()).toList(),
    'seasons': seasons.map((s) => s.toJson()).toList(),
    'audioTracks': audioTracks,
    'subtitles': subtitles,
  };

  factory MovieItem.fromJson(Map<String, dynamic> json) => MovieItem(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? 'Untitled',
    posterUrl: json['posterUrl'] as String? ?? '',
    backdropUrl: json['backdropUrl'] as String? ?? '',
    year: json['year'] as int? ?? 2024,
    rating: (json['rating'] as num?)?.toDouble() ?? 8.0,
    quality: json['quality'] as String? ?? '1080p',
    genres:
        (json['genres'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
        ['Cinema'],
    type: json['type'] as String? ?? 'movie',
    catalogGroups:
        (json['catalogGroups'] as List?)?.whereType<String>().toList() ??
        const [],
    synopsis: json['synopsis'] as String? ?? '',
    duration: json['duration'] as String? ?? '2h',
    repoId: json['repoId'] as String? ?? '',
    repoName: json['repoName'] as String? ?? '',
    providerId: json['providerId'] as String? ?? '',
    providerName: json['providerName'] as String? ?? '',
    detailUrl: json['detailUrl'] as String? ?? '',
    episodeUrl: json['episodeUrl'] as String? ?? '',
    availableRepos:
        (json['availableRepos'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [],
    availableProviders:
        (json['availableProviders'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [],
    sources:
        (json['sources'] as List<dynamic>?)
            ?.map((e) => MovieSource.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
    seasons:
        (json['seasons'] as List<dynamic>?)
            ?.map((e) => MovieSeason.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
    audioTracks:
        (json['audioTracks'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        ['Bengali (Original)', 'Hindi Dub', 'English 5.1 Dolby'],
    subtitles:
        (json['subtitles'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        ['English', 'Bengali', 'Off'],
  );
}

class MovieProvider {
  final String id;
  final String name;
  final String description;
  final String version;
  final String iconUrl;
  final String scriptUrl;
  final String apkUrl;
  final String cloudStreamUrl;
  final bool isAdult;
  final String language;
  final List<String> types; // ['movie', 'series', 'anime']
  final bool isEnabled;
  final bool isInstalled;

  const MovieProvider({
    required this.id,
    required this.name,
    this.description = '',
    this.version = '1.0.0',
    this.iconUrl = '',
    this.scriptUrl = '',
    this.apkUrl = '',
    this.cloudStreamUrl = '',
    this.isAdult = false,
    this.language = 'en',
    this.types = const ['movie', 'series'],
    this.isEnabled = true,
    this.isInstalled = true,
  });

  bool get isLiveTv {
    if (types.isNotEmpty && types.every(isLiveTvType)) return true;
    if (types.any(isLiveTvType)) return false;
    return RegExp(
      r'(iptv|live[ _-]*tv|tv[ _-]*channels?|xtream)',
      caseSensitive: false,
    ).hasMatch('$id $name');
  }

  MovieProvider copyWith({
    bool? isEnabled,
    bool? isInstalled,
    String? name,
    String? description,
    String? language,
  }) {
    return MovieProvider(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      version: version,
      language: language ?? this.language,
      iconUrl: iconUrl,
      scriptUrl: scriptUrl,
      apkUrl: apkUrl,
      cloudStreamUrl: cloudStreamUrl,
      isAdult: isAdult,
      types: types,
      isEnabled: isEnabled ?? this.isEnabled,
      isInstalled: isInstalled ?? this.isInstalled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'version': version,
    'language': language,
    'iconUrl': iconUrl,
    'scriptUrl': scriptUrl,
    'apkUrl': apkUrl,
    'cloudStreamUrl': cloudStreamUrl,
    'isAdult': isAdult,
    'types': types,
    'isEnabled': isEnabled,
    'isInstalled': isInstalled,
  };

  factory MovieProvider.fromJson(Map<String, dynamic> json) => MovieProvider(
    iconUrl: json['iconUrl'] as String? ?? '',
    scriptUrl: json['scriptUrl'] as String? ?? '',
    apkUrl: json['apkUrl'] as String? ?? '',
    cloudStreamUrl: json['cloudStreamUrl'] as String? ?? '',
    isAdult: json['isAdult'] as bool? ?? false,
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? 'Provider',
    description: json['description'] as String? ?? '',
    version: json['version'] as String? ?? '1.0.0',
    language: json['language'] as String? ?? 'en',
    types:
        (json['types'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
        ['movie', 'series'],
    isEnabled: json['isEnabled'] as bool? ?? true,
    isInstalled: json['isInstalled'] as bool? ?? true,
  );
}

class MovieRepository {
  final String id;
  final String name;
  final String description;
  final String url;
  final String author;
  final String version;
  final String
  iconType; // 'cloudstream', 'dantotsu', 'stremio', 'bollywood', 'custom'
  final String ecosystem; // 'cloudstream', 'aniyomi', 'zangetsu', 'mihon', 'lnreader', 'adult'
  final String shortcode;
  final bool isEnabled;
  final int providerCount;
  final List<String> tags;
  final bool isCustom;
  final List<MovieProvider> providers;

  const MovieRepository({
    required this.id,
    required this.name,
    required this.description,
    required this.url,
    required this.author,
    required this.version,
    required this.iconType,
    this.ecosystem = 'cloudstream',
    this.shortcode = '',
    required this.isEnabled,
    required this.providerCount,
    required this.tags,
    this.isCustom = false,
    this.providers = const [],
  });

  String get effectiveEcosystem {
    if (ecosystem.isNotEmpty) return ecosystem;
    if (iconType == 'dantotsu' ||
        tags.any((t) => t.toLowerCase().contains('anime')))
      return 'aniyomi';
    if (iconType == 'stremio' ||
        tags.any(
          (t) =>
              t.toLowerCase().contains('stremio') ||
              t.toLowerCase().contains('torrent'),
        ))
      return 'zangetsu';
    return 'cloudstream';
  }

  bool get isAdult =>
      effectiveEcosystem == 'adult' ||
      RegExp(
        r'\b(nsfw|adult|18plus)\b|18\+',
        caseSensitive: false,
      ).hasMatch(name + ' ' + url + ' ' + tags.join(' '));

  int get actualProviderCount =>
      providers.isNotEmpty ? providers.length : providerCount;
  int get activeProviderCount => providers.isNotEmpty
      ? providers.where((p) => p.isEnabled).length
      : providerCount;

  MovieRepository copyWith({
    bool? isEnabled,
    String? name,
    String? description,
    String? url,
    String? ecosystem,
    String? shortcode,
    List<MovieProvider>? providers,
  }) {
    return MovieRepository(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      url: url ?? this.url,
      author: author,
      version: version,
      iconType: iconType,
      ecosystem: ecosystem ?? this.ecosystem,
      shortcode: shortcode ?? this.shortcode,
      isEnabled: isEnabled ?? this.isEnabled,
      providerCount: providers?.length ?? providerCount,
      tags: tags,
      isCustom: isCustom,
      providers: providers ?? this.providers,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'url': url,
    'author': author,
    'version': version,
    'iconType': iconType,
    'ecosystem': effectiveEcosystem,
    'shortcode': shortcode,
    'isEnabled': isEnabled,
    'providerCount': actualProviderCount,
    'tags': tags,
    'isCustom': isCustom,
    'providers': providers.map((p) => p.toJson()).toList(),
  };

  factory MovieRepository.fromJson(Map<String, dynamic> json) {
    final icon = json['iconType'] as String? ?? 'custom';
    final eco =
        json['ecosystem'] as String? ??
        ((icon == 'dantotsu')
            ? 'aniyomi'
            : (icon == 'stremio')
            ? 'zangetsu'
            : 'cloudstream');
    return MovieRepository(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Repository',
      description: json['description'] as String? ?? '',
      url: json['url'] as String? ?? '',
      author: json['author'] as String? ?? 'Community',
      version: json['version'] as String? ?? '1.0.0',
      iconType: icon,
      ecosystem: eco,
      shortcode: json['shortcode'] as String? ?? '',
      isEnabled: json['isEnabled'] as bool? ?? true,
      providerCount: json['providerCount'] as int? ?? 1,
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
          [],
      isCustom: json['isCustom'] as bool? ?? false,
      providers:
          (json['providers'] as List<dynamic>?)
              ?.map((p) => MovieProvider.fromJson(p as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// Result of probing one repository's manifest URL for liveness.
///
/// Surfaced in the Providers Hub so the user can see, truthfully, whether each
/// repo they added actually works (reachable + serves valid JSON) instead of
/// silently guessing from a static list.
class RepoHealth {
  final String repoId;
  final String repoName;
  final bool ok;
  final String
  message; // human-readable detail: "12 extensions", "HTTP 404", "Unreachable"…

  const RepoHealth({
    required this.repoId,
    required this.repoName,
    required this.ok,
    required this.message,
  });
}

class EcosystemExtensionItem {
  final MovieProvider provider;
  final MovieRepository repository;

  const EcosystemExtensionItem({
    required this.provider,
    required this.repository,
  });
}
