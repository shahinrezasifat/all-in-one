import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repository = 'shahinrezasifat/all-in-one';
const _updateChannel = MethodChannel('snaptube_pure/app_update');
const _requiredReleaseKey = 'required_github_app_release';

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.notes,
    required this.releaseUrl,
    this.apkUrl,
  });

  final String version;
  final String notes;
  final Uri releaseUrl;
  final Uri? apkUrl;
}

final installedAndroidVersion = _readInstalledAndroidVersion();
final requiredAppUpdate = ValueNotifier<AppUpdate?>(null);
Future<AppUpdate?>? _runningUpdateCheck;

Future<AppUpdate?> requestAppUpdate() {
  final known = requiredAppUpdate.value;
  if (known != null) return Future.value(known);
  return _runningUpdateCheck ??= checkForAppUpdate()
      .then((update) {
        if (update != null) requiredAppUpdate.value = update;
        return update;
      })
      .whenComplete(() => _runningUpdateCheck = null);
}

Future<String?> _readInstalledAndroidVersion() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;

  try {
    return await _updateChannel
        .invokeMethod<String>('getInstalledVersion')
        .timeout(const Duration(seconds: 2));
  } on Exception {
    return null;
  }
}

Future<AppUpdate?> checkForAppUpdate() async {
  final installedVersion = await installedAndroidVersion;
  if (installedVersion == null) return null;

  SharedPreferences? preferences;
  AppUpdate? remembered;
  try {
    preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_requiredReleaseKey);
    if (encoded != null) {
      final data = jsonDecode(encoded);
      final version = data is Map<String, dynamic> ? data['version'] : null;
      if (data is Map<String, dynamic> &&
          version is String &&
          _parseVersion(version) > _parseVersion(installedVersion)) {
        remembered = AppUpdate(
          version: version,
          notes: data['notes'] is String ? data['notes'] as String : '',
          releaseUrl:
              _releaseLink(data['releaseUrl'], 'tag') ??
              Uri.https('github.com', '/$_repository/releases/latest'),
          apkUrl: _releaseLink(data['apkUrl'], 'download'),
        );
      } else {
        await preferences.remove(_requiredReleaseKey);
      }
    }
  } on Exception {
    // A local storage error must not interfere with the live release check.
  }

  final client = http.Client();
  try {
    final live = await fetchAppUpdate(client, installedVersion);
    if (live == null) return remembered;
    try {
      await preferences?.setString(
        _requiredReleaseKey,
        jsonEncode({
          'version': live.version,
          'notes': live.notes,
          'releaseUrl': live.releaseUrl.toString(),
          'apkUrl': live.apkUrl?.toString(),
        }),
      );
    } on Exception {
      // The dialog can still block the running app if saving fails.
    }
    return live;
  } finally {
    client.close();
  }
}

Future<AppUpdate?> fetchAppUpdate(
  http.Client client,
  String installedVersion,
) async {
  try {
    final installed = _parseVersion(installedVersion);
    final response = await client
        .get(
          Uri.https('api.github.com', '/repos/$_repository/releases/latest'),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) return null;

    final release = jsonDecode(utf8.decode(response.bodyBytes));
    if (release is! Map<String, dynamic>) return null;
    final tag = release['tag_name'];
    if (tag is! String ||
        release['draft'] == true ||
        release['prerelease'] == true) {
      return null;
    }
    final latest = _parseVersion(tag);
    if (latest <= installed) return null;

    final releaseUrl =
        _releaseLink(release['html_url'], 'tag') ??
        Uri.https('github.com', '/$_repository/releases/latest');
    Uri? apkUrl;
    final assets = release['assets'];
    if (assets is List) {
      for (final asset in assets.whereType<Map<String, dynamic>>()) {
        final name = asset['name'];
        if (name is! String ||
            !name.toLowerCase().endsWith('.apk') ||
            asset['state'] != 'uploaded') {
          continue;
        }
        final url = _releaseLink(asset['browser_download_url'], 'download');
        if (url == null || url.pathSegments.last != name) continue;
        if (name == 'all-in-one-v$latest.apk') {
          apkUrl = url;
          break;
        }
        apkUrl ??= url;
      }
    }

    final notes = release['body'];
    return AppUpdate(
      version: latest.toString(),
      notes: notes is String ? notes.trim() : '',
      releaseUrl: releaseUrl,
      apkUrl: apkUrl,
    );
  } on Exception {
    // Offline, unavailable, and invalid release responses allow normal startup.
    return null;
  }
}

Version _parseVersion(String value) {
  final version = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
  // GitHub tags track the version name. Build metadata has no precedence.
  return Version.parse(version.split('+').first);
}

Uri? _releaseLink(Object? value, String type) {
  final uri = value is String ? Uri.tryParse(value) : null;
  final prefix = '/$_repository/releases/$type/';
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.authority != 'github.com' ||
      !uri.path.startsWith(prefix) ||
      uri.path.length == prefix.length) {
    return null;
  }
  return uri;
}
