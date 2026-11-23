import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/site_model.dart';
import '../models/video_item.dart';

class SearchService {
  static final SearchService instance = SearchService._();
  SearchService._();

  List<SiteModel>? _cachedSites;

  // Load top sites from assets/data/full_sites.json
  Future<List<SiteModel>> getTopSites() async {
    if (_cachedSites != null) return List<SiteModel>.from(_cachedSites!);

    try {
      final jsonString = await rootBundle.loadString(
        'assets/data/full_sites.json',
      );
      final List<dynamic> list = json.decode(jsonString);

      final sites = <SiteModel>[
        const SiteModel(
          title: 'YouTube',
          url: 'https://m.youtube.com',
          icon: 'https://cdn-icons-png.flaticon.com/512/1384/1384060.png',
          category: 'Video',
          colorHex: 0xFFFF0000,
        ),
        const SiteModel(
          title: 'Instagram',
          url: 'https://www.instagram.com',
          icon: 'https://cdn-icons-png.flaticon.com/512/174/174855.png',
          category: 'Social',
          colorHex: 0xFFE1306C,
        ),
        const SiteModel(
          title: 'TikTok',
          url: 'https://www.tiktok.com',
          icon: 'https://cdn-icons-png.flaticon.com/512/3046/3046121.png',
          category: 'Shorts',
          colorHex: 0xFF000000,
        ),
        const SiteModel(
          title: 'Facebook',
          url: 'https://m.facebook.com',
          icon: 'https://cdn-icons-png.flaticon.com/512/124/124010.png',
          category: 'Social',
          colorHex: 0xFF1877F2,
        ),
        const SiteModel(
          title: 'Twitter / X',
          url: 'https://x.com',
          icon: 'https://cdn-icons-png.flaticon.com/512/5969/5969020.png',
          category: 'Social',
          colorHex: 0xFF1DA1F2,
        ),
        const SiteModel(
          title: 'SoundCloud',
          url: 'https://soundcloud.com',
          icon: 'https://cdn-icons-png.flaticon.com/512/145/145809.png',
          category: 'Music',
          colorHex: 0xFFFF5500,
        ),
        const SiteModel(
          title: 'Vimeo',
          url: 'https://vimeo.com',
          icon: 'https://cdn-icons-png.flaticon.com/512/174/174878.png',
          category: 'Video',
          colorHex: 0xFF1AB7EA,
        ),
        const SiteModel(
          title: 'Dailymotion',
          url: 'https://www.dailymotion.com',
          icon: 'https://cdn-icons-png.flaticon.com/512/10091/10091917.png',
          category: 'Video',
          colorHex: 0xFF0066DC,
        ),
      ];

      for (final item in list) {
        final title = item['title']?.toString() ?? '';
        if (!sites.any((s) => s.title.toLowerCase() == title.toLowerCase())) {
          sites.add(SiteModel.fromJson(item));
        }
      }

      _cachedSites = sites;
      return List<SiteModel>.from(sites);
    } catch (e) {
      return List<SiteModel>.from(_defaultSites);
    }
  }

  // Live auto-suggestions query
  Future<List<String>> getSearchSuggestions(String query) async {
    if (query.trim().isEmpty) return [];
    try {
      final url = Uri.parse(
        'https://suggestqueries.google.com/complete/search?client=youtube&ds=yt&q=${Uri.encodeComponent(query)}',
      );
      final resp = await http.get(url, headers: {'User-Agent': 'Mozilla/5.0'});
      if (resp.statusCode == 200) {
        final body = resp.body;
        final startIdx = body.indexOf('[');
        final endIdx = body.lastIndexOf(']');
        if (startIdx != -1 && endIdx != -1) {
          final jsonStr = body.substring(startIdx, endIdx + 1);
          final parsed = json.decode(jsonStr) as List<dynamic>;
          if (parsed.length > 1 && parsed[1] is List) {
            final items = parsed[1] as List<dynamic>;
            return items.map((e) => (e as List)[0].toString()).toList();
          }
        }
      }
    } catch (_) {}
    return [];
  }

