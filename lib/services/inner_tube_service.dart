import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Direct access to YouTube's InnerTube `player` endpoint.
///
/// The public watch page (and therefore `youtube_explode`) is rate limited /
/// bot-blocked from many networks, which made the whole app show nothing when
/// the user tapped Download. The InnerTube player API still answers with
/// complete, freshly signed stream URLs when called with a mobile client, so
/// it is the extractor that actually works.
class InnerTubeService {
  InnerTubeService._();

  static final InnerTubeService instance = InnerTubeService._();

  static const String _endpoint =
      'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';

  /// Client identities that still receive plain, downloadable googlevideo
  /// URLs.
  ///
  /// YouTube's 2026 streaming policy mints SABR-only / PO-token-bound
  /// manifests for every *current* client: the adaptive formats arrive with
  /// no `url` at all (only `serverAbrStreamingUrl`), so the picker collapses
  /// to a single 360p muxed stream — and any URL that does leak out answers
  /// HTTP 403. Live probing confirmed the escape hatch: the `ANDROID` app
  /// identity from 20.10.38 **without** `androidSdkVersion` (yt-dlp's
  /// "android_sdkless") still gets the complete ladder (1 muxed + 18
  /// adaptive, all with real signed URLs, `c=ANDROID`, no `n`/POT param).
  ///
  /// The current client is kept only as a last-resort fallback because its
  /// progressive 360p stream still carries a usable URL. VISIONOS always
  /// answers LOGIN_REQUIRED, and ANDROID_VR / ANDROID_KIDS are sign-in-only,
  /// so they are not worth an extra request per fetch.
  static const List<Map<String, String>> _clients = [
    {
      'name': 'ANDROID',
      'version': '20.10.38',
      'nameId': '3',
      'userAgent':
          'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
      // Deliberately EMPTY: sending androidSdkVersion is what flips YouTube
      // to a SABR/PO-token manifest for this identity.
      'androidSdk': '',
      'osName': 'Android',
      'osVersion': '11',
    },
    {
      'name': 'IOS',
      'version': '20.10.4',
      'nameId': '5',
      'userAgent':
          'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
      'androidSdk': '',
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'IOS',
      'osVersion': '18.1.0.22B83',
    },
    {
      'name': 'ANDROID',
      'version': '21.26.364',
      'nameId': '3',
      'userAgent':
          'com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip',
      'androidSdk': '30',
      'osName': 'Android',
      'osVersion': '11',
    },
  ];

  /// Client name that answered last, kept so debug logs can show which one
  /// is currently working.
  String lastWorkingClient = '';

  /// Live client preference order — starts as [_clients] but [rotateClient]
  /// reorders it. When googlevideo refuses to serve every URL minted by the
  /// leading client (mobile-network IPs often get a blanket 403 on IOS-minted
  /// streams while the same file downloads fine from a desktop IP), rotating
  /// promotes the next client so the next mint signs from a different
  /// identity — and every consumer derives the matching download UA from the
  /// URL itself via [userAgentForUrl].
  final List<Map<String, String>> _order = List.of(_clients);

  void rotateClient() {
    if (_order.length < 2) return;
    _order.add(_order.removeAt(0));
    // Any cached manifest was minted through the rejected identity — drop it
    // so the next fetch genuinely signs fresh URLs from the new head client.
    _cache.clear();
    // Silent rotation — with yt-dlp as the primary YouTube resolver these
    // legacy fallbacks must not spam the console on every 403.
  }

  /// Drops any cached manifest so subsequent resolutions mint fresh, signed URLs.
  void clearCache() {
    _cache.clear();
  }

  /// One-minute manifest cache. The picker, the download resolver and the
  /// player all ask for the same video within seconds of each other; without
  /// this the multi-client merge below would re-pay every POST per call.
  /// URLs live far longer than this window, so they stay directly reusable.
  final Map<String, _CachedManifest> _cache = {};

