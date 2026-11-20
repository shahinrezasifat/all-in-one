import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

const _repository = 'shahinrezasifat1999/all-in-one';
const _updateChannel = MethodChannel('snaptube_pure/app_update');

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

  final client = http.Client();
  try {
    return await fetchAppUpdate(client, installedVersion);
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