  /// "Up next" recommendations for the currently playing video.
  ///
  /// `youtube_explode_dart` is frequently rate-limited/bot-blocked, which used
  /// to leave the Up next section permanently stuck on "Related videos
  /// unavailable". We now try several independent sources and merge them, so
  /// the section reliably fills with real videos:
  ///   1. InnerTube `next` — YouTube's genuine "Up next" panel (most accurate).
  ///   2. `youtube_explode_dart` related/search (best-effort).
  ///   3. InnerTube search for `title author`.
  ///   4. A category-matched slice of the curated feed as a last resort.
  Future<List<VideoItem>> getUpNext(VideoItem current) async {
    final results = <VideoItem>[];
    final seen = <String>{_videoKey(current)};

    void addAll(Iterable<VideoItem> items) {
      for (final video in items) {
        final key = _videoKey(video);
        if (key.isEmpty || !seen.add(key)) continue;
        results.add(video);
      }
    }

    final parsedId = VideoId.parseVideoId(current.videoUrl);
    final videoId =
        parsedId ?? (current.id.trim().isNotEmpty ? current.id.trim() : null);

    // 1) YouTube's real "Up next" panel via InnerTube — same reliable POST path
    //    the rest of the app uses, so it works where youtube_explode is blocked.
    if (videoId != null) {
      try {
        addAll(await _relatedViaInnerTube(videoId));
      } catch (_) {}
    }

    // 2) youtube_explode as a second independent source.
    if (results.length < 8 && parsedId != null) {
      final youtube = YoutubeExplode();
      try {
        Iterable<Video>? related;
        try {
          final video = await youtube.videos
              .get(parsedId)
              .timeout(const Duration(seconds: 6));
          related = await youtube.videos
              .getRelatedVideos(video)
              .timeout(const Duration(seconds: 7));
        } catch (_) {}
        if (related == null || related.isEmpty) {
          final query = [
            current.title,
            current.author,
          ].where((part) => part.trim().isNotEmpty).join(' ');
          if (query.isNotEmpty) {
            related = await youtube.search
                .search(query)
                .timeout(const Duration(seconds: 7));
          }
        }
        if (related != null) {
          addAll(
            related.map((video) {
              final duration = video.duration;
              final time = duration == null
                  ? ''
                  : duration
                        .toString()
                        .split('.')
                        .first
                        .replaceFirst(RegExp(r'^0:'), '');
              return VideoItem(
                id: video.id.value,
                title: video.title,
                author: video.author,
                channelId: video.channelId.value,
                duration: time,
                views: '',
                thumbnailUrl: video.thumbnails.mediumResUrl,
                videoUrl: video.url,
              );
            }),
          );
        }
      } catch (_) {
      } finally {
        youtube.close();
      }
    }

    // 3) InnerTube search fallback keyed on what is actually playing.
    if (results.length < 8) {
      final query = [
        current.title,
        current.author,
      ].where((part) => part.trim().isNotEmpty).join(' ');
      if (query.isNotEmpty) {
        try {
          addAll(await searchVideos(query));
        } catch (_) {}
      }
    }

    // 4) Curated pool as the very last resort — never leave the section empty.
    if (results.isEmpty) {
      addAll(getTrendingFeed(_categoryForTitle(current.title)));
    }

    return results.take(20).toList();
  }

  String _videoKey(VideoItem video) {
    final raw = video.id.trim();
    if (raw.isNotEmpty) return raw.toLowerCase();
    final parsed = VideoId.parseVideoId(video.videoUrl);
    return parsed?.toLowerCase() ?? '';
  }

  String _categoryForTitle(String title) {
    final t = title.toLowerCase();
    if (t.contains('music') || t.contains('song') || t.contains('piano')) {
      return 'Music';
    }
    if (t.contains('game') || t.contains('gaming')) return 'Gaming';
    if (t.contains('tech') || t.contains('review')) return 'Technology';
    if (t.contains('comedy') || t.contains('funny')) return 'Shorts';
    return 'All';
  }

  /// Fetches the genuine "Up next" panel from InnerTube's `next` endpoint.
  /// `compactVideoRenderer` entries live under
  /// `contents.twoColumnWatchNextResults.secondaryResults.secondaryResults.results`.
  Future<List<VideoItem>> _relatedViaInnerTube(String videoId) async {
    final payload = json.encode({
      'context': {
        'client': {
          'clientName': 'WEB',
          'clientVersion': '2.20240401.08.00',
          'hl': 'en',
          'gl': 'US',
        },
      },
      'videoId': videoId,
    });
    final resp = await http
        .post(
          Uri.parse('https://www.youtube.com/youtubei/v1/next'),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
          body: payload,
        )
        .timeout(const Duration(seconds: 9));
    if (resp.statusCode != 200) return const [];
    final data = json.decode(resp.body);
    final results = <VideoItem>[];
    final secondary =
        data['contents']?['twoColumnWatchNextResults']?['secondaryResults']?['secondaryResults']?['results']
            as List<dynamic>? ??
        const [];

    void walk(dynamic node) {
      if (node is Map) {
        final cvr = node['compactVideoRenderer'];
        if (cvr is Map) {
          final vid = (cvr['videoId'] ?? '').toString();
          if (vid.isNotEmpty) {
            final title =
                cvr['title']?['simpleText'] ??
                cvr['title']?['runs']?[0]?['text'] ??
                'Video';
            final author =
                cvr['longBylineText']?['runs']?[0]?['text'] ??
                cvr['ownerText']?['runs']?[0]?['text'] ??
                'YouTube';
            final duration = (cvr['lengthText']?['simpleText'] ?? '')
                .toString();
            final views = (cvr['viewCountText']?['simpleText'] ?? '')
                .toString();
            results.add(
              VideoItem(
                id: vid,
                title: title.toString(),
                author: author.toString(),
                channelAvatarUrl: _rendererChannelAvatar(cvr),
                channelId: _rendererChannelId(cvr),
                duration: duration,
                views: views,
                thumbnailUrl: 'https://i.ytimg.com/vi/$vid/hqdefault.jpg',
                videoUrl: 'https://www.youtube.com/watch?v=$vid',
              ),
            );
          }
        }
        for (final value in node.values) {
          walk(value);
        }
      } else if (node is List) {
        for (final value in node) {
          walk(value);
        }
      }
    }

    walk(secondary);
    return results;
  }