  /// The request identity googlevideo expects for a signed stream URL. Every
  /// videoplayback URL carries the minting client in its `c=` query parameter
  /// (and usually its exact version in `cver=`), so the correct UA is read
  /// straight off the URL — this keeps downloads and playback in step with
  /// client rotation without extra plumbing.
  static String userAgentForUrl(String url) {
    String c = '';
    String ver = '';
    try {
      final q = Uri.parse(url).queryParameters;
      c = (q['c'] ?? '').toUpperCase();
      ver = q['cver'] ?? '';
    } catch (_) {}
    if (c.isNotEmpty) {
      // Exact name + version first: two identities share `c=ANDROID` but need
      // different UAs, and `cver` tells them apart.
      if (ver.isNotEmpty) {
        for (final client in _clients) {
          if (client['name']!.toUpperCase() == c && client['version'] == ver) {
            return client['userAgent']!;
          }
        }
      }
      for (final client in _clients) {
        if (client['name']!.toUpperCase() == c) return client['userAgent']!;
      }
      if (c.contains('ANDROID')) {
        for (final client in _clients) {
          if (client['name'] == 'ANDROID') return client['userAgent']!;
        }
      }
      if (c.contains('IOS')) {
        for (final client in _clients) {
          if (client['name'] == 'IOS') return client['userAgent']!;
        }
      }
      if (c.contains('WEB')) {
        return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36';
      }
      if (c.contains('TV')) {
        return 'Mozilla/5.0 (SmartHub; SMART-TV; U; Linux/SmartTV) AppleWebKit/537.42+ (KHTML, like Gecko) SmartTV Safari/537.42+';
      }
    }
    return _clients.first['userAgent']!;
  }

  /// Fetches the player response for [videoId], trying every known client
  /// until one returns real stream URLs. Returns null when YouTube refuses
  /// all of them (genuinely unavailable / private video).
  ///
  /// YouTube locks Ultra HD behind per-client policy: IOS is the most
  /// generous but still caps some uploads, and only ANDROID/TV carry certain
  /// 2160p itags. When the winning client offers nothing above 1080p the
  /// next two clients are polled as well and their extra streams are merged,
  /// so a genuine 4K upload never shows a 720p-only picker.
  Future<InnerTubeResult?> fetch(String videoId) async {
    if (videoId.isEmpty) return null;

    final cached = _cache[videoId];
    if (cached != null &&
        DateTime.now().isBefore(cached.expiresAt) &&
        cached.result.hasStreams) {
      return cached.result;
    }

    InnerTubeResult? primary;
    String? primaryName;
    for (final client in _order) {
      final result = await _fetchWith(videoId, client);
      if (result != null) {
        primary = result;
        primaryName = client['name'];
        lastWorkingClient = client['name']!;
        break;
      }
    }
    if (primary == null) return null;

    final top = primary.availableHeights().firstOrNull ?? 0;
    if (top < 2160) {
      for (final client in _order.where((c) => c['name'] != primaryName).take(2)) {
        final extra = await _fetchWith(videoId, client);
        if (extra == null) continue;
        _mergeMissing(primary, extra);
        if ((primary.availableHeights().firstOrNull ?? 0) >= 2160) break;
      }
    }

    final ttl = Duration(
        seconds: (primary.expiresInSeconds > 120 ? 60 : 30));
    _cache[videoId] = _CachedManifest(
        primary, DateTime.now().add(ttl));
    return primary;
  }

  Future<InnerTubeResult?> _fetchWith(
      String videoId, Map<String, String> client) async {
    try {
      final data = await _player(videoId, client);
      if (data == null) return null;
      final status = data['playabilityStatus']?['status'];
      final streaming = data['streamingData'];
      if (status != 'OK' || streaming == null) {
        // LOGIN_REQUIRED / age-gates are expected for some clients — rotate
        // silently instead of spamming the log on every fetch.
        return null;
      }
      final result = InnerTubeResult.fromJson(videoId, data);
      if (!result.hasStreams) {
        debugPrint(
            '[InnerTube] ${client['name']} ${client['version']} -> no downloadable stream');
        return null;
      }
      debugPrint(
          '[InnerTube] ${client['name']} ${client['version']} -> ${result.formats.length} streams (video=${result.videoAdaptive.length}, audio=${result.audioAdaptive.length})');
      return result;
    } catch (e) {
      debugPrint('[InnerTube] ${client['name']} failed: $e');
      return null;
    }
  }

  /// Adds every stream of [extra] that [base] does not already carry. The
  /// identity of a stream is itag + resolution + audio track, so a second
  /// client can still contribute dubbed languages that share an itag.
  void _mergeMissing(InnerTubeResult base, InnerTubeResult extra) {
    String key(InnerTubeFormat f) =>
        '${f.itag}|${f.height}|${f.audioTrackId}';
    final seen = <String>{
      for (final f in base.formats) key(f),
      for (final f in base.adaptiveFormats) key(f),
    };
    for (final f in extra.formats) {
      if (seen.add(key(f))) base.formats.add(f);
    }
    for (final f in extra.adaptiveFormats) {
      if (seen.add(key(f))) base.adaptiveFormats.add(f);
    }
  }

