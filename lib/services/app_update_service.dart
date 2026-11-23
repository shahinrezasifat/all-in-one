import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
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
    this.apkSize,
    this.apkDigest,
  });

  final String version;
  final String notes;
  final Uri releaseUrl;
  final Uri? apkUrl;
  final int? apkSize;
  final String? apkDigest;
}

typedef UpdateDownload = Future<void> Function(
  AppUpdate update,
  void Function(int received, int? total) onProgress,
);

Future<void> downloadAppUpdate(
  AppUpdate update,
  void Function(int received, int? total) onProgress, {
  http.Client? client,
  Directory? cache,
}) async {
  final url = _releaseLink(update.apkUrl?.toString(), 'download');
  if (url == null)
    throw FormatException('No Android package is attached to the release.');

  final root = cache ?? await getTemporaryDirectory();
  final directory = await Directory('${root.path}/app-updates').create();
  final apk = File('${directory.path}/update.apk');
  final partial = File('${directory.path}/update.apk.part');
  final transport = client ?? http.Client();
  const limit = 1024 * 1024 * 1024;
  try {
    var target = url;
    late http.StreamedResponse response;
    for (var redirects = 0; ; redirects++) {
      response = await transport
          .send(http.Request('GET', target)..followRedirects = false)
          .timeout(const Duration(seconds: 30));
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) break;
      final location = response.headers['location'];
      final next = location == null ? null : target.resolve(location);
      if (redirects >= 4 ||
          next == null ||
          next.scheme != 'https' ||
          next.userInfo.isNotEmpty ||
          next.port != 443 ||
          (next.host != 'release-assets.githubusercontent.com' &&
              next.host != 'objects.githubusercontent.com' &&
              _releaseLink(next.toString(), 'download') == null)) {
        throw const FormatException('Invalid GitHub asset redirect');
      }
      await response.stream.drain<void>().timeout(const Duration(seconds: 10));
      target = next;
    }
    final total = update.apkSize ?? response.contentLength;
    if (response.statusCode != 200 ||
        (total != null && (total <= 0 || total > limit))) {
      throw const FormatException('Invalid APK download response');
    }

    var received = 0;
    final output = await partial.open(mode: FileMode.write);
    try {
      onProgress(0, total);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        received += chunk.length;
        if (received > (total ?? limit)) {
          throw const FormatException('APK exceeds the expected size');
        }
        await output.writeFrom(chunk);
        onProgress(received, total);
      }
    } finally {
      await output.close();
    }
    if (received == 0 || (total != null && received != total)) {
      throw const FormatException('Incomplete APK download');
    }
    final expected = update.apkDigest;
    if (expected != null &&
        'sha256:${await sha256.bind(partial.openRead()).first}' != expected) {
      throw const FormatException('APK checksum does not match GitHub');
    }
    await partial.rename(apk.path);
  } finally {
    if (client == null) transport.close();
    if (await partial.exists()) await partial.delete();
  }
}

Future<bool> installAppUpdate() async =>
    await _updateChannel.invokeMethod<bool>('installUpdate') ?? false;

Future<void> openAppInstallSettings() =>
    _updateChannel.invokeMethod<void>('openInstallSettings');

Future<void> restartAfterAppUpdate() =>
    _updateChannel.invokeMethod<void>('restartAfterUpdate');

Future<List<String>> _supportedAbis() async {
  try {
    return await _updateChannel
            .invokeListMethod<String>('supportedAbis')
            .timeout(const Duration(seconds: 2)) ??
        [];
  } on Exception {
    return [];
  }
}

int? _assetSize(Object? value) => value is int && value > 0 ? value : null;

String? _assetDigest(Object? value) =>
    value is String && RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(value)
    ? value
    : null;

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

