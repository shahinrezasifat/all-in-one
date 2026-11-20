import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WatchHistoryItem {
  final String movieId;
  final String title;
  final String posterUrl;
  final String backdropUrl;
  final double positionSeconds;
  final double totalSeconds;
  final int seasonNumber;
  final int episodeNumber;
  final String episodeTitle;
  final DateTime lastWatched;
  final String sourceUrl;
  final String quality;
  final String audioTrack;

  const WatchHistoryItem({
    required this.movieId,
    required this.title,
    required this.posterUrl,
    required this.backdropUrl,
    required this.positionSeconds,
    required this.totalSeconds,
    this.seasonNumber = 1,
    this.episodeNumber = 1,
    this.episodeTitle = '',
    required this.lastWatched,
    required this.sourceUrl,
    this.quality = '1080p',
    this.audioTrack = 'Default',
  });

  double get progress => totalSeconds > 0 ? (positionSeconds / totalSeconds).clamp(0.0, 1.0) : 0.0;

  String get positionFormatted {
    final s = positionSeconds.toInt();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  String get durationFormatted {
    final s = totalSeconds.toInt();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
    'movieId': movieId,
    'title': title,
    'posterUrl': posterUrl,
    'backdropUrl': backdropUrl,
    'positionSeconds': positionSeconds,
    'totalSeconds': totalSeconds,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'episodeTitle': episodeTitle,
    'lastWatched': lastWatched.toIso8601String(),
    'sourceUrl': sourceUrl,
    'quality': quality,
    'audioTrack': audioTrack,
  };

  factory WatchHistoryItem.fromJson(Map<String, dynamic> json) => WatchHistoryItem(
    movieId: json['movieId'] as String? ?? '',
    title: json['title'] as String? ?? '',
    posterUrl: json['posterUrl'] as String? ?? '',
    backdropUrl: json['backdropUrl'] as String? ?? '',
    positionSeconds: (json['positionSeconds'] as num?)?.toDouble() ?? 0.0,
    totalSeconds: (json['totalSeconds'] as num?)?.toDouble() ?? 7200.0,
    seasonNumber: json['seasonNumber'] as int? ?? 1,
    episodeNumber: json['episodeNumber'] as int? ?? 1,
    episodeTitle: json['episodeTitle'] as String? ?? '',
    lastWatched: DateTime.tryParse(json['lastWatched'] as String? ?? '') ?? DateTime.now(),
    sourceUrl: json['sourceUrl'] as String? ?? '',
    quality: json['quality'] as String? ?? '1080p',
    audioTrack: json['audioTrack'] as String? ?? 'Default',
  );
}

class WatchHistoryService extends ChangeNotifier {
  static final WatchHistoryService instance = WatchHistoryService._();
  WatchHistoryService._() {
    _init();
  }

  static const String _prefsKey = 'snaptube_watch_history_v1';
  List<WatchHistoryItem> _history = [];

  List<WatchHistoryItem> get history => List.unmodifiable(_history);

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final List<dynamic> list = jsonDecode(raw);
        _history = list.map((e) => WatchHistoryItem.fromJson(e as Map<String, dynamic>)).toList();
        _history.sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
      } catch (_) {
        _history = [];
      }
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_history.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, raw);
  }

  WatchHistoryItem? getProgress(String movieId) {
    try {
      return _history.firstWhere((h) => h.movieId == movieId);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveProgress({
    required String movieId,
    required String title,
    required String posterUrl,
    required String backdropUrl,
    required double positionSeconds,
    required double totalSeconds,
    int seasonNumber = 1,
    int episodeNumber = 1,
    String episodeTitle = '',
    required String sourceUrl,
    String quality = '1080p',
    String audioTrack = 'Default',
  }) async {
    // If completed (more than 95%), we can either keep or reset
    final item = WatchHistoryItem(
      movieId: movieId,
      title: title,
      posterUrl: posterUrl,
      backdropUrl: backdropUrl,
      positionSeconds: positionSeconds,
      totalSeconds: totalSeconds,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeTitle: episodeTitle,
      lastWatched: DateTime.now(),
      sourceUrl: sourceUrl,
      quality: quality,
      audioTrack: audioTrack,
    );

    _history.removeWhere((h) => h.movieId == movieId);
    _history.insert(0, item);

    // Keep top 20 items in history
    if (_history.length > 20) {
      _history = _history.sublist(0, 20);
    }

    await _save();
    notifyListeners();
  }

  Future<void> removeFromHistory(String movieId) async {
    _history.removeWhere((h) => h.movieId == movieId);
    await _save();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _save();
    notifyListeners();
  }
}