  Future<Map<String, dynamic>?> _player(
      String videoId, Map<String, String> client) async {
    final body = jsonEncode({
      'context': {
        'client': {
          'clientName': client['name'],
          'clientVersion': client['version'],
          'hl': 'en',
          'gl': 'US',
          if ((client['androidSdk'] ?? '').isNotEmpty)
            'androidSdkVersion': int.tryParse(client['androidSdk']!),
          // YouTube's quality/DRM policy keys off the exact device identity
          // each client declares — sending a partial context gets SABR probes
          // or a login wall instead of plain stream URLs.
          if ((client['deviceMake'] ?? '').isNotEmpty)
            'deviceMake': client['deviceMake'],
          if ((client['deviceModel'] ?? '').isNotEmpty)
            'deviceModel': client['deviceModel'],
          if ((client['osName'] ?? '').isNotEmpty)
            'osName': client['osName'],
          if ((client['osVersion'] ?? '').isNotEmpty)
            'osVersion': client['osVersion'],
        },
      },
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    });

    for (int attempt = 0; attempt < 2; attempt++) {
      final res = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': client['userAgent']!,
              'X-Youtube-Client-Name': client['nameId']!,
              'X-Youtube-Client-Version': client['version']!,
              'X-Goog-Api-Format-Version': '2',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode == 403 && attempt == 0) {
        // A transient "confirm you are not a bot" answer; retrying once with
        // a plain browser identity usually clears it.
        continue;
      }
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    }
    return null;
  }
}

/// A single entry of `streamingData`, either video-only, audio-only or a
/// progressive stream that already carries both tracks.
class InnerTubeFormat {
  InnerTubeFormat.fromJson(Map<String, dynamic> json)
      : itag = (json['itag'] ?? '').toString(),
        url = (json['url'] ?? '').toString(),
        mimeType = (json['mimeType'] ?? '').toString(),
        qualityLabel = (json['qualityLabel'] ?? '').toString(),
        width = (json['width'] as num?)?.toInt() ?? 0,
        height = (json['height'] as num?)?.toInt() ?? 0,
        fps = (json['fps'] as num?)?.toInt() ?? 0,
        bitrate = (json['bitrate'] as num?)?.toInt() ?? 0,
        contentLength = int.tryParse((json['contentLength'] ?? '').toString()) ?? 0,
        audioIsDefault =
            json['audioTrack']?['audioIsDefault'] as bool? ?? true,
        // Every client spells the track identity differently: WEB sends
        // `trackId` + `audioLocale`, IOS/ANDROID send only `id` ('bn.3'),
        // so accept both names and derive the locale from the id prefix.
        audioTrackId = ((json['audioTrack']?['trackId'] ??
                json['audioTrack']?['id']) ??
            '')
            .toString(),
        audioTrackName = (json['audioTrack']?['displayName'] ??
                json['audioTrack']?['audioDisplayName'] ??
                '')
            .toString(),
        audioLocale = ((json['audioTrack']?['audioLocale'] ??
                (json['audioTrack']?['id'] ?? '')
                    .toString()
                    .split('.')
                    .first) ??
            '')
            .toString();

  final String itag;
  final String url;
  final String mimeType;
  final String qualityLabel;
  final int width;
  final int height;
  final int fps;
  final int bitrate;
  final int contentLength;
  final bool audioIsDefault;

  /// Dubbed-audio identity (only present on audio-only adaptive streams of
  /// multi-language videos, e.g. MrBeast uploads with 20+ dubs). The
  /// [audioTrackId] is what pins a download to ONE specific language.
  final String audioTrackId;
  final String audioTrackName; // 'Bangla', 'German', 'English (Original)'
  final String audioLocale; // 'bn', 'de', 'en-US'

  String get container {
    if (mimeType.contains('mp4') || mimeType.contains('m4a')) return 'mp4';
    if (mimeType.contains('webm')) return 'webm';
    if (mimeType.contains('opus')) return 'webm';
    return 'mp4';
  }

  /// Saved-file extension for an audio track: AAC inside MP4 is stored as m4a.
  String get audioExt {
    if (container == 'mp4') return 'm4a';
    if (mimeType.contains('opus')) return 'opus';
    return 'webm';
  }

