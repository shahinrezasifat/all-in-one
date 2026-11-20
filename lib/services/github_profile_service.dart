import 'dart:convert';

import 'package:http/http.dart' as http;

/// Shared GitHub identity used by both the Settings profile card and the
/// animated Developer screen, so the exact same photo/name/stats appear in both.
class GithubProfile {
  final String username;
  final String? name;
  final String? bio;
  final String? location;
  final int? publicRepositories;
  final Uri? avatar;

  const GithubProfile({
    required this.username,
    this.name,
    this.bio,
    this.location,
    this.publicRepositories,
    this.avatar,
  });

  Uri get avatarUrl => avatar ?? Uri.parse('https://github.com/$username.png');

  String get displayName =>
      name?.trim().isNotEmpty == true ? name!.trim() : username;
}

class GithubProfileService {
  GithubProfileService._();

  static const String username = 'shahinrezasifat';
  static const String profileUrl = 'https://github.com/$username';

  static GithubProfile? _cache;

  static Future<GithubProfile?> fetch({bool force = false}) async {
    if (_cache != null && !force) return _cache;
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.https('api.github.com', '/users/$username'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) return null;
      final avatarRaw = data['avatar_url'];
      final avatar = avatarRaw is String ? Uri.tryParse(avatarRaw) : null;
      final repos = data['public_repos'];
      _cache = GithubProfile(
        username:
            data['login'] is String && (data['login'] as String).isNotEmpty
            ? data['login'] as String
            : username,
        name: data['name'] is String ? data['name'] as String : null,
        bio: data['bio'] is String ? data['bio'] as String : null,
        location: data['location'] is String
            ? data['location'] as String
            : null,
        publicRepositories: repos is int && repos >= 0 ? repos : null,
        avatar:
            avatar?.scheme == 'https' &&
                avatar?.host == 'avatars.githubusercontent.com'
            ? avatar
            : null,
      );
      return _cache;
    } on Exception {
      return null;
    } finally {
      client.close();
    }
  }
}
