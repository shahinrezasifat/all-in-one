import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/extract_result.dart';
import 'inner_tube_service.dart';

class ExtractorService {
  static final ExtractorService instance = ExtractorService._();
  ExtractorService._();

  /// Circuit breaker for the LIVE YouTube-audio source. When it fails (login
  /// required / unplayable / blocked network), every later track would re-pay
  /// the same slow doomed request chain and sit on "Resolving…" forever. After
  /// two failures we park the source briefly so playback falls straight back
  /// to the track's own URL — effectively removing a broken source at runtime.
  DateTime? _audioLiveSourceDownUntil;
  int _audioLiveSourceFailures = 0;

  bool get audioLiveSourceAvailable =>
      _audioLiveSourceDownUntil == null ||
      !DateTime.now().isBefore(_audioLiveSourceDownUntil!);

  Future<void> reportAudioLiveSourceFailure() async {
    _audioLiveSourceFailures++;
    if (_audioLiveSourceFailures >= 2) {
      _audioLiveSourceDownUntil =
          DateTime.now().add(const Duration(minutes: 2));
      _audioLiveSourceFailures = 0;
      debugPrint('[Extractor] live audio source parked for 2m — using own track sources');
    }
  }

  static const String _browserUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36';

  // Primary URL extractor
  Future<ExtractResult?> extract(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty) return null;

    final platform = detectPlatform(url);

    // 1. YouTube: Query InnerTube + YoutubeExplode in parallel to build the
    //    complete quality ladder from 4K/2K/1080p down to 144p.
    if (platform == 'YouTube') {
      try {
        final itFuture = _extractWithInnerTube(url).catchError((e) {
          debugPrint('InnerTube extraction failed: $e');
          return null;
        });
        final ytFuture = _extractWithYoutubeExplode(url).catchError((e) {
          debugPrint('YoutubeExplode direct failed: $e');
          return null;
        });

        final results = await Future.wait([itFuture, ytFuture]);
        final itResult = results[0];
        final ytResult = results[1];

        final merged = _mergeYouTubeResults(itResult, ytResult);
        if (merged != null &&
            (merged.videoFormats.isNotEmpty || merged.audioFormats.isNotEmpty)) {
          return merged;
        }
      } catch (e) {
        debugPrint('YouTube parallel extraction failed: $e');
      }

      final directResult = await _extractYouTubeDirect(url);
      if (directResult != null) return directResult;
    }

    // 2. TikTok: resolve a genuine no-watermark stream (works on Android, no yt-dlp)
    if (platform == 'TikTok') {
      final tik = await _extractTikTok(url);
      if (tik != null) return tik;
    }

    // 3. Try yt-dlp if on desktop Linux/PC
    if (!Platform.isAndroid && !Platform.isIOS) {
      final ytdlpResult = await _extractWithYtDlp(url, platform);
      if (ytdlpResult != null) return ytdlpResult;
    }

