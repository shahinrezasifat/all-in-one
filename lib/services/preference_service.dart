import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/movie_model.dart';

/// A single user interaction fed into the [PreferenceService] engine.
enum PreferenceSignal {
  watchVideo,
  downloadVideo,
  searchVideo,
}

/// Content-aware recommendation engine.
///
/// It passively logs every meaningful interaction (audio plays, audio/video
/// downloads, video watches, searches and artist-profile opens) and folds them
/// into a set of exponentially-decayed weighted counters — one per preference
/// dimension: audio artists / genres / formats, and video categories /
/// languages / qualities. Because each write multiplies the existing counters
/// by a time-based decay factor before adding the new weight, the profile
/// continuously re-weights toward RECENT behavior: the more the app is used,
/// the sharper the taste model becomes, and stale preferences fade on their own.
///
/// The engine exposes pure scoring + ranking helpers so both the audio and
/// video surfaces can order their (already genuine, network-backed) catalogs by
/// personal relevance instead of generic popularity. It NEVER invents content —
/// it only re-ranks real items handed to it.
class PreferenceService extends ChangeNotifier {
  PreferenceService._() {
    _ready = _init();
  }

  static final PreferenceService instance = PreferenceService._();

  late final Future<void> _ready;
  Future<void> get ready => _ready;

  static const String _prefsKey = 'snaptube_preferences_v1';

  /// Interaction weights — a download is a stronger declaration of taste than a
  /// play, which is stronger than a search.
  static const double _wDownload = 2.4;
  static const double _wWatch = 1.3;
  static const double _wSearch = 0.4;

  /// Half-life (days) of the recency decay applied on every write.
  static const double _halfLifeDays = 30.0;

  // Dimension -> (normalized key -> weighted score).
  final Map<String, double> _artists = {};
  final Map<String, double> _genres = {};
  final Map<String, double> _formats = {};
  final Map<String, double> _categories = {};
  final Map<String, double> _languages = {};
  final Map<String, double> _qualities = {};

  /// Titles already engaged with (watched / downloaded) — used to avoid
  /// re-recommending the exact same item.
  final Map<String, double> _seenTitles = {};

  /// Recent search queries the user actually typed, most-recent first.
  /// Surfaced on the home (video) and audio browse screens so re-entering the
  /// app shows what the user cared about instead of an identical static feed.
  final List<String> _recentVideoSearches = [];
  final List<String> _recentAudioSearches = [];

  /// Artists the user explicitly starred. These always rank first and their
  /// tracks are promoted everywhere (play, recommend, download).
  final Set<String> _starredArtists = {};

  /// How many recent searches are kept per surface.
  static const int _maxRecentSearches = 12;

  List<String> get recentVideoSearches => List.unmodifiable(_recentVideoSearches);
  List<String> get recentAudioSearches => List.unmodifiable(_recentAudioSearches);
  List<String> get starredArtists => List.unmodifiable(_starredArtists);

  bool isArtistStarred(String name) =>
      _starredArtists.contains(name.toLowerCase().trim());

  /// Star an artist once and their songs lead the recommendations, plays and
  /// download lists from then on — stored persistently with the taste profile.
  void toggleArtistStar(String name) {
    final key = name.toLowerCase().trim();
    if (key.isEmpty) return;
    if (!_starredArtists.remove(key)) _starredArtists.add(key);
    unawaited(_save());
    notifyListeners();
  }

  int _interactions = 0;
  int _lastTouchMillis = 0;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Minimum evidence before we bother personalizing. Below this the UI shows
  /// the normal (genuine) catalog and a gentle "keep listening" hint.
  bool get hasEnoughSignal => _interactions >= 6;

  int get interactionCount => _interactions;