Future<AppUpdate?> requestAutomaticAppUpdate() async {
  if (requiredAppUpdate.value case final update?) return update;
  if (await installedAndroidVersion == null) return null;
  try {
    if (await _updateChannel
            .invokeMethod<bool>('hasUpdateWifi')
            .timeout(const Duration(seconds: 2)) ==
        true) {
      return await requestAppUpdate();
    }
  } on Exception {
    // Manual checks remain available from Settings.
  }
  return checkForAppUpdate(allowNetwork: false);
}

Future<AppUpdate?> checkForAppUpdate({bool allowNetwork = true}) async {
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
      final apkUrl = data is Map<String, dynamic>
          ? _releaseLink(data['apkUrl'], 'download')
          : null;
      if (data is Map<String, dynamic> &&
          version is String &&
          apkUrl != null &&
          _parseVersion(version) > _parseVersion(installedVersion)) {
        remembered = AppUpdate(
          version: version,
          notes: data['notes'] is String ? data['notes'] as String : '',
          releaseUrl:
              _releaseLink(data['releaseUrl'], 'tag') ??
              Uri.https('github.com', '/$_repository/releases/latest'),
          apkUrl: apkUrl,
          apkSize: _assetSize(data['apkSize']),
          apkDigest: _assetDigest(data['apkDigest']),
        );
      } else {
        await preferences.remove(_requiredReleaseKey);
      }
    }
  } on Exception {
    // A local storage error must not interfere with the live release check.
  }

  if (!allowNetwork) return remembered;
  final client = http.Client();
  try {
    final live = await fetchAppUpdate(
      client,
      installedVersion,
      supportedAbis: await _supportedAbis(),
    );
    if (live == null || live.apkUrl == null) return remembered;
    try {
      await preferences?.setString(
        _requiredReleaseKey,
        jsonEncode({
          'version': live.version,
          'notes': live.notes,
          'releaseUrl': live.releaseUrl.toString(),
          'apkUrl': live.apkUrl?.toString(),
          'apkSize': live.apkSize,
          'apkDigest': live.apkDigest,
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
  String installedVersion, {
  List<String> supportedAbis = const [],
}) async {
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
    int? apkSize;
    String? apkDigest;
    var bestRank = supportedAbis.length + 3;
    final assets = release['assets'];
    if (assets is List) {
      for (final asset in assets.whereType<Map<String, dynamic>>()) {
        final name = asset['name'];
        if (name is! String ||
            !RegExp(r'\.apks?$').hasMatch(name.toLowerCase()) ||
            asset['state'] != 'uploaded') {
          continue;
        }
        final url = _releaseLink(asset['browser_download_url'], 'download');
        if (url == null ||
            url.pathSegments.length != 6 ||
            url.pathSegments[4] != tag ||
            url.pathSegments.last != name) {
          continue;
        }
        final universal = name == 'all-in-one-v$latest.apk';
        final bundle = name == 'all-in-one-v$latest.apks';
        final abi = RegExp(r'-(arm64-v8a|armeabi-v7a|x86_64|x86)\.apk$')
            .firstMatch(name)
            ?.group(1);
        if (!universal && !bundle && abi == null && name != 'all-in-one.apk') {
          continue;
        }
        final abiOrder = supportedAbis.indexOf(abi ?? '');
        if (abi != null && abiOrder < 0 && !universal) continue;
        final rank = universal
            ? 0
            : abiOrder >= 0
            ? abiOrder + 1
            : bundle
            ? supportedAbis.length + 2
            : supportedAbis.length + 1;
        if (rank < bestRank) {
          apkUrl = url;
          apkSize = _assetSize(asset['size']);
          apkDigest = _assetDigest(asset['digest']);
          bestRank = rank;
        }
        if (universal) break;
      }
    }

    final notes = release['body'];
    return AppUpdate(
      version: latest.toString(),
      notes: notes is String ? notes.trim() : '',
      releaseUrl: releaseUrl,
      apkUrl: apkUrl,
      apkSize: apkSize,
      apkDigest: apkDigest,
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
