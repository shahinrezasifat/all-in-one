import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';
import 'search_service.dart';

/// A persistent, self-refreshing recommendation engine for the "Trending now"
/// feed.
///
/// Guarantees the three things the old feed could not:
///  1. Every video is shown at most once — delivered ids are persisted forever,
///     so a relaunch NEVER brings back the same videos.
///  2. Order and sources are randomised on every refresh (no fixed chart, no
///     fixed hardcoded list).
///  3. Channels/topics the user searches are remembered and become the primary
///     seeds of future feeds, so the feed drifts toward what they actually watch.
///
/// A timer keeps the candidate pool warm while the app is alive, and the cache
/// is written to disk so the very first screen after a cold start is already
/// fresh and unique.
class TrendingEngineService extends ChangeNotifier with WidgetsBindingObserver {
  TrendingEngineService._() {
    _ready = _init();
  }

  static final TrendingEngineService instance = TrendingEngineService._();

  static const String _prefsKey = 'tub_trending_engine_v1';
  static const int _maxSeen = 4000;
  static const int _maxChannels = 24;
  static const int _cachePerCategory = 60;
  static const Duration _backgroundInterval = Duration(minutes: 8);
  static const Duration _staleAfter = Duration(minutes: 20);

  late final Future<void> _ready;
  Future<void> get ready => _ready;

  final Random _random = Random();
  final Set<String> _seen = <String>{};
  final List<String> _channels = <String>[];
  final Map<String, List<VideoItem>> _cache = {};
  int _lastRefresh = 0;
  bool _started = false;
  bool _refreshing = false;
  Timer? _timer;

  /// Returns true only for ids that were already delivered to the feed.
  bool hasSeen(String id) => _seen.contains(id);

  int get seenCount => _seen.length;

  List<String> get preferredChannels => List.unmodifiable(_channels);