  // --------------------------------------------------------------------------
  // Persistence
  // --------------------------------------------------------------------------

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _artists.addAll(_decodeDim(map['artists']));
        _genres.addAll(_decodeDim(map['genres']));
        _formats.addAll(_decodeDim(map['formats']));
        _categories.addAll(_decodeDim(map['categories']));
        _languages.addAll(_decodeDim(map['languages']));
        _qualities.addAll(_decodeDim(map['qualities']));
        _seenTitles.addAll(_decodeDim(map['seen']));
        _recentVideoSearches.addAll(_decodeSearchList(map['recentVideoSearches']));
        _recentAudioSearches.addAll(_decodeSearchList(map['recentAudioSearches']));
        _starredArtists.addAll(
          _decodeSearchList(map['starredArtists'])
              .map((s) => s.toLowerCase().trim())
              .where((s) => s.isNotEmpty),
        );
        _interactions = (map['interactions'] as num?)?.toInt() ?? 0;
        _lastTouchMillis = (map['lastTouch'] as num?)?.toInt() ?? 0;
      }
    } catch (e) {
      debugPrint('[Preference] load failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Map<String, double> _decodeDim(dynamic raw) {
    if (raw is! Map) return {};
    final out = <String, double>{};
    raw.forEach((k, v) {
      final d = (v as num?)?.toDouble();
      if (d != null && d > 0) out[k.toString()] = d;
    });
    return out;
  }

  List<String> _decodeSearchList(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .map((e) => e.toString())
        .where((s) => s.trim().isNotEmpty)
        .toList();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'artists': _artists,
        'genres': _genres,
        'formats': _formats,
        'categories': _categories,
        'languages': _languages,
        'qualities': _qualities,
        'seen': _seenTitles,
        'recentVideoSearches': _recentVideoSearches,
        'recentAudioSearches': _recentAudioSearches,
        'starredArtists': _starredArtists.toList(),
        'interactions': _interactions,
        'lastTouch': _lastTouchMillis,
      };
      await prefs.setString(_prefsKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('[Preference] save failed: $e');
    }
  }

  // --------------------------------------------------------------------------
  // Core weighted, time-decayed accumulation
  // --------------------------------------------------------------------------

  /// Multiply every counter by the recency decay for the time elapsed since the
  /// last write, then add [weight] to [key]. Applied globally so the whole
  /// profile ages uniformly and recent activity dominates.
  void _touchAllMaps() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastTouchMillis > 0) {
      final days = (now - _lastTouchMillis) / (1000.0 * 60 * 60 * 24);
      if (days >= 0.25) {
        final factor = math.pow(0.5, days / _halfLifeDays).toDouble();
        for (final m in [
          _artists, _genres, _formats, _categories, _languages, _qualities, _seenTitles,
        ]) {
          m.forEach((k, v) => m[k] = v * factor);
        }
      }
    }
    _lastTouchMillis = now;
  }

  void _add(Map<String, double> m, String? rawKey, double weight) {
    final key = rawKey?.toLowerCase().trim() ?? '';
    if (key.isEmpty || weight <= 0) return;
    m[key] = (m[key] ?? 0.0) + weight;
  }

  void _commit() {
    _touchAllMaps();
    _interactions++;
    unawaited(_save());
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  // Public logging API
  // --------------------------------------------------------------------------

  /// Logs a movie/series WATCH. [audioTrackLabel] and [quality] are the stream
  /// the user actually played, so language + quality preferences are learned.
  void logVideoWatch(MovieItem movie, {String? audioTrackLabel, String? quality}) {
    _logVideoCommon(movie, _wWatch, audioTrackLabel: audioTrackLabel, quality: quality);
  }

  /// Logs a movie/series DOWNLOAD — strong quality + language + category signal.
  void logVideoDownload(MovieItem movie, {String? quality, String? resolution}) {
    _logVideoCommon(
      movie,
      _wDownload,
      quality: quality ?? resolution,
    );
  }

  void _logVideoCommon(MovieItem movie, double w, {String? audioTrackLabel, String? quality}) {
    for (final g in movie.genres) {
      _add(_categories, g, w * 0.6);
    }
    // Type bucket (movie / series / anime) is itself a category.
    if (movie.isSeries) _add(_categories, 'series', w * 0.4);
    final langText = [
      movie.title,
      ...movie.genres,
      ...movie.audioTracks,
      movie.providerName,
      movie.providerId,
      audioTrackLabel ?? '',
    ].join(' ').toLowerCase();
    for (final lang in detectLanguages(langText)) {
      _add(_languages, lang, w * 0.7);
    }
    final qKey = qualityKey(quality ?? movie.quality);
    if (qKey.isNotEmpty) _add(_qualities, qKey, w * 0.6);
    _add(_seenTitles, movie.title, w * 0.5);
    _commit();
  }

  /// Logs a SEARCH. The query string is matched against known dimension keys so
  /// searching "Arijit flac" nudges that artist + format, without inventing keys.
  /// The query itself is also recorded in the per-surface recent-search history
  /// that the home / audio browse screens surface so the feed reflects what the
  /// user actually looked for.
  void logSearch(String query, {required bool isAudio}) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return;
    if (isAudio) {
      _bumpKeysContainedIn(_artists, q, _wSearch);
      _bumpKeysContainedIn(_genres, q, _wSearch);
    } else {
      _bumpKeysContainedIn(_categories, q, _wSearch);
      _bumpKeysContainedIn(_languages, q, _wSearch);
    }
    _recordRecentSearch(query, isAudio: isAudio);
    _commit();
  }

  /// Records [query] at the front of the matching surface's recent-search list,
  /// de-duplicated (case-insensitive) and capped at [_maxRecentSearches].
  void _recordRecentSearch(String query, {required bool isAudio}) {
    final q = query.trim();
    if (q.isEmpty) return;
    final list = isAudio ? _recentAudioSearches : _recentVideoSearches;
    list.removeWhere((e) => e.toLowerCase() == q.toLowerCase());
    list.insert(0, q);
    if (list.length > _maxRecentSearches) {
      list.removeRange(_maxRecentSearches, list.length);
    }
  }

  /// Clears the recent-search history for one surface (or both when null).
  void clearRecentSearches({bool? isAudio}) {
    if (isAudio == null) {
      _recentVideoSearches.clear();
      _recentAudioSearches.clear();
    } else if (isAudio) {
      _recentAudioSearches.clear();
    } else {
      _recentVideoSearches.clear();
    }
    unawaited(_save());
    notifyListeners();
  }

  /// Increments existing keys of [m] that appear as substrings of [text]. Never
  /// creates new keys — a search only reinforces dimensions already learned.
  void _bumpKeysContainedIn(Map<String, double> m, String text, double weight) {
    for (final entry in m.entries.toList()) {
      if (text.contains(entry.key)) m[entry.key] = entry.value + weight;
    }
  }

  Future<void> resetAll() async {
    _artists.clear();
    _genres.clear();
    _formats.clear();
    _categories.clear();
    _languages.clear();
    _qualities.clear();
    _seenTitles.clear();
    _recentVideoSearches.clear();
    _recentAudioSearches.clear();
    _interactions = 0;
    _lastTouchMillis = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  // Detection helpers (pure, reusable)
  // --------------------------------------------------------------------------

  /// Normalized audio codec/format bucket: mp3 / flac / aac / opus / m4a / ogg /
  /// wav / otherwise ''. Understands both codec tokens and bitrate strings.
  static String audioFormatKey(String? format, String? extra) {
    final s = '${format ?? ''} ${extra ?? ''}'.toLowerCase();
    if (s.contains('flac') || s.contains('lossless')) return 'flac';
    if (s.contains('opus')) return 'opus';
    if (s.contains('ogg')) return 'ogg';
    if (s.contains('wav')) return 'wav';
    if (s.contains('aac')) return 'aac';
    if (s.contains('m4a') || s.contains('mp4') || s.contains('alac')) return 'm4a';
    if (s.contains('mp3')) return 'mp3';
    return '';
  }

  /// Normalized video quality bucket: 4k / 1080p / 720p / 480p / 360p or ''.
  static String qualityKey(String? raw) {
    final s = (raw ?? '').toLowerCase();
    if (s.contains('2160') || s.contains('4k') || s.contains('uhd')) return '4k';
    if (s.contains('1080')) return '1080p';
    if (s.contains('720')) return '720p';
    if (s.contains('480')) return '480p';
    if (s.contains('360')) return '360p';
    return '';
  }

  /// Detects language tokens from a combined lowercased text blob.
  static Set<String> detectLanguages(String text) {
    final out = <String>{};
    bool has(String k) => text.contains(k);
    if (has('bangla') || has('bengali') || has('বাংলা') || has('bdix')) out.add('bengali');
    if (has('hindi') || has('bollywood') || has('हिन्दी') || has('दुब')) out.add('hindi');
    if (has('tamil') || has('தமிழ்')) out.add('tamil');
    if (has('telugu') || has('తెలుగు')) out.add('telugu');
    if (has('malayalam') || has('മലയാളം')) out.add('malayalam');
    if (has('japanese') || has('anime') || has('এনিমে') || has('subbed')) out.add('japanese');
    if (has('korean') || has('kdrama')) out.add('korean');
    if (has('english') || has('eng dub') || has('dolby') || has('5.1')) out.add('english');
    // Bengali-script titles are almost always Bangla.
    for (final r in text.runes) {
      if (r >= 0x0980 && r <= 0x09FF) {
        out.add('bengali');
        break;
      }
    }
    return out;
  }

  // --------------------------------------------------------------------------
  // Scoring — each dimension normalized to its own max so weights compare.
  // --------------------------------------------------------------------------

  double _norm(Map<String, double> m, String? rawKey) {
    final key = rawKey?.toLowerCase().trim() ?? '';
    if (key.isEmpty || m.isEmpty) return 0.0;
    final v = m[key];
    if (v == null || v <= 0) return 0.0;
    double max = 0.0;
    for (final e in m.values) {
      if (e > max) max = e;
    }
    return max <= 0 ? 0.0 : (v / max);
  }

  /// 0..1 relevance of a movie. Category + language + quality affinity weighted,
  /// with a NEWNESS bonus scaled by category/language affinity so fresh titles in
  /// preferred buckets rise to the top.
  double movieScore(MovieItem movie) {
    double cat = 0.0;
    for (final g in movie.genres) {
      final n = _norm(_categories, g);
      if (n > cat) cat = n;
    }
    if (movie.isSeries) {
      final n = _norm(_categories, 'series');
      if (n > cat) cat = n;
    }
    final langText = [
      movie.title,
      ...movie.genres,
      ...movie.audioTracks,
      movie.providerName,
      movie.providerId,
    ].join(' ').toLowerCase();
    double lang = 0.0;
    for (final l in detectLanguages(langText)) {
      final n = _norm(_languages, l);
      if (n > lang) lang = n;
    }
    double qual = _norm(_qualities, qualityKey(movie.quality));
    if (qual == 0.0) {
      for (final s in movie.sources) {
        final n = _norm(_qualities, qualityKey(s.resolution));
        if (n > qual) qual = n;
      }
    }
    final base = 0.38 * cat + 0.32 * lang + 0.2 * qual;
    final fresh = ((movie.year - 2015).clamp(0, 10)) / 10.0;
    final freshBonus = 0.12 * fresh * (1.0 + cat + lang);
    return (base + freshBonus).clamp(0.0, 1.0);
  }

  // --------------------------------------------------------------------------
  // Ranking / suggestion helpers
  // --------------------------------------------------------------------------

  List<MovieItem> rankMovies(List<MovieItem> items, {int? limit}) {
    final list = List<MovieItem>.from(items);
    list.sort((a, b) => movieScore(b).compareTo(movieScore(a)));
    if (limit != null && list.length > limit) return list.sublist(0, limit);
    return list;
  }

  /// "More like what I watch": genre-overlap similarity against the user's
  /// recently-engaged titles' categories. Returns candidates ranked by combined
  /// personal relevance + shared-genre affinity with [fromHistory].
  List<MovieItem> similarMovies(List<MovieItem> candidates, {required List<MovieItem> fromHistory, int? limit}) {
    final likedGenres = <String, double>{};
    for (final h in fromHistory) {
      final w = _seenTitles[h.title.toLowerCase().trim()] ?? 1.0;
      for (final g in h.genres) {
        final k = g.toLowerCase().trim();
        if (k.isEmpty) continue;
        likedGenres[k] = (likedGenres[k] ?? 0) + w;
      }
    }
    double sim(MovieItem m) {
      double overlap = 0;
      for (final g in m.genres) {
        overlap += likedGenres[g.toLowerCase().trim()] ?? 0;
      }
      return movieScore(m) + overlap * 0.05;
    }
    final list = List<MovieItem>.from(candidates);
    list.sort((a, b) => sim(b).compareTo(sim(a)));
    if (limit != null && list.length > limit) return list.sublist(0, limit);
    return list;
  }

  // --------------------------------------------------------------------------
  // Insight getters (for labels/headers)
  // --------------------------------------------------------------------------

  List<String> _topKeys(Map<String, double> m, int n) {
    final entries = m.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(n).map((e) => e.key).toList();
  }

  List<String> topMovieCategories({int n = 5}) => _topKeys(_categories, n);
  List<String> topMovieLanguages({int n = 4}) => _topKeys(_languages, n);
  List<String> topMovieQualities({int n = 4}) => _topKeys(_qualities, n);

  String videoTasteSummary() {
    final cats = topMovieCategories(n: 3);
    final langs = topMovieLanguages(n: 2);
    final quals = topMovieQualities(n: 2);
    final parts = <String>[
      if (cats.isNotEmpty) cats.map(_titleCase).join(', '),
      if (langs.isNotEmpty) langs.map(_titleCase).join(' / '),
      if (quals.isNotEmpty) quals.map(_titleCase).join(' / '),
    ];
    return parts.join(' • ');
  }

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s
        .split(RegExp(r'\s+'))
        .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }
}