  // Search videos online
  Future<List<VideoItem>> searchVideos(String query, {String? platform}) async {
    if (query.trim().isEmpty) return [];

    final searchTarget = platform != null ? '$platform $query' : query;

    // Try YouTube InnerTube Web search
    try {
      final payload = json.encode({
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': '2.20240401.08.00',
            'hl': 'en',
            'gl': 'US',
          },
        },
        'query': searchTarget,
      });

      final resp = await http.post(
        Uri.parse('https://www.youtube.com/youtubei/v1/search'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
        body: payload,
      );

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final results = <VideoItem>[];
        final contents =
            data['contents']?['twoColumnSearchResultsRenderer']?['primaryContents']?['sectionListRenderer']?['contents']
                as List<dynamic>? ??
            [];

        for (final section in contents) {
          final items =
              section['itemSectionRenderer']?['contents'] as List<dynamic>? ??
              [];
          for (final item in items) {
            final vr = item['videoRenderer'];
            if (vr != null) {
              final vid = vr['videoId'] ?? '';
              final title = vr['title']?['runs']?[0]?['text'] ?? 'Video';
              final author =
                  vr['ownerText']?['runs']?[0]?['text'] ??
                  vr['shortBylineText']?['runs']?[0]?['text'] ??
                  (platform ?? 'Creator');
              final duration = vr['lengthText']?['simpleText'] ?? 'HD';
              final views = vr['viewCountText']?['simpleText'] ?? 'Popular';
              final thumb = 'https://i.ytimg.com/vi/$vid/hqdefault.jpg';

              if (vid.isNotEmpty) {
                results.add(
                  VideoItem(
                    id: vid,
                    title: title,
                    author: author,
                    channelAvatarUrl: _rendererChannelAvatar(vr),
                    channelId: _rendererChannelId(vr),
                    duration: duration,
                    views: views,
                    thumbnailUrl: thumb,
                    videoUrl: 'https://www.youtube.com/watch?v=$vid',
                    platform: platform ?? 'YouTube',
                  ),
                );
              }
            }
          }
        }

        if (results.isNotEmpty) return results;
      }
    } catch (_) {}

    // Fallback search
    try {
      final url = Uri.parse(
        'https://www.youtube.com/results?search_query=${Uri.encodeComponent(searchTarget)}',
      );
      final resp = await http.get(
        url,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
        },
      );
      if (resp.statusCode == 200) {
        final html = resp.body;
        final match = RegExp(r'var ytInitialData\s*=\s*({.+?});</script>')
            .firstMatch(html);
        if (match != null) {
          final data = json.decode(match.group(1)!);
          final results = <VideoItem>[];
          final contents =
              data['contents']?['twoColumnSearchResultsRenderer']?['primaryContents']?['sectionListRenderer']?['contents']
                  as List<dynamic>? ??
              [];
          for (final section in contents) {
            final items =
                section['itemSectionRenderer']?['contents'] as List<dynamic>? ??
                [];
            for (final item in items) {
              final vr = item['videoRenderer'];
              if (vr != null) {
                final vid = vr['videoId'] ?? '';
                final title = vr['title']?['runs']?[0]?['text'] ?? 'Video';
                final author =
                    vr['ownerText']?['runs']?[0]?['text'] ??
                    (platform ?? 'Creator');
                final duration = vr['lengthText']?['simpleText'] ?? 'HD';
                final views = vr['viewCountText']?['simpleText'] ?? '';
                if (vid.isNotEmpty) {
                  results.add(
                    VideoItem(
                      id: vid,
                      title: title,
                      author: author,
                      channelAvatarUrl: _rendererChannelAvatar(vr),
                      channelId: _rendererChannelId(vr),
                      duration: duration,
                      views: views,
                      thumbnailUrl: 'https://i.ytimg.com/vi/$vid/hqdefault.jpg',
                      videoUrl: 'https://www.youtube.com/watch?v=$vid',
                      platform: platform ?? 'YouTube',
                    ),
                  );
                }
              }
            }
          }
          if (results.isNotEmpty) return results;
        }
      }
    } catch (_) {}

    return [];
  }

  // Preloaded Trending & Curated Feeds by Category
  List<VideoItem> getTrendingFeed(String category) {
    if (category == 'Music') {
      return _trendingMusic;
    } else if (category == 'Gaming') {
      return _trendingGaming;
    } else if (category == 'Technology') {
      return _trendingTech;
    } else if (category == 'Shorts') {
      return _tiktokFeed;
    }
    return _trendingAll;
  }

  // ---------------------------------------------------------------------------
  // LIVE, paginated home feed (real YouTube).
  //
  // The old home feed returned one fixed hardcoded list, so every app launch
  // showed the identical handful of videos and scrolling never surfaced
  // anything new. This builds a genuinely fresh feed from the network:
  //   * page 0  -> YouTube's real Trending chart (InnerTube browse "FEtrending")
  //   * later   -> fresh, unique results for rotating diverse queries, so every
  //                scroll pulls NEW real videos instead of repeating a static list.
  // ---------------------------------------------------------------------------

  /// Rotating query seeds that unfold the feed as the user scrolls. Each page
  /// hits two of these, yielding ~20+ fresh real YouTube videos per page.
  static const List<String> _feedSeeds = [
    'trending videos today',
    'music video official',
    'gaming highlights',
    'tech review 2026',
    'funny clips viral',
    'football highlights',
    'movie trailer official',
    'cooking recipe easy',
    'travel vlog 4k',
    'science documentary',
    'car review',
    'fitness workout',
    'standup comedy',
    'nature relaxation',
    'news today',
    'coding tutorial',
    'photography tips',
    'dance performance',
    'podcast clips',
    'reaction video',
  ];

  /// Category -> the seed slice that best matches it, so the category pills on
  /// the home screen still steer the live feed.
  static List<String> _seedsForCategory(String category) {
    final c = category.toLowerCase();
    if (c.contains('music'))
      return ['music video official', 'dance performance', 'podcast clips'];
    if (c.contains('gaming'))
      return ['gaming highlights', 'reaction video', 'funny clips viral'];
    if (c.contains('techn'))
      return ['tech review 2026', 'coding tutorial', 'science documentary'];
    if (c.contains('short'))
      return ['funny clips viral', 'dance performance', 'reaction video'];
    if (c.contains('comedy'))
      return ['standup comedy', 'funny clips viral', 'reaction video'];
    if (c.contains('news'))
      return ['news today', 'football highlights', 'science documentary'];
    return _feedSeeds;
  }

  /// Fetch one page of the LIVE home feed. [page] is 0-based. Returns [] once
  /// the seed pool is exhausted or the network fails, so callers stop cleanly.
  Future<List<VideoItem>> fetchLiveFeedPage({
    required int page,
    String category = 'All',
  }) async {
    // Page 0 opens with YouTube's genuine trending chart (when reachable),
    // then widens with a few real trending-oriented searches so the first
    // screen is always rich even if the chart endpoint is geo-blocked.
    if (page == 0) {
      final out = <VideoItem>[];
      final trending = await fetchTrendingChart();
      for (final v in trending) {
        if (!out.any((e) => e.id == v.id)) out.add(v);
      }
      for (final q in const [
        'trending videos today',
        'viral videos this week',
      ]) {
        for (final v in await searchVideos(q)) {
          if (!out.any((e) => e.id == v.id)) out.add(v);
        }
      }
      if (out.isNotEmpty) return out;
      // Everything blocked -> fall through to the seeded first page below.
    }

    final seeds = _seedsForCategory(category);
    final start = page * 2;
    if (start >= seeds.length) return const [];
    final out = <VideoItem>[];
    for (int i = start; i < start + 2 && i < seeds.length; i++) {
      out.addAll(await searchVideos(seeds[i]));
    }
    return out;
  }

  /// Whether more live-feed pages remain for [category] after [page].
  bool hasMoreLiveFeedPages(int page, String category) =>
      (page * 2) < _seedsForCategory(category).length;

  /// YouTube's real Trending chart via the InnerTube browse endpoint. Falls back
  /// to scraping the trending page's initial data when the API is unavailable.
  Future<List<VideoItem>> fetchTrendingChart() async {
    // 1) InnerTube browse "FEtrending".
    try {
      final payload = json.encode({
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': '2.20240401.08.00',
            'hl': 'en',
            'gl': 'US',
          },
        },
        'browseId': 'FEtrending',
      });
      final resp = await http
          .post(
            Uri.parse('https://www.youtube.com/youtubei/v1/browse'),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
            body: payload,
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final results = <VideoItem>[];
        _collectVideoRenderers(data, results);
        if (results.isNotEmpty) return results;
      }
    } catch (_) {}

    // 2) Fallback: scrape the public trending page's embedded initial data.
    try {
      final url = Uri.parse('https://www.youtube.com/feed/trending');
      final resp = await http.get(
        url,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
        },
      );
      if (resp.statusCode == 200) {
        final match = RegExp(r'var ytInitialData\s*=\s*({.+?});</script>')
            .firstMatch(resp.body);
        if (match != null) {
          final data = json.decode(match.group(1)!);
          final results = <VideoItem>[];
          _collectVideoRenderers(data, results);
          if (results.isNotEmpty) return results;
        }
      }
    } catch (_) {}

    return const [];
  }

  /// Recursively walks any InnerTube/ytInitialData shape collecting every
  /// `videoRenderer` into a deduplicated [VideoItem] list. Robust against the
  /// deep, frequently-changing nesting of YouTube responses.
  void _collectVideoRenderers(dynamic node, List<VideoItem> out) {
    if (node is Map) {
      final vr = node['videoRenderer'];
      if (vr is Map) {
        final item = _videoItemFromRenderer(vr);
        if (item != null && !out.any((v) => v.id == item.id)) out.add(item);
      }
      for (final v in node.values) {
        _collectVideoRenderers(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collectVideoRenderers(v, out);
      }
    }
  }

  String? _rendererChannelAvatar(Map renderer) {
    final thumbnails = renderer['channelThumbnailSupportedRenderers']
            ?['channelThumbnailWithLinkRenderer']?['thumbnail']?['thumbnails'] ??
        renderer['channelThumbnail']?['thumbnails'];
    if (thumbnails is! List) return null;
    for (final thumbnail in thumbnails.reversed.whereType<Map>()) {
      final url = thumbnail['url'];
      if (url is String && Uri.tryParse(url)?.scheme == 'https') return url;
    }
    return null;
  }

  String? _rendererChannelId(Map renderer) {
    for (final key in ['ownerText', 'shortBylineText', 'longBylineText']) {
      final runs = renderer[key]?['runs'];
      if (runs is! List) continue;
      for (final run in runs.whereType<Map>()) {
        final id = run['navigationEndpoint']?['browseEndpoint']?['browseId'];
        if (id is String && id.startsWith('UC')) return id;
      }
    }
    return null;
  }

  VideoItem? _videoItemFromRenderer(Map vr) {
    final vid = (vr['videoId'] ?? '').toString();
    if (vid.isEmpty) return null;
    final title =
        vr['title']?['runs']?[0]?['text'] ??
        vr['title']?['simpleText'] ??
        'Video';
    final author =
        vr['ownerText']?['runs']?[0]?['text'] ??
        vr['shortBylineText']?['runs']?[0]?['text'] ??
        'YouTube';
    final duration = vr['lengthText']?['simpleText'] ?? '';
    final views = vr['viewCountText']?['simpleText'] ?? '';
    return VideoItem(
      id: vid,
      title: title,
      author: author,
      channelAvatarUrl: _rendererChannelAvatar(vr),
      channelId: _rendererChannelId(vr),
      duration: duration.isEmpty ? 'New' : duration,
      views: views.isEmpty ? 'Trending' : views,
      thumbnailUrl: 'https://i.ytimg.com/vi/$vid/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=$vid',
      platform: 'YouTube',
    );
  }

  // Categories per platform
  List<String> getPlatformCategories(String platformTitle) {
    final name = platformTitle.toLowerCase();
    if (name.contains('youtube')) {
      return ['All', 'Music', 'Gaming', 'Technology', 'Shorts'];
    } else if (name.contains('tiktok')) {
      return ['All', 'Viral Sounds', 'Dance & Remix', 'Shorts', 'Comedy'];
    } else if (name.contains('instagram')) {
      return ['All', 'Reels', 'Trending Audio', 'Travel & 4K', 'Lofi'];
    } else if (name.contains('facebook')) {
      return ['All', 'Watch', 'Gaming', 'Funny', 'Food & Travel'];
    } else if (name.contains('soundcloud')) {
      return ['All', '320k Audio', 'Lofi Beats', 'Electronic', 'Bass Boost'];
    }
    return ['All', 'Trending', 'Shorts', 'Music'];
  }

  // Dedicated Platform Feeds
  List<VideoItem> getPlatformFeed(
    String platformTitle, {
    String category = 'All',
  }) {
    final name = platformTitle.toLowerCase();

    if (name.contains('youtube')) {
      return getTrendingFeed(category);
    } else if (name.contains('tiktok')) {
      if (category == 'Viral Sounds') {
        return _tiktokFeed
            .where(
              (v) =>
                  v.title.toLowerCase().contains('audio') ||
                  v.title.toLowerCase().contains('sound'),
            )
            .toList();
      }
      return _tiktokFeed;
    } else if (name.contains('instagram')) {
      if (category == 'Reels') {
        return _instagramFeed
            .where((v) => v.title.toLowerCase().contains('reels'))
            .toList();
      }
      return _instagramFeed;
    } else if (name.contains('facebook')) {
      return _facebookFeed;
    } else if (name.contains('soundcloud')) {
      return _soundcloudFeed;
    } else if (name.contains('twitter') || name.contains('x')) {
      return _twitterFeed;
    }

    // For any custom user-added site (Vimeo, Reddit, Dailymotion, Twitch, etc.)
    return [
      VideoItem(
        id: 'custom_${platformTitle.hashCode.abs()}_1',
        title: '$platformTitle - Featured 4K Media Stream',
        author: platformTitle,
        duration: '4:20',
        views: '1.2M views',
        thumbnailUrl: 'https://images.unsplash.com/photo-1536440136628-849c177e76a1?w=500&auto=format&fit=crop',
        videoUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
        platform: platformTitle,
      ),
      VideoItem(
        id: 'custom_${platformTitle.hashCode.abs()}_2',
        title: '$platformTitle - Trending Video & MP3 Audio',
        author: platformTitle,
        duration: '3:45',
        views: '850K views',
        thumbnailUrl: 'https://images.unsplash.com/photo-1514525253161-7a46d19cd819?w=500&auto=format&fit=crop',
        videoUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
        platform: platformTitle,
      ),
      VideoItem(
        id: 'custom_${platformTitle.hashCode.abs()}_3',
        title: '$platformTitle - Highlights & Viral Clip (1080p)',
        author: platformTitle,
        duration: '2:15',
        views: '2.4M views',
        thumbnailUrl: 'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?w=500&auto=format&fit=crop',
        videoUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
        platform: platformTitle,
      ),
      ..._trendingAll,
    ];
  }

  static const List<SiteModel> _defaultSites = [
    SiteModel(
      title: 'YouTube',
      url: 'https://m.youtube.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/1384/1384060.png',
      category: 'Video',
      colorHex: 0xFFFF0000,
    ),
    SiteModel(
      title: 'Instagram',
      url: 'https://www.instagram.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/174/174855.png',
      category: 'Social',
      colorHex: 0xFFE1306C,
    ),
    SiteModel(
      title: 'TikTok',
      url: 'https://www.tiktok.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/3046/3046121.png',
      category: 'Shorts',
      colorHex: 0xFF000000,
    ),
    SiteModel(
      title: 'Facebook',
      url: 'https://m.facebook.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/124/124010.png',
      category: 'Social',
      colorHex: 0xFF1877F2,
    ),
    SiteModel(
      title: 'Twitter / X',
      url: 'https://x.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/5969/5969020.png',
      category: 'Social',
      colorHex: 0xFF1DA1F2,
    ),
    SiteModel(
      title: 'SoundCloud',
      url: 'https://soundcloud.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/145/145809.png',
      category: 'Music',
      colorHex: 0xFFFF5500,
    ),
  ];

  static const List<VideoItem> _trendingAll = [
    VideoItem(
      id: '60ItHLz5WEA',
      title: 'Alan Walker - Faded (Official Music Video)',
      author: 'Alan Walker',
      duration: '3:33',
      views: '3.6B views',
      thumbnailUrl: 'https://i.ytimg.com/vi/60ItHLz5WEA/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=60ItHLz5WEA',
      platform: 'YouTube',
    ),
    VideoItem(
      id: 'kJQP7kiw5Fk',
      title: 'Luis Fonsi - Despacito ft. Daddy Yankee',
      author: 'Luis Fonsi',
      duration: '4:42',
      views: '8.4B views',
      thumbnailUrl: 'https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=kJQP7kiw5Fk',
      platform: 'YouTube',
    ),
    VideoItem(
      id: 'fJ9rUzIMcZQ',
      title: 'Queen - Bohemian Rhapsody (Official Video Remastered)',
      author: 'Queen Official',
      duration: '6:00',
      views: '1.7B views',
      thumbnailUrl: 'https://i.ytimg.com/vi/fJ9rUzIMcZQ/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=fJ9rUzIMcZQ',
      platform: 'YouTube',
    ),
    VideoItem(
      id: 'JGwWNGJdvx8',
      title: 'Ed Sheeran - Shape of You (Official Music Video)',
      author: 'Ed Sheeran',
      duration: '4:24',
      views: '6.2B views',
      thumbnailUrl: 'https://i.ytimg.com/vi/JGwWNGJdvx8/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=JGwWNGJdvx8',
      platform: 'YouTube',
    ),
    VideoItem(
      id: '9bZkp7q19f0',
      title: 'PSY - GANGNAM STYLE (강남스타일) M/V',
      author: 'officialpsy',
      duration: '4:13',
      views: '5.1B views',
      thumbnailUrl: 'https://i.ytimg.com/vi/9bZkp7q19f0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=9bZkp7q19f0',
      platform: 'YouTube',
    ),
    VideoItem(
      id: 'OPf0YbXqDm0',
      title: 'Mark Ronson - Uptown Funk ft. Bruno Mars',
      author: 'MarkRonsonVEVO',
      duration: '4:30',
      views: '5.2B views',
      thumbnailUrl: 'https://i.ytimg.com/vi/OPf0YbXqDm0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=OPf0YbXqDm0',
      platform: 'YouTube',
    ),
  ];

  static const List<VideoItem> _tiktokFeed = [
    VideoItem(
      id: '60ItHLz5WEA',
      title: 'TikTok Viral Sound - Oh No Remix (Original HD Audio)',
      author: '@tiktok_trends',
      duration: '0:30',
      views: '125M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/60ItHLz5WEA/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=60ItHLz5WEA',
      platform: 'TikTok',
    ),
    VideoItem(
      id: 'kJQP7kiw5Fk',
      title: 'TikTok Dance Challenge - Cupid Twin Version 4K',
      author: '@viral_dances',
      duration: '0:45',
      views: '88M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=kJQP7kiw5Fk',
      platform: 'TikTok',
    ),
    VideoItem(
      id: 'JGwWNGJdvx8',
      title: 'Savage Love - Jason Derulo TikTok Beat',
      author: '@jasonderulo',
      duration: '1:00',
      views: '210M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/JGwWNGJdvx8/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=JGwWNGJdvx8',
      platform: 'TikTok',
    ),
    VideoItem(
      id: 'fJ9rUzIMcZQ',
      title: 'Makeba - Jain (Viral TikTok Audio Edit)',
      author: '@tiktok_music_hub',
      duration: '0:55',
      views: '340M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/fJ9rUzIMcZQ/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=fJ9rUzIMcZQ',
      platform: 'TikTok',
    ),
    VideoItem(
      id: 'OPf0YbXqDm0',
      title: 'GigaChad Theme - Phonky Town (TikTok Viral Bass)',
      author: '@phonk_masters',
      duration: '1:15',
      views: '95M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/OPf0YbXqDm0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=OPf0YbXqDm0',
      platform: 'TikTok',
    ),
    VideoItem(
      id: '9bZkp7q19f0',
      title: 'Water - Tyla (TikTok Dance Trend Compilation)',
      author: '@tyladance',
      duration: '0:48',
      views: '160M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/9bZkp7q19f0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=9bZkp7q19f0',
      platform: 'TikTok',
    ),
    VideoItem(
      id: 'k2qgadSvNyU',
      title: 'Greedy - Tate McRae (TikTok Speed Up Remix)',
      author: '@tatemcrae_edits',
      duration: '0:52',
      views: '75M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/k2qgadSvNyU/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=k2qgadSvNyU',
      platform: 'TikTok',
    ),
    VideoItem(
      id: 'QdBZY2fkU-0',
      title: 'Epic Life Hacks & TikTok Cooking Tricks 2026',
      author: '@hacks_unlimited',
      duration: '1:30',
      views: '45M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/QdBZY2fkU-0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=QdBZY2fkU-0',
      platform: 'TikTok',
    ),
    VideoItem(
      id: 'e1Z_yGzJ_H0',
      title: 'Tokyo Street Food ASMR (TikTok Viral 4K)',
      author: '@streetfood_tokyo',
      duration: '0:58',
      views: '62M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/e1Z_yGzJ_H0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=e1Z_yGzJ_H0',
      platform: 'TikTok',
    ),
    VideoItem(
      id: '7b7z8k79N4Q',
      title: 'Cat Vibing to Ievan Polkka (Official Remix)',
      author: '@vibing_cat',
      duration: '0:40',
      views: '310M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/7b7z8k79N4Q/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=7b7z8k79N4Q',
      platform: 'TikTok',
    ),
  ];

  static const List<VideoItem> _instagramFeed = [
    VideoItem(
      id: 'k2qgadSvNyU',
      title: 'Instagram Reels - 4K Cyberpunk Tokyo Night Cityscape',
      author: '@tokyo_reels_4k',
      duration: '0:35',
      views: '42M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/k2qgadSvNyU/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=k2qgadSvNyU',
      platform: 'Instagram',
    ),
    VideoItem(
      id: '60ItHLz5WEA',
      title: 'Pasoori - Coke Studio (Instagram Viral Reels Audio)',
      author: '@coke_studio',
      duration: '1:20',
      views: '190M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/60ItHLz5WEA/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=60ItHLz5WEA',
      platform: 'Instagram',
    ),
    VideoItem(
      id: 'JGwWNGJdvx8',
      title: 'Until I Found You - Stephen Sanchez (IG Reels Edition)',
      author: '@reels_audio_official',
      duration: '0:50',
      views: '115M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/JGwWNGJdvx8/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=JGwWNGJdvx8',
      platform: 'Instagram',
    ),
    VideoItem(
      id: 'fJ9rUzIMcZQ',
      title: 'Golden Hour - JVKE (Instagram Piano Remaster)',
      author: '@jvke_official',
      duration: '1:10',
      views: '230M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/fJ9rUzIMcZQ/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=fJ9rUzIMcZQ',
      platform: 'Instagram',
    ),
    VideoItem(
      id: 'kJQP7kiw5Fk',
      title: 'Cinematic Iceland Drone 4K (Trending IG Audio)',
      author: '@travel_cinematics',
      duration: '0:45',
      views: '68M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=kJQP7kiw5Fk',
      platform: 'Instagram',
    ),
    VideoItem(
      id: '9bZkp7q19f0',
      title: 'Glimpse of Us - Joji (Instagram Mood Reels Edit)',
      author: '@joji_reels',
      duration: '0:55',
      views: '84M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/9bZkp7q19f0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=9bZkp7q19f0',
      platform: 'Instagram',
    ),
    VideoItem(
      id: 'OPf0YbXqDm0',
      title: 'Sunset Vibes & Supercars in Monaco (Reels 4K 60fps)',
      author: '@monaco_supercars',
      duration: '0:38',
      views: '51M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/OPf0YbXqDm0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=OPf0YbXqDm0',
      platform: 'Instagram',
    ),
    VideoItem(
      id: 'QdBZY2fkU-0',
      title: 'Calm Down - Rema (Trending Instagram Audio Reel)',
      author: '@heisrema',
      duration: '1:05',
      views: '320M plays',
      thumbnailUrl: 'https://i.ytimg.com/vi/QdBZY2fkU-0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=QdBZY2fkU-0',
      platform: 'Instagram',
    ),
    VideoItem(
      id: 'e1Z_yGzJ_H0',
      title: 'Satisfying Pottery & Ceramic Art (IG Reels)',
      author: '@satisfying_arts',
      duration: '0:42',
      views: '39M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/e1Z_yGzJ_H0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=e1Z_yGzJ_H0',
      platform: 'Instagram',
    ),
    VideoItem(
      id: '7b7z8k79N4Q',
      title: 'Starry Night Time-Lapse in Swiss Alps (4K Reel)',
      author: '@swiss_alps_4k',
      duration: '0:30',
      views: '73M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/7b7z8k79N4Q/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=7b7z8k79N4Q',
      platform: 'Instagram',
    ),
  ];

  static const List<VideoItem> _facebookFeed = [
    VideoItem(
      id: 'QdBZY2fkU-0',
      title: 'FB Watch - Ultimate Funny Fails & Bloopers 2026',
      author: 'Facebook Watch Official',
      duration: '8:45',
      views: '18M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/QdBZY2fkU-0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=QdBZY2fkU-0',
      platform: 'Facebook',
    ),
    VideoItem(
      id: 'e1Z_yGzJ_H0',
      title: 'FB Gaming - Insane Clutch Highlights (Pro Tournament)',
      author: 'FB Gaming Central',
      duration: '12:20',
      views: '5.2M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/e1Z_yGzJ_H0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=e1Z_yGzJ_H0',
      platform: 'Facebook',
    ),
  ];

  static const List<VideoItem> _soundcloudFeed = [
    VideoItem(
      id: '7b7z8k79N4Q',
      title: 'SoundCloud - Lofi Chillhop Radio [Beats to Relax/Study to]',
      author: 'Lofi Girl',
      duration: '3:45:00',
      views: '55M streams',
      thumbnailUrl: 'https://i.ytimg.com/vi/7b7z8k79N4Q/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=7b7z8k79N4Q',
      platform: 'SoundCloud',
    ),
    VideoItem(
      id: 'OPf0YbXqDm0',
      title: 'SoundCloud - Flac 320k Bass Boosted Car Audio Remix',
      author: 'SoundCloud Basshead',
      duration: '4:15',
      views: '12M streams',
      thumbnailUrl: 'https://i.ytimg.com/vi/OPf0YbXqDm0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=OPf0YbXqDm0',
      platform: 'SoundCloud',
    ),
  ];

  static const List<VideoItem> _twitterFeed = [
    VideoItem(
      id: 'QdBZY2fkU-0',
      title: 'X Viral - SpaceX Starship Orbital Launch 4K Clip',
      author: '@SpaceX',
      duration: '2:10',
      views: '45M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/QdBZY2fkU-0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=QdBZY2fkU-0',
      platform: 'Twitter',
    ),
  ];

  static const List<VideoItem> _trendingMusic = [
    VideoItem(
      id: '60ItHLz5WEA',
      title: 'Alan Walker - Faded (Official Music Video)',
      author: 'Alan Walker',
      duration: '3:33',
      views: '3.6B views',
      thumbnailUrl: 'https://i.ytimg.com/vi/60ItHLz5WEA/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=60ItHLz5WEA',
      platform: 'YouTube',
    ),
    VideoItem(
      id: 'JGwWNGJdvx8',
      title: 'Ed Sheeran - Shape of You',
      author: 'Ed Sheeran',
      duration: '4:24',
      views: '6.2B views',
      thumbnailUrl: 'https://i.ytimg.com/vi/JGwWNGJdvx8/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=JGwWNGJdvx8',
      platform: 'YouTube',
    ),
  ];

  static const List<VideoItem> _trendingGaming = [
    VideoItem(
      id: 'e1Z_yGzJ_H0',
      title: 'Minecraft 1.21 Update - Official Gameplay Trailer',
      author: 'Minecraft',
      duration: '2:15',
      views: '12M views',
      thumbnailUrl: 'https://i.ytimg.com/vi/e1Z_yGzJ_H0/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=e1Z_yGzJ_H0',
      platform: 'YouTube',
    ),
  ];

  static const List<VideoItem> _trendingTech = [
    VideoItem(
      id: '7b7z8k79N4Q',
      title: 'Building a Next-Gen Flutter Application in 2026',
      author: 'Flutter Official',
      duration: '18:40',
      views: '450K views',
      thumbnailUrl: 'https://i.ytimg.com/vi/7b7z8k79N4Q/hqdefault.jpg',
      videoUrl: 'https://www.youtube.com/watch?v=7b7z8k79N4Q',
      platform: 'YouTube',
    ),
  ];
}