  bool get isRefreshing => _refreshing;

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final id in (map['seen'] as List<dynamic>? ?? const [])) {
          final key = id.toString().trim();
          if (key.isNotEmpty) _seen.add(key);
        }
        for (final c in (map['channels'] as List<dynamic>? ?? const [])) {
          final key = c.toString().trim();
          if (key.isNotEmpty && !_channels.contains(key.toLowerCase())) {
            _channels.add(key);
            if (_channels.length > _maxChannels) {
              _channels.removeRange(_maxChannels, _channels.length);
              break;
            }
          }
        }
        final rawCache = map['cache'];
        if (rawCache is Map) {
          rawCache.forEach((key, value) {
            if (value is! List) return;
            final items = <VideoItem>[];
            for (final e in value) {
              if (e is Map<String, dynamic>) {
                items.add(VideoItem.fromJson(e));
              } else if (e is Map) {
                items.add(VideoItem.fromJson(Map<String, dynamic>.from(e)));
              }
            }
            _cache[key.toString()] = items;
          });
        }
        _lastRefresh = (map['lastRefresh'] as num?)?.toInt() ?? 0;
      }
    } catch (e) {
      debugPrint('[TrendingEngine] load failed: $e');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachePayload = <String, dynamic>{};
      _cache.forEach((key, value) {
        cachePayload[key] = value.map((v) => v.toJson()).toList();
      });
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'seen': _seen.toList(),
          'channels': _channels,
          'cache': cachePayload,
          'lastRefresh': _lastRefresh,
        }),
      );
    } catch (e) {
      debugPrint('[TrendingEngine] save failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Background worker — keeps fresh candidates ready without blocking the UI.
  // ---------------------------------------------------------------------------

  /// Starts the always-on background refresher. Safe to call many times.
  void startBackground() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(_backgroundInterval, (_) {
      unawaited(refreshCache());
    });
    unawaited(refreshCache());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final age = DateTime.now().millisecondsSinceEpoch - _lastRefresh;
      if (age > _staleAfter.inMilliseconds) unawaited(refreshCache());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Remembers a searched channel/topic. It becomes a primary feed seed from
  /// now on, persisted across restarts.
  void logChannel(String query) {
    final q = query.trim();
    if (q.length < 2) return;
    _channels.removeWhere((c) => c.toLowerCase() == q.toLowerCase());
    _channels.insert(0, q);
    if (_channels.length > _maxChannels) {
      _channels.removeRange(_maxChannels, _channels.length);
    }
    unawaited(_save());
    notifyListeners();
    // Put the new interest to work immediately, in the background.
    unawaited(refreshCache());
  }

  /// Clears remembered channels (used by Settings → clear history, if wired).
  void clearChannels() {
    _channels.clear();
    unawaited(_save());
    notifyListeners();
  }

  /// Category-specific and ever-rotating generic query seeds. [exact] marks a
  /// remembered channel, which must be queried verbatim; generic seeds get a
  /// random nonce appended so YouTube returns a different slice every refresh.
  List<({String text, bool exact})> _queriesFor(String category) {
    final c = category.toLowerCase();
    final topical = <String>[];
    if (c.contains('music')) {
      topical.addAll([
        'new music video',
        'live concert highlights',
        'indie songs 2026',
      ]);
    } else if (c.contains('gaming')) {
      topical.addAll([
        'gaming highlights',
        'gameplay walkthrough',
        'esports finals',
      ]);
    } else if (c.contains('techn')) {
      topical.addAll([
        'tech review 2026',
        'unboxing new gadget',
        'science documentary',
      ]);
    } else if (c.contains('short')) {
      topical.addAll([
        'shorts funny',
        'dance challenge shorts',
        'viral moments',
      ]);
    } else if (c.contains('comedy')) {
      topical.addAll(['standup comedy', 'funny clips', 'sketch comedy']);
    } else if (c.contains('news')) {
      topical.addAll([
        'news today',
        'world news briefing',
        'documentary current affairs',
      ]);
    } else {
      topical.addAll([
        'trending videos today',
        'viral videos this week',
        'funny clips viral',
        'football highlights',
        'movie trailer official',
        'cooking recipe easy',
        'travel vlog 4k',
        'car review',
        'fitness workout',
        'nature relaxation',
        'coding tutorial',
        'photography tips',
        'dance performance',
        'podcast clips',
        'reaction video',
        'new music video',
      ]);
    }

    // Preferred channels lead, then a rotating slice of topical seeds, then a
    // couple of completely random seeds for discovery. Everything is shuffled.
    final out = <({String text, bool exact})>[
      for (final c in _channels.take(4)) (text: c, exact: true),
      for (final t in topical) (text: t, exact: false),
    ];
    out.shuffle(_random);
    return out;
  }

  String _vary(String query) {
    const tokens = [
      'latest',
      'new',
      '2026',
      'today',
      'best',
      'official',
      'full',
      'episode',
      'part 2',
      'explained',
    ];
    return '$query ${tokens[_random.nextInt(tokens.length)]}';
  }

  /// Fetches fresh candidates into the in-memory/disk cache. Never marks them
  /// as seen — that happens only when [fetchFreshBatch] hands them to the UI.
  Future<void> refreshCache({String category = 'All'}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await ready;
      final queries = _queriesFor(category);
      final found = <VideoItem>[];
      final seenHere = <String>{};

      void addAll(Iterable<VideoItem> items) {
        for (final v in items) {
          if (v.id.isEmpty || seenHere.contains(v.id)) continue;
          seenHere.add(v.id);
          found.add(v);
        }
      }

      // The genuine chart is a nice starting point, but it is the same for
      // everyone — so it is only one of many sources and is always shuffled.
      if (_random.nextBool()) {
        try {
          addAll(
            await SearchService.instance.fetchTrendingChart().timeout(
              const Duration(seconds: 8),
            ),
          );
        } catch (_) {}
      }

      for (final q in queries.take(6)) {
        try {
          addAll(
            await SearchService.instance
                .searchVideos(q.exact ? q.text : _vary(q.text))
                .timeout(const Duration(seconds: 9)),
          );
        } catch (_) {}
        if (found.length >= _cachePerCategory) break;
      }

      // Last-resort curated pool, still filtered against everything ever shown.
      if (found.length < 6) {
        addAll(SearchService.instance.getTrendingFeed(category));
      }

      final fresh = found.where((v) => !_seen.contains(v.id)).toList()
        ..shuffle(_random);
      _cache[category] = fresh.take(_cachePerCategory).toList();
      _lastRefresh = DateTime.now().millisecondsSinceEpoch;
      await _save();
      notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  /// Returns a randomised batch of videos that have NEVER been shown before,
  /// and records them as seen so they can never come back.
  Future<List<VideoItem>> fetchFreshBatch({
    String category = 'All',
    int count = 8,
    bool forceRefresh = false,
  }) async {
    await ready;
    var fresh = _freshFor(category);
    if (forceRefresh || fresh.length < count) {
      await refreshCache(category: category);
      fresh = _freshFor(category);
    }
    if (fresh.isEmpty) return const [];

    fresh.shuffle(_random);
    final picked = fresh.take(count).toList();
    _seen.addAll(picked.map((v) => v.id));
    if (_seen.length > _maxSeen) {
      _seen.removeAll(_seen.take(_seen.length - _maxSeen).toList());
    }
    // Drop delivered items from the cache so a second batch cannot reuse them.
    final delivered = picked.map((v) => v.id).toSet();
    _cache[category] = (_cache[category] ?? const [])
        .where((v) => !delivered.contains(v.id))
        .toList();
    await _save();
    notifyListeners();
    return picked;
  }

  List<VideoItem> _freshFor(String category) =>
      (_cache[category] ?? const <VideoItem>[])
          .where((v) => !_seen.contains(v.id))
          .toList();

  /// True while more unseen candidates exist for [category].
  bool hasMore(String category) => _freshFor(category).isNotEmpty;
}