  String get codec {
    if (mimeType.contains('avc1')) return 'avc1';
    if (mimeType.contains('vp9') || mimeType.contains('vp09')) return 'vp9';
    if (mimeType.contains('vp8')) return 'vp8';
    if (mimeType.contains('av01')) return 'av01';
    if (mimeType.contains('hev1') || mimeType.contains('hvc1')) return 'hevc';
    if (mimeType.contains('mp4a')) return 'aac';
    if (mimeType.contains('opus')) return 'opus';
    return '';
  }

  bool get isAudio => mimeType.startsWith('audio');

  /// kbps, for a human readable label.
  int get kbps => (bitrate / 1000).round();

  /// Container/codec ranking used when several streams share a resolution.
  /// H.264 in MP4 plays on every device, then VP9 (WebM), then AV1 and HEVC
  /// which only newer hardware decodes.
  int get compatibilityRank {
    switch (codec) {
      case 'avc1':
        return 0;
      case 'vp9':
        return 1;
      case 'vp8':
        return 2;
      case 'aac':
        return 3;
      case 'opus':
        return 4;
      case 'hevc':
        return 5;
      case 'av01':
        return 6;
      default:
        return 7;
    }
  }
}

/// Everything the app needs about one video: metadata plus every stream
/// InnerTube was willing to hand out.
class InnerTubeResult {
  InnerTubeResult.fromJson(String videoId, Map<String, dynamic> json)
      : id = (json['videoDetails']?['videoId'] ?? videoId).toString(),
        title = (json['videoDetails']?['title'] ?? 'YouTube Video').toString(),
        author =
            (json['videoDetails']?['author'] ?? 'YouTube Channel').toString(),
        lengthSeconds = int.tryParse(
                (json['videoDetails']?['lengthSeconds'] ?? '0').toString()) ??
            0,
        thumbnailUrl = ((json['videoDetails']
                        ?['thumbnail']?['thumbnails'] as List?)
                    ?.isNotEmpty ==
                true
            ? ((json['videoDetails']!['thumbnail']!['thumbnails'] as List)
                .last['url']
                .toString())
            : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg'),
        expiresInSeconds =
            int.tryParse((json['streamingData']?['expiresInSeconds'] ?? '0')
                    .toString()) ??
                0,
        formats = ((json['streamingData']?['formats'] as List?) ?? [])
            .map((f) => InnerTubeFormat.fromJson(
                Map<String, dynamic>.from(f as Map)))
            .where((f) => f.url.isNotEmpty)
            .toList(),
        adaptiveFormats =
            ((json['streamingData']?['adaptiveFormats'] as List?) ?? [])
                .map((f) => InnerTubeFormat.fromJson(
                    Map<String, dynamic>.from(f as Map)))
                .where((f) => f.url.isNotEmpty)
                .toList();

  final String id;
  final String title;
  final String author;
  final int lengthSeconds;
  final String thumbnailUrl;
  final int expiresInSeconds;
  final List<InnerTubeFormat> formats; // progressive (video+audio)
  final List<InnerTubeFormat> adaptiveFormats; // single track each

  bool get hasStreams => formats.isNotEmpty || adaptiveFormats.isNotEmpty;

  String get durationFormatted {
    final s = lengthSeconds <= 0 ? 210 : lengthSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  List<InnerTubeFormat> get videoAdaptive =>
      adaptiveFormats.where((f) => !f.isAudio && f.height > 0).toList();

  List<InnerTubeFormat> get audioAdaptive =>
      adaptiveFormats.where((f) => f.isAudio).toList();

  /// Best video-only stream for a resolution, honouring [preferredContainer]
  /// when the caller already committed to a container.
  InnerTubeFormat? bestVideo(int height, {String? preferredContainer}) {
    var candidates = videoAdaptive.where((f) => f.height == height).toList();
    if (candidates.isEmpty) return null;
    if (preferredContainer != null && preferredContainer.isNotEmpty) {
      final inContainer =
          candidates.where((f) => f.container == preferredContainer).toList();
      if (inContainer.isNotEmpty) candidates = inContainer;
    }
    candidates.sort((a, b) {
      final rank = a.compatibilityRank.compareTo(b.compatibilityRank);
      if (rank != 0) return rank;
      final br = b.bitrate.compareTo(a.bitrate);
      if (br != 0) return br;
      return b.fps.compareTo(a.fps);
    });
    return candidates.first;
  }

  /// Every distinct resolution offered, highest first.
  List<int> availableHeights() {
    final heights = videoAdaptive.map((f) => f.height).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    return heights;
  }

  /// Resolution closest to [height] that the source actually offers. Used
  /// when an exact resolution disappeared from the manifest.
  int closestHeight(int height) {
    final heights = availableHeights();
    if (heights.isEmpty) return height;
    int best = heights.first;
    for (final h in heights) {
      if ((h - height).abs() < (best - height).abs()) best = h;
    }
    return best;
  }

  /// The original audio track that can be muxed next to a video of
  /// [container] without re-encoding anything (mp4 <-> m4a, webm <-> opus).
  ///
  /// [trackId] locks the pick to one dubbed language (matches YouTube's
  /// `audioTrack.trackId`, or its locale as a fallback) — the highest-bitrate
  /// stream of THAT language is returned, so a Bangla selection never
  /// silently falls back to the English default track.
  InnerTubeFormat? bestAudio({String? container, String? trackId}) {
    var candidates = audioAdaptive;
    if (trackId != null && trackId.isNotEmpty) {
      final dubbed = candidates
          .where((f) => f.audioTrackId == trackId || f.audioLocale == trackId)
          .toList();
      if (dubbed.isNotEmpty) candidates = dubbed;
    }
    if (container != null && container.isNotEmpty) {
      final matching =
          candidates.where((f) => f.container == container).toList();
      if (matching.isNotEmpty) candidates = matching;
    }
    if (candidates.isEmpty) return null;
    final sorted = candidates.toList()
      ..sort((a, b) {
        final def = (b.audioIsDefault ? 1 : 0).compareTo(a.audioIsDefault ? 1 : 0);
        if (def != 0) return def;
        return b.bitrate.compareTo(a.bitrate);
      });
    return sorted.first;
  }

  /// Every spoken language YouTube publishes for this video, one entry per
  /// audio track, highest bitrate first inside each language. Empty when the
  /// video has a single (original) audio track.
  List<InnerTubeAudioLanguage> audioLanguages() {
    final byId = <String, InnerTubeAudioLanguage>{};
    for (final f in audioAdaptive) {
      final id = f.audioTrackId.isNotEmpty
          ? f.audioTrackId
          : (f.audioLocale.isNotEmpty ? f.audioLocale : 'default');
      final existing = byId[id];
      final name = f.audioTrackName.isNotEmpty
          ? f.audioTrackName
          : (f.audioLocale.isNotEmpty ? f.audioLocale : 'Original');
      if (existing == null) {
        byId[id] = InnerTubeAudioLanguage(
          trackId: id,
          name: name,
          isDefault: f.audioIsDefault,
          bestBitrate: f.bitrate,
        );
      } else if (f.audioIsDefault && !existing.isDefault) {
        byId[id] = InnerTubeAudioLanguage(
          trackId: id,
          name: name,
          isDefault: true,
          bestBitrate: f.bitrate > existing.bestBitrate
              ? f.bitrate
              : existing.bestBitrate,
        );
      } else if (f.bitrate > existing.bestBitrate) {
        byId[id] = InnerTubeAudioLanguage(
          trackId: id,
          name: existing.name,
          isDefault: existing.isDefault,
          bestBitrate: f.bitrate,
        );
      }
    }
    final list = <InnerTubeAudioLanguage>[...byId.values]
      ..sort((a, b) {
        final def = (b.isDefault ? 1 : 0).compareTo(a.isDefault ? 1 : 0);
        if (def != 0) return def;
        return a.name.compareTo(b.name);
      });
    return list.length <= 1 ? const [] : list;
  }

  /// Best progressive stream (already has audio) at or below [maxHeight].
  InnerTubeFormat? bestProgressive({int maxHeight = 360}) {
    final list = formats.where((f) => f.height > 0 && f.height <= maxHeight).toList();
    if (list.isEmpty) return null;
    list.sort((a, b) => b.height.compareTo(a.height));
    return list.first;
  }
}

/// Representation of an audio track/language in a YouTube video.
class InnerTubeAudioLanguage {
  final String trackId;
  final String name;
  final bool isDefault;
  final int bestBitrate;

  const InnerTubeAudioLanguage({
    required this.trackId,
    required this.name,
    required this.isDefault,
    required this.bestBitrate,
  });
}

/// A merged player manifest kept briefly so the picker, resolver and player
/// do not each re-pay the multi-client POST for the same video.
class _CachedManifest {
  final InnerTubeResult result;
  final DateTime expiresAt;

  const _CachedManifest(this.result, this.expiresAt);
}