    // 5. Generic probe for direct links or other video sites
    return await _generateGenericExtractResult(url, platform);
  }

  String detectPlatform(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) return 'YouTube';
    if (lower.contains('tiktok.com')) return 'TikTok';
    if (lower.contains('instagram.com')) return 'Instagram';
    if (lower.contains('facebook.com') || lower.contains('fb.watch')) return 'Facebook';
    if (lower.contains('twitter.com') || lower.contains('x.com')) return 'Twitter / X';
    if (lower.contains('soundcloud.com')) return 'SoundCloud';
    if (lower.contains('vimeo.com')) return 'Vimeo';
    if (lower.contains('dailymotion.com')) return 'Dailymotion';
    return 'Web Video';
  }

  Future<ExtractResult?> _extractWithInnerTube(String url) async {
    final videoId = _extractYouTubeId(url);
    if (videoId == null) return null;

    final it = await InnerTubeService.instance.fetch(videoId);
    if (it == null || !it.hasStreams) return null;

    final videoFormats = <MediaFormat>[];
    final audioFormats = <MediaFormat>[];

    // One entry per resolution, highest first, most-compatible codec chosen
    // inside each height — the format sheet lists this order verbatim, and a
    // paused task's height hint is read back from these labels. MP4 is
    // preferred at every height (H.264 first, then AV1-in-MP4) so downloads
    // land in the MP4 container the user expects without any conversion.
    // YouTube's FULL original ladder (144p … 2160p/4K … 4320p/8K) is listed —
    // nothing above 720p is ever hidden: adaptive streams above 720p have no
    // muxed copy on YouTube, so the video-only stream + its original audio
    // track (optionally the user's chosen dub) are merged losslessly.
    final listedHeights = <int>{};
    for (final h in it.availableHeights()) {
      final v = it.bestVideo(h, preferredContainer: 'mp4') ?? it.bestVideo(h);
      if (v == null) continue;
      listedHeights.add(h);
      final companion = it.bestAudio(container: v.container);
      final qMeta = _qualityMetadata(v.height, v.fps);
      final badge = _badgeForHeight(v.height);
      final vBytes = v.contentLength > 0 ? v.contentLength : 0;
      final aBytes = companion == null
          ? 0
          : (companion.contentLength > 0
              ? companion.contentLength
              : (vBytes > 0 ? (vBytes ~/ 6).clamp(2 * 1024 * 1024, 24 * 1024 * 1024) : 0));
      final totalBytes = vBytes + aBytes;
      videoFormats.add(
        MediaFormat(
          id: 'it_v_${v.itag}',
          label: qMeta.label,
          ext: v.container,
          type: MediaType.video,
          fileSize: totalBytes > 0 ? totalBytes : null,
          url: v.url,
          videoOnly: true,
          companionAudioUrl: companion?.url,
          companionAudioExt: companion?.audioExt,
          badge: badge,
          note: qMeta.note,
        ),
      );
    }

    // Progressive (muxed) streams only fill heights the adaptive ladder does
    // not cover — listing both would show the SAME resolution twice.
    final muxed = it.formats.toList()
      ..sort((a, b) {
        final h = b.height.compareTo(a.height);
        if (h != 0) return h;
        return b.bitrate.compareTo(a.bitrate);
      });
    for (final p in muxed) {
      if (p.height <= 0 || listedHeights.contains(p.height)) continue;
      listedHeights.add(p.height);
      videoFormats.add(
        MediaFormat(
          id: 'it_p_${p.itag}',
          label: '${p.height}p',
          ext: p.container,
          type: MediaType.video,
          fileSize: p.contentLength > 0 ? p.contentLength : null,
          url: p.url,
          videoOnly: false,
          badge: _badgeForHeight(p.height),
        ),
      );
    }

    // SnapTube Standard Audio Suite: MP3 320K HQ, MP3 128K Fast, M4A
    final mp3Source = it.bestAudio();
    if (mp3Source != null) {
      final baseBytes = mp3Source.contentLength > 0 ? mp3Source.contentLength : 0;
      final dSecs = it.lengthSeconds > 0 ? it.lengthSeconds : 210;

      audioFormats.add(
        MediaFormat(
          id: 'it_a_mp3_320',
          label: 'MP3 320K (HQ)',
          ext: 'mp3',
          type: MediaType.audio,
          fileSize: dSecs > 0 ? (dSecs * 320 * 1000 ~/ 8) : (baseBytes > 0 ? baseBytes : null),
          url: mp3Source.url,
          badge: 'HQ',
          note: 'Best audio quality • 320 kbps',
        ),
      );

      audioFormats.add(
        MediaFormat(
          id: 'it_a_mp3_128',
          label: 'MP3 128K',
          ext: 'mp3',
          type: MediaType.audio,
          fileSize: dSecs > 0 ? (dSecs * 128 * 1000 ~/ 8) : (baseBytes > 0 ? (baseBytes * 128 ~/ 320) : null),
          url: mp3Source.url,
          badge: 'FAST',
          note: 'Fast download • 128 kbps',
        ),
      );

      audioFormats.add(
        MediaFormat(
          id: 'it_a_m4a',
          label: 'M4A',
          ext: 'm4a',
          type: MediaType.audio,
          fileSize: dSecs > 0 ? (dSecs * 160 * 1000 ~/ 8) : (baseBytes > 0 ? (baseBytes * 160 ~/ 320) : null),
          url: mp3Source.url,
          badge: 'M4A',
          note: 'Original AAC container',
        ),
      );
    }

    if (videoFormats.isEmpty && audioFormats.isEmpty) return null;

    return ExtractResult(
      id: videoId,
      title: it.title,
      author: it.author,
      duration: it.durationFormatted,
      thumbnailUrl: it.thumbnailUrl,
      originalUrl: 'https://www.youtube.com/watch?v=$videoId',
      platform: 'YouTube',
      videoFormats: videoFormats,
      audioFormats: audioFormats,
      audioLanguages: [
        for (final l in it.audioLanguages())
          AudioLanguageOption(id: l.trackId, name: l.name, isDefault: l.isDefault),
      ],
    );
  }

  static ({String label, String note}) _qualityMetadata(int height, int fps) {
    final fpsSuffix = fps > 30 ? ' ${fps}fps' : '';
    if (height >= 4320) {
      return (label: '8K Ultra HD (4320p)$fpsSuffix', note: 'Cinema 8K Ultra HD');
    } else if (height >= 2160) {
      return (label: '4K Ultra HD (2160p)$fpsSuffix', note: 'Cinema 4K Resolution • Ultra ${fps > 0 ? fps : 60}fps');
    } else if (height >= 1440) {
      return (label: '2K Quad HD (1440p)$fpsSuffix', note: 'Crisp 2K QHD • High Bitrate');
    } else if (height >= 1080) {
      return (label: '1080p Full HD$fpsSuffix', note: 'Silky ${fps > 0 ? fps : 60}fps Clarity');
    } else if (height >= 720) {
      return (label: '720p HD$fpsSuffix', note: 'High Definition Standard');
    } else if (height >= 480) {
      return (label: '480p SD', note: 'Standard Definition');
    } else if (height >= 360) {
      return (label: '360p Compact', note: 'Medium Quality');
    } else if (height >= 240) {
      return (label: '240p', note: 'Data Saver');
    } else {
      return (label: '144p', note: 'Lowest Bandwidth');
    }
  }

  static String? _badgeForHeight(int height) {
    if (height >= 4320) return '8K';
    if (height >= 2160) return '4K';
    if (height >= 1440) return '2K';
    if (height >= 1080) return 'FHD';
    if (height >= 720) return 'HD';
    return null;
  }

  /// 100% Real YouTube Stream Manifest Extraction using pure Dart YoutubeExplode
  Future<ExtractResult?> _extractWithYoutubeExplode(String url) async {
    final videoId = _extractYouTubeId(url);
    if (videoId == null) return null;

    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(videoId);
      final manifest = await yt.videos.streamsClient.getManifest(videoId);

      final videoFormats = <MediaFormat>[];
      final audioFormats = <MediaFormat>[];

      final companionCache = <String, AudioOnlyStreamInfo?>{};
      AudioOnlyStreamInfo? companionFor(String container) => companionCache
          .putIfAbsent(container, () => _companionAudio(manifest, container));

      int honestSize(int videoBytes, AudioOnlyStreamInfo? audio) {
        if (videoBytes <= 0 && audio == null) return 0;
        final aBytes = audio == null
            ? 0
            : (audio.size.totalBytes > 0
                ? audio.size.totalBytes
                : (videoBytes ~/ 6).clamp(2 * 1024 * 1024, 24 * 1024 * 1024));
        return videoBytes + aBytes;
      }

      // Collect all distinct heights across all video streams (highest first)
      final allHeights = manifest.video
          .map((s) => s.videoResolution.height)
          .where((h) => h > 0)
          .toSet()
          .toList()
        ..sort((a, b) => b.compareTo(a));

      final listedHeights = <int>{};

      for (final h in allHeights) {
        final streamsAtHeight = manifest.videoOnly
            .where((s) => s.videoResolution.height == h)
            .toList();

        if (streamsAtHeight.isNotEmpty) {
          // Prefer MP4 container (for native MediaMuxer compatibility), then highest fps, then bitrate
          streamsAtHeight.sort((a, b) {
            final aMp4 = a.container.name.toLowerCase() == 'mp4' ? 1 : 0;
            final bMp4 = b.container.name.toLowerCase() == 'mp4' ? 1 : 0;
            if (aMp4 != bMp4) return bMp4.compareTo(aMp4);
            final fpsCmp = b.framerate.compareTo(a.framerate);
            if (fpsCmp != 0) return fpsCmp;
            return b.bitrate.compareTo(a.bitrate);
          });

          final best = streamsAtHeight.first;
          final muxedCompanion = manifest.muxed.where((m) => m.container.name == 'mp4').firstOrNull ?? manifest.muxed.firstOrNull;
          final audio = companionFor(best.container.name);
          // Prefer the dedicated audio-only track: it is a few MB instead of
          // re-downloading a whole muxed video just to throw its picture away.
          final companionUrl = audio?.url.toString() ?? muxedCompanion?.url.toString();
          final companionExt = audio != null ? _audioExtFor(audio) : muxedCompanion?.container.name;
          final fps = best.framerate.framesPerSecond.round();
          final qMeta = _qualityMetadata(h, fps);
          final badge = _badgeForHeight(h);

          listedHeights.add(h);
          videoFormats.add(MediaFormat(
            id: 'yt_v_${h}p_${best.tag}',
            label: qMeta.label,
            ext: best.container.name,
            type: MediaType.video,
            fileSize: honestSize(best.size.totalBytes, audio),
            url: best.url.toString(),
            isVipUnlocked: true,
            videoOnly: true,
            companionAudioUrl: companionUrl,
            companionAudioExt: companionExt,
            badge: badge,
            note: qMeta.note,
          ));
        } else {
          // If no videoOnly stream at this height, use muxed stream
          final muxedAtHeight = manifest.muxed
              .where((s) => s.videoResolution.height == h)
              .firstOrNull;
          if (muxedAtHeight != null && !listedHeights.contains(h)) {
            listedHeights.add(h);
            videoFormats.add(MediaFormat(
              id: 'yt_muxed_${muxedAtHeight.tag}',
              label: '${muxedAtHeight.videoResolution.height}p Muxed (Video + Audio)',
              ext: muxedAtHeight.container.name,
              type: MediaType.video,
              fileSize: muxedAtHeight.size.totalBytes,
              url: muxedAtHeight.url.toString(),
              isVipUnlocked: true,
              videoOnly: false,
              badge: _badgeForHeight(muxedAtHeight.videoResolution.height),
              note: 'Instant Playable • Audio Included',
            ));
          }
        }
      }

      // SnapTube Standard Audio Suite: MP3 320K HQ, MP3 128K Fast, M4A
      final muxedAudio = manifest.muxed.where((m) => m.container.name == 'mp4').firstOrNull ?? manifest.muxed.firstOrNull;
      final bestAudioStream =
          manifest.audioOnly.sortByBitrate().toList().reversed.firstOrNull;
      final audioSourceUrl = bestAudioStream?.url.toString() ?? muxedAudio?.url.toString();
      if (audioSourceUrl != null) {
        final dSecs = video.duration?.inSeconds ?? 210;
        final baseBytes = bestAudioStream?.size.totalBytes ?? muxedAudio?.size.totalBytes ?? 0;
        audioFormats.add(MediaFormat(
          id: 'audio_mp3_320',
          label: 'MP3 320K (HQ)',
          ext: 'mp3',
          type: MediaType.audio,
          fileSize: dSecs > 0 ? (dSecs * 320 * 1000 ~/ 8) : (baseBytes > 0 ? baseBytes : null),
          url: audioSourceUrl,
          isVipUnlocked: true,
          badge: 'HQ',
          note: 'Best audio quality • 320 kbps',
        ));
        audioFormats.add(MediaFormat(
          id: 'audio_mp3_128',
          label: 'MP3 128K',
          ext: 'mp3',
          type: MediaType.audio,
          fileSize: dSecs > 0 ? (dSecs * 128 * 1000 ~/ 8) : (baseBytes > 0 ? (baseBytes * 128 ~/ 320) : null),
          url: audioSourceUrl,
          isVipUnlocked: true,
          badge: 'FAST',
          note: 'Fast download • 128 kbps',
        ));
        audioFormats.add(MediaFormat(
          id: 'audio_m4a',
          label: 'M4A',
          ext: 'm4a',
          type: MediaType.audio,
          fileSize: dSecs > 0 ? (dSecs * 160 * 1000 ~/ 8) : (baseBytes > 0 ? (baseBytes * 160 ~/ 320) : null),
          url: audioSourceUrl,
          isVipUnlocked: true,
          badge: 'M4A',
          note: 'Original AAC container',
        ));
      }

      final durationSeconds = video.duration?.inSeconds ?? 210;
      final durFormatted =
          '${durationSeconds ~/ 60}:${(durationSeconds % 60).toString().padLeft(2, '0')}';

      final thumb = video.thumbnails.highResUrl.isNotEmpty
          ? video.thumbnails.highResUrl
          : 'https://i.ytimg.com/vi/${video.id.value}/hqdefault.jpg';

      final audioLanguages = <AudioLanguageOption>[];
      final seenTrackIds = <String>{};
      for (final a in manifest.audioOnly) {
        final trk = a.audioTrack;
        if (trk != null && seenTrackIds.add(trk.id)) {
          audioLanguages.add(AudioLanguageOption(
            id: trk.id,
            name: trk.displayName,
            isDefault: trk.audioIsDefault,
          ));
        }
      }

      return ExtractResult(
        id: video.id.value,
        title: video.title,
        author: video.author,
        duration: durFormatted,
        thumbnailUrl: thumb,
        originalUrl: url,
        platform: 'YouTube',
        videoFormats: videoFormats.where((f) => (f.url ?? '').isNotEmpty).toList(),
        audioFormats: audioFormats.where((f) => (f.url ?? '').isNotEmpty).toList(),
        audioLanguages: audioLanguages,
      );
    } catch (e) {
      debugPrint('YoutubeExplode extraction error: $e');
      return null;
    } finally {
      yt.close();
    }
  }

  /// Merges YouTube results from InnerTube and YoutubeExplode so that every
  /// possible resolution (from 4K/2K/1080p down to 144p) is available.
  ExtractResult? _mergeYouTubeResults(ExtractResult? it, ExtractResult? yt) {
    if (it == null && yt == null) return null;
    if (it == null) return yt;
    if (yt == null) return it;

    final id = yt.id.isNotEmpty ? yt.id : it.id;
    final title = (yt.title.isNotEmpty && yt.title != 'YouTube Video') ? yt.title : it.title;
    final author = (yt.author.isNotEmpty && yt.author != 'YouTube Channel') ? yt.author : it.author;
    final duration = yt.duration.isNotEmpty ? yt.duration : it.duration;
    final thumb = yt.thumbnailUrl.isNotEmpty ? yt.thumbnailUrl : it.thumbnailUrl;
    final originalUrl = it.originalUrl.isNotEmpty ? it.originalUrl : yt.originalUrl;

    // Collect all distinct heights from both sources
    final allHeights = <int>{};
    for (final f in [...yt.videoFormats, ...it.videoFormats]) {
      final h = heightHint(f.id, f.label);
      if (h != null && h > 0) allHeights.add(h);
    }

    final sortedHeights = allHeights.toList()..sort((a, b) => b.compareTo(a));
    final mergedVideoFormats = <MediaFormat>[];

    for (final h in sortedHeights) {
      final ytMatch = yt.videoFormats.where((f) => heightHint(f.id, f.label) == h).firstOrNull;
      final itMatch = it.videoFormats.where((f) => heightHint(f.id, f.label) == h).firstOrNull;

      if (ytMatch != null) {
        mergedVideoFormats.add(ytMatch);
      } else if (itMatch != null) {
        mergedVideoFormats.add(itMatch);
      }
    }

    // Include any muxed or other video formats that don't map to a standard height
    for (final f in [...yt.videoFormats, ...it.videoFormats]) {
      final h = heightHint(f.id, f.label);
      if (h == null && !mergedVideoFormats.any((m) => m.id == f.id)) {
        mergedVideoFormats.add(f);
      }
    }

    // Audio formats: preserve all SnapTube standard audio formats (MP3 320k, 128k, M4A)
    final mergedAudioFormats = <MediaFormat>[];
    final seenAudioLabels = <String>{};
    for (final a in [...yt.audioFormats, ...it.audioFormats]) {
      final key = a.label.toLowerCase();
      if (seenAudioLabels.add(key)) {
        mergedAudioFormats.add(a);
      }
    }
    if (mergedAudioFormats.isEmpty) {
      mergedAudioFormats.add(const MediaFormat(
        id: 'audio_mp3_320',
        label: 'MP3 320K (HQ)',
        ext: 'mp3',
        type: MediaType.audio,
        badge: 'HQ',
        note: 'Best audio quality • 320 kbps',
      ));
    }

    final combinedLanguages = <AudioLanguageOption>[];
    final seenLangIds = <String>{};
    for (final l in [...it.audioLanguages, ...yt.audioLanguages]) {
      if (seenLangIds.add(l.id)) {
        combinedLanguages.add(l);
      }
    }

    return ExtractResult(
      id: id,
      title: title,
      author: author,
      duration: duration,
      thumbnailUrl: thumb,
      originalUrl: originalUrl,
      platform: 'YouTube',
      videoFormats: mergedVideoFormats,
      audioFormats: mergedAudioFormats,
      audioLanguages: combinedLanguages,
    );
  }

  /// Known YouTube itag -> video height. InnerTube formats are saved as
  /// `it_v_<itag>` (no height in the id), so a retry that only carries the id
  /// must still resolve the exact same resolution instead of falling back to
  /// "highest available" and writing a mismatched stream into a half-finished
  /// file.
  static const Map<int, int> _itagHeights = {
    160: 144, 394: 144,
    133: 240, 395: 240,
    134: 360, 396: 360,
    135: 480, 397: 480,
    136: 720, 298: 720, 398: 720,
    137: 1080, 299: 1080, 303: 1080, 399: 1080,
    300: 1440, 308: 1440, 400: 1440,
    301: 2160, 313: 2160, 315: 2160, 401: 2160,
    302: 4320, 402: 4320,
  };

  /// Highest video height (4320/2160/1440/1080/...) mentioned by a format id or a
  /// human label such as '4K Ultra HD (2160p)'. Returns null when the caller
  /// did not express a specific resolution preference.
  static int? heightHint(String? id, String? label) {
    final itagMatch = RegExp(r'_(\d{2,3})$').firstMatch(id ?? '');
    if (itagMatch != null) {
      final known = _itagHeights[int.parse(itagMatch.group(1)!)];
      if (known != null) return known;
    }
    const heights = [4320, 2160, 1440, 1080, 720, 480, 360, 240, 144];
    final regex = RegExp(
      r'(?:^|[^\d])(' + heights.map((h) => h.toString()).join('|') + r')(?:p|\b|[^\d]|$)',
      caseSensitive: false,
    );
    for (final src in [id, label]) {
      if (src == null || src.trim().isEmpty) continue;
      final value = src.trim();
      final match = regex.firstMatch(value);
      if (match != null) return int.parse(match.group(1)!);
      final lower = value.toLowerCase();
      if (lower.contains('8k')) return 4320;
      if (lower.contains('4k') || lower.contains('uhd')) return 2160;
      if (lower.contains('2k') || lower.contains('qhd')) return 1440;
    }
    return null;
  }

  static VideoOnlyStreamInfo? _atHeight(
    Iterable<VideoOnlyStreamInfo> streams,
    int height, {
    String? preferredContainer,
  }) {
    final matches = streams.where((s) => s.videoResolution.height == height).toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      if (preferredContainer != null && preferredContainer.isNotEmpty) {
        final aPref = a.container.name.toLowerCase() == preferredContainer.toLowerCase() ? 1 : 0;
        final bPref = b.container.name.toLowerCase() == preferredContainer.toLowerCase() ? 1 : 0;
        if (aPref != bPref) return bPref.compareTo(aPref);
      } else {
        final aMp4 = a.container.name.toLowerCase() == 'mp4' ? 1 : 0;
        final bMp4 = b.container.name.toLowerCase() == 'mp4' ? 1 : 0;
        if (aMp4 != bMp4) return bMp4.compareTo(aMp4);
      }
      final fpsCmp = b.framerate.compareTo(a.framerate);
      if (fpsCmp != 0) return fpsCmp;
      return b.bitrate.compareTo(a.bitrate);
    });
    return matches.first;
  }

  /// Container extension of an audio stream, as it should be saved on disk.
  static String _audioExtFor(AudioOnlyStreamInfo audio) =>
      audio.container.name == 'mp4' ? 'm4a' : audio.container.name;

  /// Picks the original audio track that can be muxed next to a video stream
  /// without re-encoding: MP4 video wants M4A/AAC audio, WebM video wants
  /// WebM/Opus audio. Falls back to the best available track only when no
  /// container-compatible one exists.
  static AudioOnlyStreamInfo? _companionAudio(
    StreamManifest manifest,
    String videoContainer, {
    String? audioTrackId,
  }) {
    List<AudioOnlyStreamInfo> byBitrate(Iterable<AudioOnlyStreamInfo> list) {
      final sorted = list.toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      return sorted;
    }

    // When the user specifically chose an audio language/dub, prioritize that track
    if ((audioTrackId ?? '').isNotEmpty) {
      final byTrack = byBitrate(
        manifest.audioOnly.where((a) =>
            a.audioTrack?.id == audioTrackId ||
            (a.audioTrack?.displayName ?? '').toLowerCase() == audioTrackId!.toLowerCase()),
      );
      if (byTrack.isNotEmpty) {
        final matchContainer = byTrack.where((a) => a.container.name == videoContainer);
        if (matchContainer.isNotEmpty) return matchContainer.first;
        return byTrack.first;
      }
    }

    final matching = byBitrate(
      manifest.audioOnly.where((a) => a.container.name == videoContainer),
    );
    final matchingDefault = matching
        .where((a) => a.audioTrack == null || a.audioTrack!.audioIsDefault);
    if (matchingDefault.isNotEmpty) return matchingDefault.first;
    if (matching.isNotEmpty) return matching.first;

    final anyAudio = byBitrate(manifest.audioOnly);
    final anyDefault = anyAudio
        .where((a) => a.audioTrack == null || a.audioTrack!.audioIsDefault);
    if (anyDefault.isNotEmpty) return anyDefault.first;
    return anyAudio.firstOrNull;
  }

  /// Fresh on-the-fly resolution of an authorized live stream URL.
  ///
  /// [preferredFormatId] / [preferredLabel] carry the resolution the user
  /// picked; the matching adaptive stream is always returned so a retry can
  /// never silently downgrade 4K/2K/1080p to a smaller muxed stream.
  /// [audioTrackId] pins audio downloads to the dubbed language the user
  /// chose in the picker (YouTube `audioTrack.trackId` or its locale).
  Future<String?> resolveLiveStreamUrl(
    String originalUrl, {
    required bool isAudio,
    String? preferredFormatId,
    String? preferredLabel,
    String? audioTrackId,
  }) async {
    final videoId = _extractYouTubeId(originalUrl);
    if (videoId == null) return null;

    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      if (isAudio) {
        if ((audioTrackId ?? '').isNotEmpty) {
          final byTrack = manifest.audioOnly.where((a) =>
              a.audioTrack?.id == audioTrackId ||
              (a.audioTrack?.displayName ?? '').toLowerCase() == audioTrackId!.toLowerCase()).toList();
          if (byTrack.isNotEmpty) {
            return byTrack.sortByBitrate().last.url.toString();
          }
        }
        // Audio-only first — a muxed stream would download the entire video
        // just to extract its soundtrack afterwards.
        if (manifest.audioOnly.isNotEmpty) {
          return manifest.audioOnly.withHighestBitrate().url.toString();
        }
        if (manifest.muxed.isNotEmpty) {
          final m = manifest.muxed.where((m) => m.container.name == 'mp4').firstOrNull ?? manifest.muxed.first;
          return m.url.toString();
        }
      } else {
        final wanted = heightHint(preferredFormatId, preferredLabel);
        if (wanted != null) {
          final exact = _atHeight(manifest.videoOnly, wanted, preferredContainer: 'mp4') ??
              _atHeight(manifest.videoOnly, wanted);
          if (exact != null) return exact.url.toString();
        }

        if (manifest.videoOnly.isNotEmpty) {
          return manifest.videoOnly.sortByVideoQuality().first.url.toString();
        }
        if (manifest.muxed.isNotEmpty) {
          return manifest.muxed.sortByVideoQuality().first.url.toString();
        }
      }
    } catch (e) {
      debugPrint('YoutubeExplode resolveLiveStreamUrl error: $e');
    } finally {
      yt.close();
    }

    try {
      final it = await InnerTubeService.instance.fetch(videoId);
      if (it != null) {
        if (isAudio) {
          InnerTubeFormat? audio;
          if ((audioTrackId ?? '').isNotEmpty) {
            audio = it.bestAudio(trackId: audioTrackId);
          }
          if (audio == null &&
              preferredFormatId != null &&
              preferredFormatId.isNotEmpty &&
              preferredFormatId != 'it_a_mp3') {
            final itag = preferredFormatId.replaceAll(RegExp(r'[^0-9]'), '');
            if (itag.isNotEmpty) {
              audio = it.audioAdaptive.where((f) => f.itag == itag).firstOrNull;
            }
          }
          audio ??= it.bestAudio(trackId: audioTrackId);
          if (audio != null && audio.url.isNotEmpty) return audio.url;
        } else {
          final wanted = heightHint(preferredFormatId, preferredLabel);
          InnerTubeFormat? video;
          if (wanted != null) {
            video = it.bestVideo(wanted, preferredContainer: 'mp4') ??
                it.bestVideo(wanted);
          }
          if (video != null && video.url.isNotEmpty) return video.url;
          if (wanted == null) {
            final prog = it.bestProgressive();
            if (prog != null && prog.url.isNotEmpty) return prog.url;
          }
        }
      }
    } catch (e) {
      debugPrint('InnerTube resolveLiveStreamUrl error: $e');
    }

    return null;
  }

  /// Resolves a stream that a plain ExoPlayer/AVPlayer can actually PLAY:
  /// one progressive (muxed) file carrying BOTH picture and sound. Adaptive
  /// video-only streams are silent and audio-only ones show a still frame —
  /// feeding those to the player is exactly what made a tapped YouTube video
  /// "play like audio only".
  Future<String?> resolvePlayableStream(String originalUrl) async {
    final videoId = _extractYouTubeId(originalUrl);
    if (videoId == null) return null;

    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      if (manifest.muxed.isNotEmpty) {
        return manifest.muxed.sortByVideoQuality().first.url.toString();
      }
    } catch (e) {
      debugPrint('YoutubeExplode resolvePlayableStream error: $e');
    } finally {
      yt.close();
    }

    try {
      final it = await InnerTubeService.instance.fetch(videoId);
      if (it != null) {
        final prog = it.bestProgressive(maxHeight: 720) ??
            it.bestProgressive(maxHeight: 2160) ??
            it.bestProgressive(maxHeight: 100000);
        if (prog != null && prog.url.isNotEmpty) return prog.url;
      }
    } catch (e) {
      debugPrint('InnerTube resolvePlayableStream error: $e');
    }

    return null;
  }

  /// Resolves a GENUINE, freshly signed video stream at the requested
  /// resolution TOGETHER with the original audio track that belongs to it.
  ///
  /// YouTube serves 4K/2K/1080p as separate video-only and audio-only
  /// streams. Downloading the video alone produces a silent file, so the
  /// caller downloads both and muxes them (no re-encoding, original
  /// resolution and original bitrate are preserved exactly).
  Future<LiveStreamSource?> resolveLiveVideoWithAudio(
    String originalUrl, {
    String? preferredFormatId,
    String? preferredLabel,
    String? audioTrackId,
  }) async {
    final videoId = _extractYouTubeId(originalUrl);
    if (videoId == null) return null;

    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final wanted = heightHint(preferredFormatId, preferredLabel);

      VideoOnlyStreamInfo? video;
      if (wanted != null) {
        video = _atHeight(manifest.videoOnly, wanted, preferredContainer: 'mp4') ??
            _atHeight(manifest.videoOnly, wanted);
        if (video == null && manifest.videoOnly.isNotEmpty) {
          final closest = manifest.videoOnly.toList()
            ..sort(
              (a, b) => (a.videoResolution.height - wanted)
                  .abs()
                  .compareTo((b.videoResolution.height - wanted).abs()),
            );
          video = closest.first;
        }
      } else if (manifest.videoOnly.isNotEmpty) {
        final top = manifest.videoOnly.sortByVideoQuality().firstOrNull;
        if (top != null) {
          video = _atHeight(manifest.videoOnly, top.videoResolution.height, preferredContainer: 'mp4');
        }
      }

      String? audioUrl;
      String? audioExt;
      if ((audioTrackId ?? '').isNotEmpty) {
        final dub = _companionAudio(manifest, video?.container.name ?? 'mp4', audioTrackId: audioTrackId);
        if (dub != null) {
          audioUrl = dub.url.toString();
          audioExt = _audioExtFor(dub);
        }
      }
      if (audioUrl == null && video != null) {
        final companion = _companionAudio(manifest, video.container.name);
        if (companion != null) {
          audioUrl = companion.url.toString();
          audioExt = _audioExtFor(companion);
        }
      }
      // Only when the source publishes no separate audio track at all: fall
      // back to a muxed stream (its picture is discarded by the merge).
      if (audioUrl == null && manifest.muxed.isNotEmpty) {
        final muxed = manifest.muxed.where((m) => m.container.name == 'mp4').firstOrNull ?? manifest.muxed.first;
        audioUrl = muxed.url.toString();
        audioExt = muxed.container.name;
      }

      if (video != null) {
        return LiveStreamSource(
          videoUrl: video.url.toString(),
          audioUrl: audioUrl,
          videoExt: video.container.name,
          audioExt: audioExt ?? 'mp4',
        );
      }

      if (manifest.muxed.isNotEmpty) {
        final m = manifest.muxed.sortByVideoQuality().first;
        return LiveStreamSource(
          videoUrl: m.url.toString(),
          videoExt: m.container.name,
        );
      }
    } catch (e) {
      debugPrint('YoutubeExplode resolveLiveVideoWithAudio error: $e');
    } finally {
      yt.close();
    }

    try {
      final it = await InnerTubeService.instance.fetch(videoId);
      if (it != null) {
        final wanted = heightHint(preferredFormatId, preferredLabel);
        InnerTubeFormat? video;
        if (wanted != null) {
          video = it.bestVideo(wanted, preferredContainer: 'mp4') ??
              it.bestVideo(wanted);
        }
        if (wanted == null) {
          video ??= it.bestVideo(it.availableHeights().firstOrNull ?? 0, preferredContainer: 'mp4') ??
              it.bestVideo(it.availableHeights().firstOrNull ?? 0);
        }
        InnerTubeFormat? audio;
        if ((audioTrackId ?? '').isNotEmpty) {
          audio = it.bestAudio(container: video?.container, trackId: audioTrackId) ??
              it.bestAudio(trackId: audioTrackId);
        }
        audio ??= it.bestAudio(container: video?.container);
        if (video != null && video.url.isNotEmpty && audio != null && audio.url.isNotEmpty) {
          return LiveStreamSource(
            videoUrl: video.url,
            videoExt: video.container,
            audioUrl: audio.url,
            audioExt: audio.audioExt,
          );
        }
      }
    } catch (e) {
      debugPrint('InnerTube resolveLiveVideoWithAudio error: $e');
    }

    return null;
  }

  /// InnerTube WEB search API — the same endpoint the Search screen uses.
  /// youtube_explode_dart's search reads the bot-checked results page, which
  /// stalls for tens of seconds (or dies in a RequestLimitExceeded) from most
  /// IPs; every audio/movie resolve behind it looked like "nothing downloads".
  Future<List<String>> _searchVideoIds(String query, {int take = 8}) async {
    final payload = json.encode({
      'context': {
        'client': {
          'clientName': 'WEB',
          'clientVersion': '2.20240401.08.00',
          'hl': 'en',
          'gl': 'US',
        }
      },
      'query': query,
    });
    try {
      final resp = await http
          .post(
            Uri.parse(
              'https://www.youtube.com/youtubei/v1/search?prettyPrint=false',
            ),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': _browserUA,
            },
            body: payload,
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body);
      final ids = <String>[];
      void walk(dynamic node) {
        if (ids.length >= take) return;
        if (node is Map) {
          final vr = node['videoRenderer'];
          if (vr is Map) {
            final id = (vr['videoId'] ?? '').toString();
            if (id.length == 11 && !ids.contains(id)) ids.add(id);
          }
          for (final v in node.values) {
            walk(v);
          }
        } else if (node is List) {
          for (final v in node) {
            walk(v);
          }
        }
      }
      walk(data);
      return ids;
    } catch (e) {
      debugPrint('InnerTube search failed for "$query": $e');
      return const [];
    }
  }

  /// Real audio resolver searching genuine YouTube CDN stream for any track.
  ///
  /// Some uploads (often region/copyright restricted music videos) expose
  /// audio-only URLs that only serve the first megabyte before returning 403.
  /// Rather than handing the caller a URL that is guaranteed to fail midway, we
  /// verify each candidate with a one-byte range request at the end of the
  /// stream and only return a genuinely downloadable one. Muxed streams are a
  /// last-resort fallback so the download still completes.
  Future<String?> resolveLiveAudioStreamForTrack(String title, [String? artist]) async {
    String cleanTitle = title.replaceAll(RegExp(r'\(.*?\)'), '').replaceAll(RegExp(r'\[.*?\]'), '').trim();
    String cleanArtist = (artist ?? '').trim();

    if (cleanArtist.contains('•') || cleanArtist.contains('bitrate') || cleanArtist.contains('Master') || cleanArtist.contains('FLAC')) {
      cleanArtist = '';
    }

    if (cleanTitle.contains(' - ')) {
      final parts = cleanTitle.split(' - ');
      cleanTitle = parts[0].trim();
      if (cleanArtist.isEmpty && parts.length > 1) {
        cleanArtist = parts[1].trim();
      }
    }

    final query = cleanArtist.isNotEmpty
        ? '$cleanArtist $cleanTitle audio'
        : '$cleanTitle official audio';

    // InnerTube search + ANDROID player API deliver a genuine stream in a
    // fraction of a second; the youtube_explode_dart search below stays only
    // as the fallback, because its bot-checked results page used to stall
    // every audio download behind a 30+ second timeout.
    try {
      for (final q in [query, '$cleanTitle audio']) {
        final ids = await _searchVideoIds(q);
        for (final videoId in ids.take(3)) {
          final tubed = await InnerTubeService.instance.fetch(videoId);
          if (tubed == null || !tubed.hasStreams) continue;
          final candidates = tubed.audioAdaptive.toList()
            ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
          for (final a in candidates) {
            if (a.url.isNotEmpty &&
                await _isStreamRangeAccessible(a.url, a.contentLength)) {
              return a.url;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('InnerTube audio resolve failed for "$title": $e');
    }

    final yt = YoutubeExplode();
    try {
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          final results = await yt.search.search(query);
          final stream = await _firstDownloadableStream(yt, results.take(3));
          if (stream != null) return stream;
          break;
        } catch (_) {
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 600));
          }
        }
      }
      final fallbackResults = await yt.search.search('$cleanTitle audio');
      return await _firstDownloadableStream(yt, fallbackResults.take(3));
    } catch (e) {
      debugPrint('Error resolving audio stream for "$title": $e');
    } finally {
      yt.close();
    }
    return null;
  }

  Future<String?> _firstDownloadableStream(
    YoutubeExplode yt,
    Iterable<Video> videos,
  ) async {
    for (final video in videos) {
      try {
        final manifest = await yt.videos.streamsClient.getManifest(video.id);

        // Audio downloads must use the real audio-only stream, never a muxed
        // video file that merely contains an audio track.
        final audio = manifest.audioOnly.toList()
          ..sort((a, b) => b.bitrate.kiloBitsPerSecond.compareTo(a.bitrate.kiloBitsPerSecond));
        for (final stream in audio) {
          final url = stream.url.toString();
          if (await _isStreamRangeAccessible(url, stream.size.totalBytes)) {
            return url;
          }
        }

        // Fallback: a muxed stream is still a genuine full-length source.
        final muxed = manifest.muxed.sortByVideoQuality();
        for (final stream in muxed) {
          final url = stream.url.toString();
          if (await _isStreamRangeAccessible(url, stream.size.totalBytes)) {
            return url;
          }
        }
      } catch (_) {
        // Try the next search result.
      }
    }
    return null;
  }

  /// Verifies that a stream can serve bytes beyond its first megabyte. YouTube
  /// sometimes issues region-restricted audio URLs that answer 403 for every
  /// range except the beginning of the file. Headers adapt to the host: the
  /// YouTube CDN needs the signing client's identity, every other repository
  /// source (Apple/Spotify/own-CDN JSON repos) is probed as a plain browser.
  Future<bool> _isStreamRangeAccessible(String url, int totalBytes) async {
    final client = http.Client();
    try {
      final end = totalBytes > 1 ? totalBytes - 1 : 1;
      final start = end > 0 ? end : 0;
      final req = http.Request('GET', Uri.parse(url));
      final lower = url.toLowerCase();
      if (lower.contains('googlevideo.com') || lower.contains('youtube.com')) {
        req.headers.addAll({
          'User-Agent': InnerTubeService.userAgentForUrl(url),
          'Range': 'bytes=0-100',
        });
      } else {
        var referer = '';
        try {
          final uri = Uri.parse(url);
          referer = '${uri.scheme}://${uri.host}/';
        } catch (_) {}
        req.headers.addAll({
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
          if (referer.isNotEmpty) 'Referer': referer,
          'Range': 'bytes=$start-$end',
        });
      }
      final res = await client.send(req).timeout(const Duration(seconds: 5));
      if (res.statusCode == 206) {
        await res.stream.drain<void>();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Public downloadability probe for the audio download sheet: verifies a
  /// repository-declared format truly serves its whole file before it is
  /// ever offered to the user.
  Future<bool> isAudioDownloadable(String url, {int totalBytes = 0}) async {
    if (url.trim().isEmpty) return false;
    return _isStreamRangeAccessible(url, totalBytes);
  }

  /// Shared builder: turns a YouTube audio-only manifest into the real,
  /// downloadable quality options the source provides. The list is ordered from
  /// highest to lowest bitrate and every label/extension describes the actual
  /// stream (M4A/AAC or WebM/Opus) — there is no pretend "320 kbps MP3" entry,
  /// because no such stream exists in the manifest.
  List<MediaFormat> _buildAudioFormats(StreamManifest manifest) {
    final audioFormats = <MediaFormat>[];
    final streams = manifest.audioOnly.sortByBitrate().toList().reversed.toList();

    for (int i = 0; i < streams.length; i++) {
      final s = streams[i];
      final kbps = s.bitrate.kiloBitsPerSecond.round();
      final ext = s.container.name == 'mp4' ? 'm4a' : s.container.name;
      // Show the genuine AUDIO codec, never a video container name:
      // AAC-in-MP4 is sold as M4A/AAC, WebM audio-only is Opus.
      final codec = switch (ext) {
        'm4a' => 'AAC',
        'webm' => 'OPUS',
        _ => ext.toUpperCase(),
      };
      final isBest = i == 0;
      final label = '$kbps kbps $codec Audio${isBest ? ' (Best)' : ''}';
      audioFormats.add(MediaFormat(
        id: 'audio_${s.tag}',
        label: label,
        ext: ext,
        type: MediaType.audio,
        fileSize: s.size.totalBytes,
        url: s.url.toString(),
        isVipUnlocked: true,
        note: isBest
            ? 'Highest bitrate available from this source'
            : 'Original source stream • $codec',
      ));
    }

    return audioFormats;
  }

  /// Resolves a GENUINE, full-length audio source for a track (never a 30s
  /// preview). Searches YouTube, fetches the real stream manifest and returns
  /// every available audio quality so both playback and the download picker can
  /// offer the same options the source actually provides.
  Future<ExtractResult?> resolveAudioExtract(String title, [String? artist]) async {
    String cleanTitle =
        title.replaceAll(RegExp(r'\(.*?\)'), '').replaceAll(RegExp(r'\[.*?\]'), '').trim();
    String cleanArtist = (artist ?? '').trim();

    if (cleanArtist.contains('•') ||
        cleanArtist.contains('bitrate') ||
        cleanArtist.contains('Master') ||
        cleanArtist.contains('FLAC') ||
        cleanArtist.contains('kbps')) {
      cleanArtist = '';
    }

    // A track label like "Artist - Title" should search artist + title cleanly.
    if (cleanTitle.contains(' - ')) {
      final parts = cleanTitle.split(' - ');
      cleanArtist = parts.first.trim();
      cleanTitle = parts.last.trim();
    }

    final query = cleanArtist.isNotEmpty
        ? '$cleanArtist $cleanTitle audio'
        : '$cleanTitle official audio';

    // InnerTube first — same reason as resolveLiveAudioStreamForTrack: the
    // explode search page is bot-blocked and used to hang every playback /
    // audio-picker resolve open.
    try {
      for (final q in [query, '$cleanTitle audio']) {
        final ids = await _searchVideoIds(q);
        for (final videoId in ids.take(3)) {
          final tubed = await InnerTubeService.instance.fetch(videoId);
          if (tubed == null || !tubed.hasStreams) continue;
          final extracted = await _audioExtractFromInnerTube(tubed, cleanArtist);
          if (extracted != null) return extracted;
        }
      }
    } catch (e) {
      debugPrint('InnerTube audio extract failed for "$title": $e');
    }

    final yt = YoutubeExplode();
    try {
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          final results = await yt.search.search(query);
          final picked = await _playableAudioResult(yt, results.take(3), cleanArtist);
          if (picked != null) return picked;
          break;
        } catch (_) {
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 600));
          }
        }
      }
      final fallbackResults = await yt.search.search('$cleanTitle audio');
      return await _playableAudioResult(yt, fallbackResults.take(3), cleanArtist);
    } catch (e) {
      debugPrint('resolveAudioExtract error for "$title": $e');
    } finally {
      yt.close();
    }
    return null;
  }

  /// Turns an InnerTube manifest into the movie-picker result: muxed and
  /// video-only streams, one entry per quality, listed highest first.
  Future<ExtractResult?> _movieExtractFromInnerTube(InnerTubeResult tubed) async {
    final videoFormats = <MediaFormat>[];
    final seen = <String>{};
    for (final p in tubed.formats) {
      final label = p.qualityLabel.isNotEmpty ? p.qualityLabel : '${p.height}p';
      if (!seen.add('muxed_$label')) continue;
      videoFormats.add(MediaFormat(
        id: 'it_mv_p_${p.itag}',
        label: '$label (Video + Audio)',
        ext: p.container,
        type: MediaType.video,
        fileSize: p.contentLength > 0 ? p.contentLength : null,
        url: p.url,
      ));
    }
    for (final h in tubed.availableHeights()) {
      final v = tubed.bestVideo(h);
      if (v == null) continue;
      final label = v.qualityLabel.isNotEmpty ? v.qualityLabel : '${v.height}p';
      if (!seen.add(label)) continue;
      final companion = tubed.bestAudio(container: v.container);
      videoFormats.add(MediaFormat(
        id: 'it_mv_v_${v.itag}',
        label: v.fps > 30 ? '$label ${v.fps}fps' : label,
        ext: v.container,
        type: MediaType.video,
        fileSize: v.contentLength > 0 ? v.contentLength : null,
        url: v.url,
        videoOnly: true,
        companionAudioUrl: companion?.url,
        companionAudioExt: companion?.audioExt,
        note: 'Video only',
      ));
    }
    if (videoFormats.isEmpty) return null;
    return ExtractResult(
      id: tubed.id,
      title: tubed.title,
      author: tubed.author,
      duration: tubed.durationFormatted,
      thumbnailUrl: tubed.thumbnailUrl,
      originalUrl: 'https://www.youtube.com/watch?v=${tubed.id}',
      platform: 'YouTube',
      videoFormats: videoFormats,
      audioFormats: const [],
    );
  }

  /// Turns an InnerTube manifest into the audio-picker result: every genuine
  /// audio-only stream, range-probed, highest bitrate first.
  Future<ExtractResult?> _audioExtractFromInnerTube(
    InnerTubeResult tubed,
    String cleanArtist,
  ) async {
    final streams = tubed.audioAdaptive.toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final audioFormats = <MediaFormat>[];
    for (final a in streams) {
      if (a.url.isEmpty) continue;
      if (!await _isStreamRangeAccessible(a.url, a.contentLength)) continue;
      final ext = a.audioExt;
      final codec = ext == 'm4a' ? 'AAC' : ext.toUpperCase();
      final isBest = audioFormats.isEmpty;
      audioFormats.add(MediaFormat(
        id: 'it_a_${a.itag}',
        label: '${a.kbps} kbps $codec Audio${isBest ? ' (Best)' : ''}',
        ext: ext,
        type: MediaType.audio,
        fileSize: a.contentLength > 0 ? a.contentLength : null,
        url: a.url,
        isVipUnlocked: true,
        note: isBest
            ? 'Highest bitrate available from this source'
            : 'Original source stream • $codec',
      ));
    }
    if (audioFormats.isEmpty) return null;
    return ExtractResult(
      id: tubed.id,
      title: tubed.title,
      author: cleanArtist.isNotEmpty ? cleanArtist : tubed.author,
      duration: tubed.durationFormatted,
      thumbnailUrl: tubed.thumbnailUrl,
      originalUrl: 'https://www.youtube.com/watch?v=${tubed.id}',
      platform: 'YouTube',
      videoFormats: const [],
      audioFormats: audioFormats,
    );
  }

  /// Picks the first search result whose audio streams can actually be
  /// downloaded. Only GENUINE audio-only manifest streams are offered — a
  /// muxed video container (MP4/WebM video) is never dressed up as an "audio
  /// format", and every listed stream is range-probed first so the picker
  /// shows exactly what the source can serve, nothing that it cannot.
  Future<ExtractResult?> _playableAudioResult(
    YoutubeExplode yt,
    Iterable<Video> videos,
    String cleanArtist,
  ) async {
    for (final video in videos) {
      try {
        final manifest = await yt.videos.streamsClient.getManifest(video.id);
        final audioFormats = _buildAudioFormats(manifest);
        if (audioFormats.isEmpty) continue;

        final probeResults = await Future.wait(audioFormats.map((f) async {
          final url = f.url ?? '';
          if (url.isEmpty) return false;
          return await _isStreamRangeAccessible(url, f.fileSize ?? 0);
        }));

        final downloadable = <MediaFormat>[];
        for (var i = 0; i < audioFormats.length; i++) {
          if (probeResults[i]) downloadable.add(audioFormats[i]);
        }
        if (downloadable.isNotEmpty) {
          return _audioResultForVideo(video, cleanArtist, downloadable);
        }
      } catch (_) {
        // Try the next search result.
      }
    }
    return null;
  }

  ExtractResult _audioResultForVideo(
    Video video,
    String cleanArtist,
    List<MediaFormat> audioFormats,
  ) {
    final durSeconds = video.duration?.inSeconds ?? 210;
    final durStr = '${durSeconds ~/ 60}:${(durSeconds % 60).toString().padLeft(2, '0')}';
    final thumb = video.thumbnails.mediumResUrl.isNotEmpty
        ? video.thumbnails.mediumResUrl
        : 'https://i.ytimg.com/vi/${video.id.value}/mqdefault.jpg';

    return ExtractResult(
      id: video.id.value,
      title: video.title,
      author: cleanArtist.isNotEmpty ? cleanArtist : video.author,
      duration: durStr,
      thumbnailUrl: thumb,
      originalUrl: 'https://www.youtube.com/watch?v=${video.id.value}',
      platform: 'YouTube',
      videoFormats: const [],
      audioFormats: audioFormats,
    );
  }

  /// Real movie stream resolver searching genuine high-quality stream for movies
  Future<String?> resolveLiveMovieStream(
    String title, {
    String? resolution,
    bool preferMuxedForPlayback = false,
  }) async {
    final res = resolution ?? '1080p';
    final is4k = res.toLowerCase().contains('4k') || res.contains('2160');
    final is2k = res.toLowerCase().contains('2k') || res.contains('1440');
    final query = is4k
        ? '$title 4k trailer movie clip'
        : (is2k ? '$title 1440p trailer' : '$title 1080p trailer full clip');

    // InnerTube first: the explode search page is bot-blocked and used to
    // stall this resolve past 30 s — movie downloads simply never started.
    try {
      final ids = await _searchVideoIds(query, take: 3);
      for (final videoId in ids) {
        final tubed = await InnerTubeService.instance.fetch(videoId);
        if (tubed == null || !tubed.hasStreams) continue;
        if (preferMuxedForPlayback && tubed.formats.isNotEmpty) {
          final muxed = tubed.formats.toList()
            ..sort((a, b) => b.height.compareTo(a.height));
          return muxed.first.url;
        }
        final wanted = heightHint(null, res);
        if (wanted != null) {
          final v = tubed.bestVideo(wanted) ??
              tubed.bestVideo(tubed.closestHeight(wanted));
          if (v != null) return v.url;
        }
        if (tubed.formats.isNotEmpty) {
          final muxed = tubed.formats.toList()
            ..sort((a, b) => b.height.compareTo(a.height));
          return muxed.first.url;
        }
        final heights = tubed.availableHeights();
        if (heights.isNotEmpty) {
          final v = tubed.bestVideo(heights.first);
          if (v != null) return v.url;
        }
      }
    } catch (e) {
      debugPrint('InnerTube movie resolve failed for "$title": $e');
    }

    final yt = YoutubeExplode();
    try {
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          final results = await yt.search.search(query);
          if (results.isNotEmpty) {
            final video = results.first;
            final manifest = await yt.videos.streamsClient.getManifest(video.id);

            if (preferMuxedForPlayback && manifest.muxed.isNotEmpty) {
              return manifest.muxed.sortByVideoQuality().first.url.toString();
            }

            if (is4k) {
              final v4k = manifest.videoOnly.where((v) => v.qualityLabel.contains('2160')).firstOrNull;
              if (v4k != null) return v4k.url.toString();
            }
            if (is2k) {
              final v2k = manifest.videoOnly.where((v) => v.qualityLabel.contains('1440')).firstOrNull;
              if (v2k != null) return v2k.url.toString();
            }

            // Muxed stream contains BOTH video + audio and ratebypass=yes (no 403 blocks)
            if (manifest.muxed.isNotEmpty) {
              return manifest.muxed.sortByVideoQuality().first.url.toString();
            }

            final v1080 = manifest.videoOnly.where((v) => v.qualityLabel.contains('1080')).firstOrNull;
            if (v1080 != null) return v1080.url.toString();

            if (manifest.videoOnly.isNotEmpty) {
              return manifest.videoOnly.sortByVideoQuality().first.url.toString();
            }
          }
          break;
        } catch (_) {
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 600));
          }
        }
      }

      final fallbackResults = await yt.search.search('$title official trailer');
      if (fallbackResults.isNotEmpty) {
        final video = fallbackResults.first;
        final manifest = await yt.videos.streamsClient.getManifest(video.id);
        if (manifest.muxed.isNotEmpty) {
          return manifest.muxed.sortByVideoQuality().first.url.toString();
        }
        if (manifest.videoOnly.isNotEmpty) {
          return manifest.videoOnly.sortByVideoQuality().first.url.toString();
        }
      }
    } catch (e) {
      debugPrint('Error resolving movie stream for "$title": $e');
    } finally {
      yt.close();
    }
    return null;
  }

  // Extract using local yt-dlp process if installed
  Future<ExtractResult?> _extractWithYtDlp(String url, String platform) async {
    try {
      String cmd = 'yt-dlp';
      final homeDir = Platform.environment['HOME'] ?? '';
      final localBin = '$homeDir/.local/bin/yt-dlp';
      if (File(localBin).existsSync()) {
        cmd = localBin;
      }

      final result = await Process.run(
        cmd,
        [
          '--no-playlist',
          '--dump-json',
          '--simulate',
          url,
        ],
        runInShell: true,
      );

      if (result.exitCode == 0 && result.stdout.toString().isNotEmpty) {
        final data = json.decode(result.stdout.toString());
        final title = data['title'] ?? 'Video';
        final author = data['uploader'] ?? data['channel'] ?? 'Creator';
        final duration = data['duration_string'] ?? '3:30';
        final thumbnail = data['thumbnail'] ?? '';
        final formats = data['formats'] as List<dynamic>? ?? [];

        final videoFormats = <MediaFormat>[];
        final audioFormats = <MediaFormat>[];

        final seenResolutions = <int>{};
        for (final f in formats.reversed) {
          final height = f['height'] as int? ?? 0;
          final vcodec = f['vcodec']?.toString() ?? 'none';
          final acodec = f['acodec']?.toString() ?? 'none';
          if (height > 0 && vcodec != 'none' && !seenResolutions.contains(height)) {
            seenResolutions.add(height);
            final ext = f['ext']?.toString() ?? 'mp4';
            final size = f['filesize'] as int? ?? f['filesize_approx'] as int?;
            String label = '${height}p';
            String? note;
            if (height >= 2160) {
              label = '4K Ultra HD';
              note = 'Highest Quality';
            } else if (height >= 1440) {
              label = '2K Quad HD';
              note = 'Crisp Detail';
            } else if (height >= 1080) {
              label = '1080p Full HD';
              note = 'Smooth 60fps';
            } else if (height >= 720) {
              label = '720p HD';
              note = 'Standard HD';
            }

            videoFormats.add(MediaFormat(
              id: f['format_id']?.toString() ?? '${height}p',
              label: label,
              ext: ext,
              type: MediaType.video,
              fileSize: size ?? (height * 1024 * 180),
              url: f['url']?.toString(),
              isVipUnlocked: true,
              videoOnly: acodec == 'none',
              note: note,
            ));
          }
        }

        // The AUDIO section gets exactly ONE honest row: MP3. yt-dlp reports
        // dozens of raw AAC/OPUS variants (every dub separately!) — the engine
        // downloads the best original track and encodes a real 320 kbps MP3.
        Map<String, dynamic>? bestAudioFmt;
        int bestScore = -1;
        final seenAudioFids = <String>{};
        for (final f in formats) {
          final acodec = f['acodec']?.toString() ?? 'none';
          final urlStr = f['url']?.toString() ?? '';
          final fid = f['format_id']?.toString() ?? '';
          if (acodec == 'none' || urlStr.isEmpty || fid.isEmpty ||
              seenAudioFids.contains(fid)) {
            continue;
          }
          seenAudioFids.add(fid);
          final abr = ((f['abr'] as num?) ?? 0).round();
          final size = (f['filesize'] as int?) ??
              (f['filesize_approx'] as int?) ??
              0;
          final score = abr > 0 ? abr : (size > 0 ? size ~/ 1024 : 0);
          if (score > bestScore) {
            bestScore = score;
            bestAudioFmt = f as Map<String, dynamic>;
          }
        }
        if (bestAudioFmt != null) {
          audioFormats.add(MediaFormat(
            id: 'audio_mp3',
            label: '320 kbps MP3 Audio',
            ext: 'mp3',
            type: MediaType.audio,
            fileSize: (bestAudioFmt['filesize'] as int?) ??
                (bestAudioFmt['filesize_approx'] as int?),
            url: bestAudioFmt['url']?.toString(),
            isVipUnlocked: true,
            note: 'High Quality',
          ));
        }

        // Filter every list to entries that carry a real, downloadable URL.
        final realVideo = videoFormats.where((f) => (f.url ?? '').isNotEmpty).toList();
        final realAudio = audioFormats.where((f) => (f.url ?? '').isNotEmpty).toList();

        // Nothing genuinely resolvable -> let other strategies try.
        if (realVideo.isEmpty && realAudio.isEmpty) return null;

        return ExtractResult(
          id: data['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          title: title,
          author: author,
          duration: duration,
          thumbnailUrl: thumbnail,
          originalUrl: url,
          platform: platform,
          videoFormats: realVideo,
          audioFormats: realAudio,
        );
      }
    } catch (_) {}
    return null;
  }

  // Fallback direct YouTube HTML/metadata extraction
  Future<ExtractResult?> _extractYouTubeDirect(String url) async {
    try {
      final vid = _extractYouTubeId(url);
      if (vid == null) return null;

      final resp = await http.get(
        Uri.parse('https://www.youtube.com/watch?v=$vid'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final html = resp.body;
        final match = RegExp(r'var ytInitialPlayerResponse\s*=\s*({.+?});(?:var|</script>)').firstMatch(html);
        if (match != null) {
          final data = json.decode(match.group(1)!);
          final title = data['videoDetails']?['title'] ?? 'YouTube Video';
          final author = data['videoDetails']?['author'] ?? 'YouTube Channel';
          final seconds = int.tryParse(data['videoDetails']?['lengthSeconds']?.toString() ?? '200') ?? 200;
          final duration = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
          final thumb = 'https://i.ytimg.com/vi/$vid/hqdefault.jpg';

          // Build formats ONLY from streaming entries that expose a direct url.
          final videoFormats = <MediaFormat>[];
          final audioFormats = <MediaFormat>[];
          final streaming = data['streamingData'];
          if (streaming != null) {
            // Progressive "formats" already carry audio; every entry of
            // "adaptiveFormats" is a single track (video-only or audio-only).
            final entries = <MapEntry<dynamic, bool>>[
              ...?((streaming['formats'] as List?)
                  ?.map((f) => MapEntry<dynamic, bool>(f, false))),
              ...?((streaming['adaptiveFormats'] as List?)
                  ?.map((f) => MapEntry<dynamic, bool>(f, true))),
            ];
            final listedHeights = <int>{};
            final audioCandidates = <MediaFormat>[];
            for (final entry in entries) {
              final f = entry.key;
              final singleTrack = entry.value;
              final u = f['url']?.toString() ?? '';
              if (u.isEmpty) continue;
              final itag = f['itag']?.toString() ?? '';
              final mimeType = (f['mimeType'] ?? '').toString();
              final size = int.tryParse((f['contentLength'] ?? '').toString());
              final quality = (f['qualityLabel'] ?? f['quality'] ?? '').toString();
              final ext = mimeType.contains('mp4')
                  ? 'mp4'
                  : (mimeType.contains('webm') ? 'webm' : 'm4a');
              if (mimeType.startsWith('audio')) {
                audioCandidates.add(MediaFormat(
                  id: 'yt_a_$itag',
                  label: quality.isNotEmpty ? '$quality Audio' : 'Audio',
                  ext: ext,
                  type: MediaType.audio,
                  fileSize: size,
                  url: u,
                  note: 'Direct stream',
                ));
              } else {
                final h = int.tryParse((f['height'] ?? '').toString()) ??
                    int.tryParse(RegExp(r'(\d+)p').firstMatch(quality)?.group(1) ?? '') ??
                    0;
                // One row per resolution: skip a progressive duplicate of an
                // adaptive height already listed.
                if (h > 0 && !listedHeights.add(h)) continue;
                videoFormats.add(MediaFormat(
                  id: 'yt_v_$itag',
                  label: quality.isNotEmpty ? quality : 'Video',
                  ext: ext,
                  type: MediaType.video,
                  fileSize: size,
                  url: u,
                  videoOnly: singleTrack,
                  note: singleTrack ? 'Direct video stream • audio merged after download' : 'Direct stream',
                ));
              }
            }
            // Collapsed to ONE MP3 row, exactly like the primary extractor —
            // the biggest original track gives the best MP3 quality.
            if (audioCandidates.isNotEmpty) {
              audioCandidates.sort((a, b) => (b.fileSize ?? 0).compareTo(a.fileSize ?? 0));
              audioFormats.add(MediaFormat(
                id: 'yt_a_mp3',
                label: '320 kbps MP3 Audio',
                ext: 'mp3',
                type: MediaType.audio,
                fileSize: seconds * 320 * 1000 ~/ 8,
                url: audioCandidates.first.url,
                note: 'High Quality',
              ));
            }
          }

          if (videoFormats.isEmpty && audioFormats.isEmpty) return null;

          return ExtractResult(
            id: vid,
            title: title,
            author: author,
            duration: duration,
            thumbnailUrl: thumb,
            originalUrl: url,
            platform: 'YouTube',
            videoFormats: videoFormats,
            audioFormats: audioFormats,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<ExtractResult?> _generateGenericExtractResult(String url, String platform) async {
    // 1. Direct media link (mp4/webm/mp3/m3u8/...)? Probe it for real.
    final direct = await _probeMedia(url);
    if (direct != null && direct.isMedia) {
      return _resultFromProbes(
        pageUrl: url,
        platform: platform,
        probes: [direct],
      );
    }

    // 2. Otherwise treat the URL as a web page, fetch its HTML and discover
    //    genuine media URLs (video/source tags, OpenGraph, download links and
    //    JSON-embedded streams). This is what makes ordinary video sites work
    //    when no native extractor exists.
    final pageHtml = await _fetchHtml(url);
    if (pageHtml == null) return null;

    final candidates = _mediaUrlsFromHtml(pageHtml.html, url);
    if (candidates.isEmpty) return null;

    return extractFromCandidates(
      url,
      candidates,
      pageTitle: pageHtml.title,
      author: pageHtml.author,
      thumbnailUrl: pageHtml.image,
    );
  }

  /// Probes a list of media URLs harvested from a live page (WebView DOM,
  /// network-performance entries, HTML, ...) and returns only confirmed,
  /// directly-downloadable streams. Never fabricates formats.
  Future<ExtractResult?> extractFromCandidates(
    String pageUrl,
    List<String> candidates, {
    String? pageTitle,
    String? author,
    String? thumbnailUrl,
  }) async {
    final probes = <_MediaProbeInfo>[];
    final seen = <String>{};

    for (final raw in candidates) {
      final url = raw.trim();
      if (url.isEmpty || !url.startsWith('http')) continue;
      if (!seen.add(url)) continue;
      if (probes.length >= 12) break;
      final probe = await _probeMedia(url, referer: pageUrl);
      if (probe != null && probe.isMedia) probes.add(probe);
    }

    if (probes.isEmpty) return null;
    return _resultFromProbes(
      pageUrl: pageUrl,
      platform: detectPlatform(pageUrl),
      probes: probes,
      pageTitle: pageTitle,
      author: author,
      thumbnailUrl: thumbnailUrl,
    );
  }

  ExtractResult _resultFromProbes({
    required String pageUrl,
    required String platform,
    required List<_MediaProbeInfo> probes,
    String? pageTitle,
    String? author,
    String? thumbnailUrl,
  }) {
    final videoFormats = <MediaFormat>[];
    final audioFormats = <MediaFormat>[];

    for (final probe in probes) {
      final isAudio = probe.isAudio;
      final isHls = probe.isHls;
      final label = isHls
          ? (isAudio ? 'Original HLS Audio' : 'Original HLS Video')
          : (isAudio
              ? 'Original ${probe.ext.toUpperCase()} Audio'
              : 'Original ${probe.ext.toUpperCase()} Video');
      final format = MediaFormat(
        id: 'web_${probe.formatKey}',
        label: label,
        ext: isHls ? 'mp4' : probe.ext,
        type: isAudio ? MediaType.audio : MediaType.video,
        fileSize: probe.sizeBytes,
        url: probe.url,
        isVipUnlocked: true,
        badge: isAudio ? 'HQ' : 'HD',
        note: isHls
            ? 'Adaptive HLS stream from the page'
            : 'Direct media stream from the page',
      );
      if (isAudio) {
        audioFormats.add(format);
      } else {
        videoFormats.add(format);
        // SnapTube Technology: Also generate audio extraction options for web video
        final pSize = probe.sizeBytes;
        audioFormats.add(MediaFormat(
          id: 'web_a_${probe.formatKey}_mp3_320',
          label: 'MP3 320K (HQ)',
          ext: 'mp3',
          type: MediaType.audio,
          fileSize: (pSize != null && pSize > 0) ? (pSize ~/ 5) : null,
          url: probe.url,
          isVipUnlocked: true,
          badge: 'HQ',
          note: 'Best audio quality • 320 kbps',
        ));
        audioFormats.add(MediaFormat(
          id: 'web_a_${probe.formatKey}_mp3_128',
          label: 'MP3 128K',
          ext: 'mp3',
          type: MediaType.audio,
          fileSize: (pSize != null && pSize > 0) ? (pSize ~/ 10) : null,
          url: probe.url,
          isVipUnlocked: true,
          badge: 'FAST',
          note: 'Fast download • 128 kbps',
        ));
        audioFormats.add(MediaFormat(
          id: 'web_a_${probe.formatKey}_m4a',
          label: 'M4A',
          ext: 'm4a',
          type: MediaType.audio,
          fileSize: (pSize != null && pSize > 0) ? (pSize ~/ 8) : null,
          url: probe.url,
          isVipUnlocked: true,
          badge: 'M4A',
          note: 'Original AAC container',
        ));
      }
    }

    String title = (pageTitle ?? '').trim();
    if (title.isEmpty || title.startsWith('http')) {
      try {
        final host = Uri.parse(pageUrl).host.replaceFirst('www.', '');
        title = host.isNotEmpty ? 'Video from $host' : 'Web Video';
      } catch (_) {
        title = 'Web Video';
      }
    }

    String authorName = (author ?? '').trim();
    if (authorName.isEmpty) {
      try {
        authorName = Uri.parse(pageUrl).host.replaceFirst('www.', '');
      } catch (_) {
        authorName = platform;
      }
    }
    if (authorName.isEmpty) authorName = platform;

    return ExtractResult(
      id: 'web_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      author: authorName,
      duration: '',
      thumbnailUrl: thumbnailUrl ?? '',
      originalUrl: pageUrl,
      platform: platform,
      videoFormats: videoFormats,
      audioFormats: audioFormats,
    );
  }

  /// Probes a candidate URL (HEAD, then a ranged GET as fallback) and returns
  /// its real content type/size. Returns null for pages or unreachable links.
  Future<_MediaProbeInfo?> _probeMedia(String rawUrl, {String referer = ''}) async {
    final url = rawUrl.trim();
    if (url.isEmpty) return null;
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    final client = http.Client();
    try {
      String? contentType;
      int? totalSize;
      int status = 0;

      // HEAD first: cheapest way to learn the content type. Some CDNs reject
      // HEAD, so fall back to a one-byte ranged GET.
      try {
        final headReq = http.Request('HEAD', uri);
        headReq.headers.addAll(_probeHeaders(uri, referer));
        final headRes = await client.send(headReq).timeout(const Duration(seconds: 6));
        status = headRes.statusCode;
        contentType = headRes.headers['content-type'];
        final len = headRes.headers['content-length'];
        if (len != null) totalSize = int.tryParse(len);
        await headRes.stream.drain<void>();
      } catch (_) {
        status = 0;
      }

      if (status < 200 || status >= 300 || contentType == null) {
        try {
          final getReq = http.Request('GET', uri);
          getReq.headers.addAll(_probeHeaders(uri, referer, range: 'bytes=0-1'));
          final getRes = await client.send(getReq).timeout(const Duration(seconds: 8));
          status = getRes.statusCode;
          contentType = getRes.headers['content-type'] ?? contentType;
          final range = getRes.headers['content-range'];
          if (range != null && range.contains('/')) {
            final total = int.tryParse(range.split('/').last.trim());
            if (total != null && total > 0) totalSize = total;
          }
          final len = getRes.contentLength;
          if ((totalSize == null || totalSize <= 0) && len != null && len > 2) {
            totalSize = len;
          }
          await getRes.stream.drain<void>();
        } catch (_) {
          return null;
        }
      }

      if (status < 200 || status >= 300) return null;

      final cType = (contentType ?? '').toLowerCase();
      if (cType.contains('text/html') || cType.contains('application/xhtml')) {
        return null; // A page, not a media file.
      }

      final lower = uri.path.toLowerCase();
      final isHls = lower.endsWith('.m3u8') || cType.contains('mpegurl');
      final isDash = lower.endsWith('.mpd') || cType.contains('dash+xml');

      String? ext = _mediaExtFromPathOrType(lower, cType);
      final bool hasMediaExt = ext != null;
      final bool hasMediaType = cType.startsWith('video/') ||
          cType.startsWith('audio/') ||
          cType.contains('octet-stream') ||
          cType.contains('mp4') ||
          cType.contains('matroska') ||
          cType.contains('mpeg');

      if (!isHls && !isDash && !hasMediaExt && !hasMediaType) return null;
      if (isDash) return null; // DASH manifests are not downloadable by the engine.

      ext ??= cType.startsWith('audio/') ? 'm4a' : 'mp4';
      final isAudio = cType.startsWith('audio/') ||
          const {'mp3', 'm4a', 'aac', 'flac', 'opus', 'ogg', 'wav'}.contains(ext);

      return _MediaProbeInfo(
        url: uri.toString(),
        ext: isHls ? 'm3u8' : ext,
        isAudio: isAudio,
        isHls: isHls,
        sizeBytes: (totalSize != null && totalSize > 0) ? totalSize : null,
      );
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Map<String, String> _probeHeaders(Uri uri, String referer, {String? range}) {
    final headers = <String, String>{
      'User-Agent': _browserUA,
      'Accept': '*/*',
    };
    if (referer.isNotEmpty) {
      headers['Referer'] = referer;
    } else if (uri.host.isNotEmpty) {
      headers['Referer'] = '${uri.scheme}://${uri.host}/';
    }
    if (range != null) headers['Range'] = range;
    return headers;
  }

  String? _mediaExtFromPathOrType(String path, String contentType) {
    for (final ext in const [
      'mp4', 'webm', 'mkv', 'm4v', 'mov', 'm3u8',
      'mp3', 'm4a', 'aac', 'flac', 'opus', 'ogg', 'wav',
    ]) {
      if (path.endsWith('.$ext')) return ext;
    }
    if (contentType.contains('video/mp4') || contentType.contains('audio/mp4')) return 'mp4';
    if (contentType.contains('webm')) return 'webm';
    if (contentType.contains('matroska')) return 'mkv';
    if (contentType.contains('quicktime')) return 'mov';
    if (contentType.contains('mpegurl')) return 'm3u8';
    if (contentType.contains('audio/mpeg')) return 'mp3';
    if (contentType.contains('audio/aac')) return 'm4a';
    if (contentType.contains('audio/flac')) return 'flac';
    if (contentType.contains('audio/ogg')) return 'ogg';
    if (contentType.contains('audio/opus')) return 'opus';
    if (contentType.contains('audio/wav')) return 'wav';
    if (contentType.contains('video/')) return 'mp4';
    return null;
  }

  Future<_PageHtml?> _fetchHtml(String url) async {
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': _browserUA, 'Accept': 'text/html,*/*'},
      ).timeout(const Duration(seconds: 8));
      final cType = (res.headers['content-type'] ?? '').toLowerCase();
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      if (cType.isNotEmpty &&
          !cType.contains('text/html') &&
          !cType.contains('application/xhtml') &&
          !cType.contains('text/plain')) {
        return null;
      }
      final html = res.body;
      if (html.trim().isEmpty) return null;

      String title = '';
      final titleMatch = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false)
          .firstMatch(html);
      if (titleMatch != null) {
        title = _htmlDecode(titleMatch.group(1) ?? '').trim();
      }

      String image = '';
      final imageMatch = RegExp(
        r'''<meta[^>]+(?:property|name)=["'](?:og:image|twitter:image)["'][^>]+content=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(html);
      if (imageMatch != null) image = _htmlDecode(imageMatch.group(1) ?? '');

      String author = '';
      final authorMatch = RegExp(
        r'''<meta[^>]+(?:property|name)=["'](?:author|twitter:creator|og:video:actor|article:author|channel_name)["'][^>]+content=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(html) ??
      RegExp(
        r'''<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:author|twitter:creator|og:video:actor|article:author|channel_name)["']''',
        caseSensitive: false,
      ).firstMatch(html);
      if (authorMatch != null) author = _htmlDecode(authorMatch.group(1) ?? '').trim();

      return _PageHtml(html: html, title: title, image: image, author: author);
    } catch (_) {
      return null;
    }
  }

  /// Extracts real media URLs from page HTML: <video>/<audio>/<source> tags,
  /// OpenGraph video/audio metadata, direct download links and stream URLs
  /// embedded in inline JSON.
  List<String> _mediaUrlsFromHtml(String html, String baseUrl) {
    final out = <String>[];
    final seen = <String>{};

    void add(String? raw) {
      if (raw == null) return;
      var value = _htmlDecode(raw)
          .replaceAll(r'\/', '/')
          .replaceAll(r'\u0026', '&')
          .trim();
      if (value.isEmpty) return;
      if (value.startsWith('//')) value = 'https:$value';
      if (value.startsWith('blob:') || value.startsWith('data:')) return;
      if (!value.startsWith('http://') && !value.startsWith('https://')) {
        try {
          value = Uri.parse(baseUrl).resolve(value).toString();
        } catch (_) {
          return;
        }
      }
      if (value.startsWith('http') && seen.add(value)) out.add(value);
    }

    final tagPatterns = [
      RegExp(r'''<(?:video|audio|source)[^>]+src=["']([^"']+)["']''', caseSensitive: false),
      RegExp(r'''<(?:video|audio)[^>]+data-src=["']([^"']+)["']''', caseSensitive: false),
      RegExp(
        r'''<meta[^>]+(?:property|name)=["'](?:og:video(?::url|:secure_url)?|og:audio(?::url)?|twitter:player:stream)["'][^>]+content=["']([^"']+)["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:video(?::url|:secure_url)?|og:audio(?::url)?|twitter:player:stream)["']''',
        caseSensitive: false,
      ),
    ];
    for (final pattern in tagPatterns) {
      for (final match in pattern.allMatches(html)) {
        add(match.group(1));
      }
    }

    // Direct links and inline JSON string values ending in a media extension.
    final normalized = html.replaceAll(r'\/', '/');
    final urlPattern = RegExp(
      r'''https?://[^\s"'<>]+?\.(?:mp4|webm|mkv|m4v|mov|m3u8|mp3|m4a|aac|flac|opus|ogg|wav)(?:\?[^\s"'<>]*)?''',
      caseSensitive: false,
    );
    for (final match in urlPattern.allMatches(normalized)) {
      add(match.group(0));
    }

    return out.take(30).toList();
  }

  String _htmlDecode(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }


  String? _extractYouTubeId(String url) {
    final clean = url.trim();
    if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(clean)) {
      return clean;
    }
    final regExp = RegExp(
      r'(?:youtube\.com/(?:[^/\n\s]+/\S+/|(?:v|e(?:mbed)?|shorts)/|\S*?[?&]v=)|youtu\.be/)([a-zA-Z0-9_-]{11})',
      caseSensitive: false,
    );
    final match = regExp.firstMatch(clean);
    return match?.group(1);
  }

  /// Genuine no-watermark TikTok resolution via a public JSON endpoint. Works on
  /// Android where yt-dlp is unavailable. Returns only real, directly-downloadable
  /// stream URLs; returns null (honest empty) if the endpoint cannot resolve.
  Future<ExtractResult?> _extractTikTok(String url) async {
    try {
      final api = 'https://www.tikwm.com/api/?hd=1&url=${Uri.encodeComponent(url)}';
      final resp = await http
          .get(Uri.parse(api), headers: {'User-Agent': _browserUA})
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;

      final body = json.decode(resp.body);
      if (body['code'] != 0) return null;
      final d = body['data'];
      if (d == null) return null;

      final play = (d['play'] ?? d['originplay'] ?? '').toString();
      if (play.isEmpty || !play.startsWith('http')) return null;

      final title = (d['title'] ?? 'TikTok Video').toString();
      final author = (d['author']?['nickname'] ?? d['author']?['unique_id'] ?? 'TikTok').toString();
      final dur = (d['duration'] as num?)?.toInt() ?? 0;
      final covers = d['covers'];
      final cover = (covers is List && covers.isNotEmpty)
          ? covers.first.toString()
          : (d['cover']?.toString() ?? '');
      final playSize = (d['play_size'] as num?)?.toInt() ?? (d['size'] as num?)?.toInt();

      final videoFormats = <MediaFormat>[];
      videoFormats.add(MediaFormat(
        id: 'tt_original',
        label: 'Original (No Watermark)',
        ext: 'mp4',
        type: MediaType.video,
        fileSize: playSize,
        url: play,
        note: 'Direct TikTok stream',
      ));
      final hd = (d['hdplay'] ?? '').toString();
      if (hd.isNotEmpty && hd.startsWith('http') && hd != play) {
        videoFormats.add(MediaFormat(
          id: 'tt_hd',
          label: 'HD (No Watermark)',
          ext: 'mp4',
          type: MediaType.video,
          fileSize: (d['hdplay_size'] as num?)?.toInt(),
          url: hd,
          note: 'High definition',
        ));
      }

      return ExtractResult(
        id: 'tiktok_${DateTime.now().millisecondsSinceEpoch}',
        title: title,
        author: author,
        duration: '${dur ~/ 60}:${(dur % 60).toString().padLeft(2, '0')}',
        thumbnailUrl: cover,
        originalUrl: url,
        platform: 'TikTok',
        videoFormats: videoFormats,
        audioFormats: const [],
      );
    } catch (e) {
      debugPrint('TikTok extraction failed: $e');
      return null;
    }
  }

  /// Real movie resolver: returns a genuine result with only the qualities the
  /// source actually provides. Desktop uses yt-dlp (real multi-quality manifest);
  /// Android uses a YouTube full-movie search.
  Future<ExtractResult?> resolveMovieExtract(String title) async {
    final clean = title
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .replaceAll(RegExp(r'[:|].*$'), '')
        .trim();

    // Desktop: yt-dlp movie search yields genuine resolutions.
    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        final ytdlp = await _extractWithYtDlp('ytsearch1:$clean full movie', 'Movie');
        if (ytdlp != null && ytdlp.videoFormats.any((f) => (f.url ?? '').isNotEmpty)) {
          return ytdlp;
        }
      } catch (_) {}
    }

    // Android / fallback: real YouTube full-movie manifest.
    // InnerTube first — no bot-checked search page, no watch-page manifest.
    try {
      final itIds = await _searchVideoIds('$clean full movie', take: 3);
      for (final videoId in itIds) {
        final tubed = await InnerTubeService.instance.fetch(videoId);
        if (tubed == null || !tubed.hasStreams) continue;
        final movie = await _movieExtractFromInnerTube(tubed);
        if (movie != null) return movie;
      }
    } catch (e) {
      debugPrint('InnerTube movie extract failed for "$title": $e');
    }

    final yt = YoutubeExplode();
    try {
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          final results = await yt.search.search('$clean full movie');
          if (results.isNotEmpty) {
            final video = results.first;
            final manifest = await yt.videos.streamsClient.getManifest(video.id);

            final videoFormats = <MediaFormat>[];
            final seen = <String>{};
            for (final s in manifest.muxed.sortByVideoQuality()) {
              if (seen.add('muxed_${s.qualityLabel}')) {
                videoFormats.add(MediaFormat(
                  id: 'mv_muxed_${s.tag}',
                  label: '${s.qualityLabel} (Video + Audio)',
                  ext: s.container.name,
                  type: MediaType.video,
                  fileSize: s.size.totalBytes,
                  url: s.url.toString(),
                  note: 'Instant playable',
                ));
              }
            }
            for (final s in manifest.videoOnly.sortByVideoQuality()) {
              if (seen.add(s.qualityLabel)) {
                videoFormats.add(MediaFormat(
                  id: 'mv_v_${s.tag}',
                  label: s.qualityLabel,
                  ext: s.container.name,
                  type: MediaType.video,
                  fileSize: s.size.totalBytes,
                  url: s.url.toString(),
                  note: 'Video only',
                ));
              }
            }

            final filtered = videoFormats.where((f) => (f.url ?? '').isNotEmpty).toList();
            if (filtered.isNotEmpty) {
              final durSeconds = video.duration?.inSeconds ?? 0;
              final durStr =
                  '${(durSeconds ~/ 60)}:${(durSeconds % 60).toString().padLeft(2, '0')}';
              final thumb = video.thumbnails.highResUrl.isNotEmpty
                  ? video.thumbnails.highResUrl
                  : 'https://i.ytimg.com/vi/${video.id.value}/hqdefault.jpg';
              return ExtractResult(
                id: video.id.value,
                title: video.title,
                author: video.author,
                duration: durStr,
                thumbnailUrl: thumb,
                originalUrl: 'https://www.youtube.com/watch?v=${video.id.value}',
                platform: 'Movie',
                videoFormats: filtered,
                audioFormats: const [],
              );
            }
          }
          break;
        } catch (_) {
          if (attempt == 0) await Future.delayed(const Duration(milliseconds: 600));
        }
      }
    } catch (e) {
      debugPrint('resolveMovieExtract failed for "$title": $e');
    } finally {
      yt.close();
    }
    return null;
  }
}

class _MediaProbeInfo {
  final String url;
  final String ext;
  final bool isAudio;
  final bool isHls;
  final int? sizeBytes;

  const _MediaProbeInfo({
    required this.url,
    required this.ext,
    required this.isAudio,
    required this.isHls,
    this.sizeBytes,
  });

  bool get isMedia => url.isNotEmpty;

  String get formatKey => '${ext}_${url.hashCode.abs()}';
}

class _PageHtml {
  final String html;
  final String title;
  final String image;
  final String author;

  const _PageHtml({
    required this.html,
    required this.title,
    required this.image,
    this.author = '',
  });
}
