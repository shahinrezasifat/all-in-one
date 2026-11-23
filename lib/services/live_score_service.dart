import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// A tiny, dependency-free client for free/no-key live-cricket score APIs.
///
/// The default endpoint is an open-source free IPL score API. Users can point
/// it at any compatible free endpoint from Settings without an app update.
class LiveMatch {
  const LiveMatch({
    required this.title,
    required this.teamA,
    required this.scoreA,
    required this.teamB,
    required this.scoreB,
    required this.status,
  });

  final String title;
  final String teamA;
  final String scoreA;
  final String teamB;
  final String scoreB;
  final String status;
}

class LiveScoreService {
  LiveScoreService._();

  static final LiveScoreService instance = LiveScoreService._();

  static const endpointKey = 'live_score_api_endpoint';
  static const defaultEndpoint =
      'https://ipl-2026-api-free.onrender.com/ipl-2026-live-score';

  DateTime? _lastFetch;
  DateTime? _lastFailure;
  List<LiveMatch> _cache = [];

  Future<String> get endpoint async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(endpointKey)?.trim().isNotEmpty == true
          ? prefs.getString(endpointKey)!.trim()
          : defaultEndpoint;
    } catch (_) {
      return defaultEndpoint;
    }
  }

  Future<void> setEndpoint(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(endpointKey, url.trim());
    } catch (_) {}
    _lastFetch = null;
  }

  Future<List<LiveMatch>> fetch({bool force = false}) async {
    if (!force &&
        _lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < const Duration(minutes: 2)) {
      return _cache;
    }
    // A failed/offline endpoint must not be retried on every rebuild.
    if (!force &&
        _lastFailure != null &&
        DateTime.now().difference(_lastFailure!) < const Duration(minutes: 10)) {
      return _cache;
    }
    try {
      final uri = Uri.parse(await endpoint);
      if (!uri.isAbsolute ||
          (uri.scheme != 'https' && uri.scheme != 'http')) {
        return _cache;
      }
      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return _cache;
      final decoded = jsonDecode(response.body);
      final matches = _parse(decoded);
      _cache = matches;
      _lastFetch = DateTime.now();
      _lastFailure = null;
      return matches;
    } catch (error) {
      _lastFailure = DateTime.now();
      debugPrint('Live score unavailable: $error');
      return _cache;
    }
  }

  List<LiveMatch> _parse(Object? decoded) {
    final result = <LiveMatch>[];
    final dynamic root = decoded is Map<String, dynamic>
        ? (decoded['matches'] ?? decoded['data'] ?? decoded)
        : decoded;

    if (root is Map) {
      for (final value in root.values) {
        final match = _one(value);
        if (match != null) result.add(match);
      }
    } else if (root is List) {
      for (final value in root) {
        final match = _one(value);
        if (match != null) result.add(match);
      }
    }
    return result.take(6).toList();
  }

  LiveMatch? _one(dynamic value) {
    if (value is! Map) return null;
    String str(Object? key, [String fallback = '']) =>
        value[key]?.toString().trim() ?? fallback;
    final title = str('title', str('name', str('match', 'Live match')));
    final teamA = str('team_1', str('team1', str('homeTeam', 'Team A')));
    final teamB = str('team_2', str('team2', str('awayTeam', 'Team B')));
    if (title.isEmpty && teamA.isEmpty && teamB.isEmpty) return null;
    return LiveMatch(
      title: title,
      teamA: teamA,
      scoreA: str('score_1', str('score1', str('homeScore', '—'))),
      teamB: teamB,
      scoreB: str('score_2', str('score2', str('awayScore', '—'))),
      status: str('status', str('status_text', str('state', 'LIVE'))),
    );
  }
}
