enum MediaType { video, audio }

class MediaFormat {
  final String id;
  final String
  label; // e.g., '1080p FHD', '720p HD', '4K 2160p', '320kbps HQ MP3'
  final String ext; // 'mp4', 'mp3', 'm4a', 'webm'
  final MediaType type;
  final int? fileSize; // in bytes
  final String? url;
  final bool isVipUnlocked; // Always true in SnapTube Pure!
  final String? note; // 'Ultra HD', 'Studio Quality', 'Fast Download'
  final String? badge; // '4K', '2K', 'FHD', 'HD', 'HQ', 'FAST', 'M4A'

  /// Adaptive (DASH) video streams carry a picture track ONLY — there is no
  /// sound in the file until a companion audio stream is muxed into it.
  /// The download engine downloads that original audio track as well and
  /// merges the two, so the saved file keeps this exact resolution AND plays
  /// with sound. Muxed streams already contain audio and leave this `false`.
  final bool videoOnly;

  /// Original audio stream that belongs to this video (same source video,
  /// container-compatible codec) so the merge never re-encodes anything.
  final String? companionAudioUrl;
  final String? companionAudioExt;

  const MediaFormat({
    required this.id,
    required this.label,
    required this.ext,
    required this.type,
    this.fileSize,
    this.url,
    this.isVipUnlocked = true,
    this.note,
    this.badge,
    this.videoOnly = false,
    this.companionAudioUrl,
    this.companionAudioExt,
  });

  /// Dynamic estimated size calculation based on duration in seconds
  /// (SnapTube standard algorithm: ~1MB/min for 128k, ~2.4MB/min for 320k,
  /// ~4MB/min for 360p, ~7MB/min for 480p, ~15MB/min for 720p, ~32MB/min for 1080p, ~85MB/min for 4K).
  static int estimateSizeBytes({
    required int durationSeconds,
    required MediaType type,
    String? resolutionOrBitrate,
  }) {
    final int minutes = (durationSeconds / 60).clamp(1, 240).toInt();
    final str = (resolutionOrBitrate ?? '').toUpperCase();
    if (type == MediaType.audio) {
      if (str.contains('320')) return minutes * 2400 * 1024;
      if (str.contains('128')) return minutes * 1024 * 1024;
      return (minutes * 1200 * 1024).toInt(); // M4A / AAC
    } else {
      if (str.contains('4K') || str.contains('2160'))
        return minutes * 85 * 1024 * 1024;
      if (str.contains('2K') || str.contains('1440'))
        return minutes * 50 * 1024 * 1024;
      if (str.contains('1080')) return minutes * 32 * 1024 * 1024;
      if (str.contains('720')) return minutes * 15 * 1024 * 1024;
      if (str.contains('480')) return minutes * 7 * 1024 * 1024;
      return minutes * 4 * 1024 * 1024; // 360p / other
    }
  }

  /// True when downloading this format must be followed by an audio merge
  /// to produce a complete, audible file at this resolution.
  ///
  /// Deliberately NOT gated on [url]: an adaptive stream whose link has not
  /// been minted yet must still resolve a video+audio pair, otherwise the user
  /// would end up with a silent file at the resolution they picked.
  bool get needsAudioMerge => type == MediaType.video && videoOnly;

  String get formattedSize {
    if (fileSize == null || fileSize == 0) return 'Variable size';
    final mb = fileSize! / (1024 * 1024);
    if (mb > 1000) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// A freshly signed pair of live stream URLs: the video at the requested
/// resolution plus the container-compatible audio track that belongs to it.
class LiveStreamSource {
  final String videoUrl;
  final String? audioUrl; // null => the video stream already carries audio
  final String videoExt;
  final String? audioExt;

  const LiveStreamSource({
    required this.videoUrl,
    this.audioUrl,
    required this.videoExt,
    this.audioExt,
  });

  bool get needsMux => (audioUrl ?? '').isNotEmpty;
}

/// One dubbed/original spoken language YouTube offers for a video.
/// Selecting it makes EVERY audio that ends up in the downloaded file —
/// the muxed companion of a video or a pure MP3 — come from this track.
class AudioLanguageOption {
  final String id; // YouTube audioTrack.trackId (or locale fallback)
  final String name; // 'Bangla', 'English (Original)', …
  final bool isDefault; // the language the video was published in

  const AudioLanguageOption({
    required this.id,
    required this.name,
    this.isDefault = false,
  });
}

class ExtractResult {
  final String id;
  final String title;
  final String author;
  final String duration;
  final String thumbnailUrl;
  final String originalUrl;
  final String platform;
  final String channelUrl;
  final List<MediaFormat> videoFormats;
  final List<MediaFormat> audioFormats;

  /// Dubbed audio languages detected at extract time — empty for the usual
  /// single-audio video, 10-20+ entries for dubbed channels like MrBeast.
  final List<AudioLanguageOption> audioLanguages;

  const ExtractResult({
    required this.id,
    required this.title,
    required this.author,
    required this.duration,
    required this.thumbnailUrl,
    required this.originalUrl,
    required this.platform,
    this.channelUrl = '',
    required this.videoFormats,
    required this.audioFormats,
    this.audioLanguages = const [],
  });

  /// Duration converted to total seconds for size estimation and calculations
  int get durationSeconds {
    if (duration.isEmpty) return 210;
    try {
      final parts = duration
          .split(':')
          .map((p) => int.tryParse(p.trim()) ?? 0)
          .toList();
      if (parts.length == 3) {
        return parts[0] * 3600 + parts[1] * 60 + parts[2];
      } else if (parts.length == 2) {
        return parts[0] * 60 + parts[1];
      } else if (parts.length == 1) {
        return parts[0];
      }
    } catch (_) {}
    return 210;
  }
}
