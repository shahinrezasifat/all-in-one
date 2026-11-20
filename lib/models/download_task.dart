enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

class DownloadSegment {
  final int segmentIndex; // 0, 1, 2, 3
  final int startByte;
  final int endByte;
  int downloadedBytes;
  double speedBytesPerSec;
  bool isCompleted;

  DownloadSegment({
    required this.segmentIndex,
    required this.startByte,
    required this.endByte,
    this.downloadedBytes = 0,
    this.speedBytesPerSec = 0,
    this.isCompleted = false,
  });

  double get progress {
    final total = endByte - startByte + 1;
    if (total <= 0) return isCompleted ? 1.0 : 0.0;
    return (downloadedBytes / total).clamp(0.0, 1.0);
  }

  String get progressPercentage {
    return '${(progress * 100).toInt()}%';
  }
}

class DownloadTask {
  final String id;
  final String title;
  final String author;
  final String thumbnailUrl;
  final String formatLabel;
  String ext;
  final bool isAudio;
  final String category; // 'video', 'audio', 'movie'
  final String originalUrl;
  String? streamUrl;
  final bool isHls;

  /// Format id the user actually picked. Kept on the task so that a retry
  /// after a dropped connection re-resolves THE SAME resolution instead of
  /// silently falling back to a lower-quality stream.
  String? preferredFormatId;

  /// Adaptive (video-only) source: the companion audio track must be
  /// downloaded and muxed in before the file is complete.
  bool needsAudioMerge;

  /// Live companion-audio URL for [needsAudioMerge] tasks. Signed URLs expire
  /// quickly, so an expired link is refreshed on every attempt — but it is
  /// still persisted: losing it forced restored tasks through a full
  /// re-extract, which can never answer for sources whose originalUrl is not
  /// a re-analysable page (plain browser downloads), killing their retry.
  String? audioStreamUrl;
  String? audioExt;

  /// The dubbed audio language the user chose in the format picker (YouTube
  /// `audioTrack.trackId`, locale fallback). Every re-resolve of this task —
  /// link refresh, retry, resume — keeps THIS language, so a Bangla pick
  /// never reverts to the English original after a reconnect.
  String? audioTrackId;
  String? audioTrackName;

  /// Provider-supplied request headers (Referer / Cookie / token) carried
  /// from the MovieSource that started this task. Movie servers reject
  /// byte-range requests without them — dropping these is why movie
  /// downloads could silently fail. Persisted so retries keep working.
  Map<String, String> headers;

  /// Short human-readable state shown while the engine is reconnecting,
  /// waiting for the source or merging tracks (transient, never persisted).
  String? statusNote;

  /// Post-download processing stage ('Merging…', 'Converting to MP4…',
  /// 'Converting to MP3…'). While set, the DOWNLOAD slider is finished and a
  /// second CONVERT slider driven by [convertProgress] takes over — the task
  /// only becomes 'completed' once this stage ends (transient).
  String? convertStage;

  /// 0..1 progress of the current [convertStage].
  double convertProgress;

  bool get isConverting => convertStage != null;

  bool get isPreparing =>
      status == DownloadStatus.downloading &&
      !isConverting &&
      downloadedBytes <= 0 &&
      (nativeProgress ?? 0) <= 0;

  /// True when this task is an image (e.g. thumbnail, cover art, poster).
  bool get isImageTask =>
      category == 'image' ||
      const {
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'bmp',
      }.contains(ext.toLowerCase());

  /// True when this task is an audio file (MP3, M4A, etc.).
  bool get isAudioTask =>
      !isImageTask &&
      (isAudio ||
          category == 'audio' ||
          const {
            'mp3',
            'm4a',
            'aac',
            'flac',
            'opus',
            'wav',
            'ogg',
          }.contains(ext.toLowerCase()));

  /// True when this task is a video or movie.
  bool get isVideoTask => !isImageTask && !isAudioTask;

  /// Informational note kept next to a COMPLETED download (e.g. the audio
  /// track could not be muxed on this device and was saved separately).
  String? completionNote;

  // Progress states
  DownloadStatus status;
  int downloadedBytes;
  int totalBytes;
  double speedBytesPerSec;
  double? nativeProgress;
  String? savePath;
  String? errorMessage;
  DateTime createdAt;
  DateTime? completedAt;

  // IDM Parallel Multi-Chunk Segment Downloader State
  int threadsCount;
  List<DownloadSegment> segments;

  DownloadTask({
    required this.id,
    required this.title,
    required this.author,
    required this.thumbnailUrl,
    required this.formatLabel,
    required this.ext,
    required this.isAudio,
    String? category,
    required this.originalUrl,
    this.streamUrl,
    this.preferredFormatId,
    this.isHls = false,
    this.needsAudioMerge = false,
    this.audioStreamUrl,
    this.audioExt,
    this.audioTrackId,
    this.audioTrackName,
    Map<String, String>? headers,
    this.statusNote,
    this.convertStage,
    this.convertProgress = 0.0,
    this.completionNote,
    this.status = DownloadStatus.queued,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0,
    this.savePath,
    this.errorMessage,
    DateTime? createdAt,
    this.completedAt,
    this.threadsCount = 1,
    List<DownloadSegment>? segments,
  }) : category = category ?? (isAudio ? 'audio' : 'video'),
       headers = headers ?? const {},
       createdAt = createdAt ?? DateTime.now(),
       segments = segments ?? [];

  double get progress {
    // While the convert stage runs the byte download itself is finished —
    // its slider must honestly sit at 100%.
    if (isConverting || status == DownloadStatus.completed) return 1.0;
    if (nativeProgress != null) return nativeProgress!;
    if (totalBytes <= 0) return status == DownloadStatus.completed ? 1.0 : 0.0;
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
  }

  String get speedFormatted {
    if (status != DownloadStatus.downloading) return '';
    final kb = speedBytesPerSec / 1024;
    if (kb >= 1024) {
      return '${(kb / 1024).toStringAsFixed(1)} MB/s';
    }
    return '${kb.toStringAsFixed(0)} KB/s';
  }

  String get progressSizeFormatted {
    final curMb = downloadedBytes / (1024 * 1024);
    if (totalBytes > 0) {
      final totMb = totalBytes / (1024 * 1024);
      return '${curMb.toStringAsFixed(1)} / ${totMb.toStringAsFixed(1)} MB';
    }
    return '${curMb.toStringAsFixed(1)} MB';
  }

  String get etaFormatted {
    if (status != DownloadStatus.downloading ||
        speedBytesPerSec <= 0 ||
        totalBytes <= 0) {
      return '';
    }
    final remainingBytes = totalBytes - downloadedBytes;
    if (remainingBytes <= 0) return 'Finishing...';

    final remainingSecs = (remainingBytes / speedBytesPerSec).round();
    if (remainingSecs < 60) {
      return '${remainingSecs}s';
    }
    final mins = remainingSecs ~/ 60;
    final secs = remainingSecs % 60;
    return '${mins}m ${secs}s';
  }

  void initSegments() {
    if (totalBytes <= 0 || threadsCount <= 0) return;
    final chunkSize = (totalBytes / threadsCount).floor();
    segments = List.generate(threadsCount, (i) {
      final start = i * chunkSize;
      final end = (i == threadsCount - 1)
          ? totalBytes - 1
          : (start + chunkSize - 1);
      return DownloadSegment(segmentIndex: i, startByte: start, endByte: end);
    });
  }

  // ALL 4 SEGMENTS DOWNLOAD SIMULTANEOUSLY AT THE EXACT SAME TIME
  void updateSegmentsFromProgressSimultaneous() {
    if (segments.isEmpty) initSegments();
    if (segments.isEmpty || totalBytes <= 0) return;

    final overallProgress = progress;
    final totalSegs = segments.length;

    for (int i = 0; i < totalSegs; i++) {
      final seg = segments[i];
      final segLength = seg.endByte - seg.startByte + 1;

      // All 4 segments advance simultaneously in parallel!
      seg.downloadedBytes = (segLength * overallProgress).toInt();
      seg.isCompleted = overallProgress >= 1.0;
      seg.speedBytesPerSec =
          (speedBytesPerSec / totalSegs) * (seg.isCompleted ? 0.0 : 1.0);
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'thumbnailUrl': thumbnailUrl,
    'formatLabel': formatLabel,
    'ext': ext,
    'isAudio': isAudio,
    'category': category,
    'originalUrl': originalUrl,
    'streamUrl': streamUrl,
    'audioStreamUrl': audioStreamUrl,
    'audioExt': audioExt,
    'audioTrackId': audioTrackId,
    'audioTrackName': audioTrackName,
    'headers': headers,
    'preferredFormatId': preferredFormatId,
    'isHls': isHls,
    'needsAudioMerge': needsAudioMerge,
    'completionNote': completionNote,
    'savePath': savePath,
    'status': status.name,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'threadsCount': threadsCount,
    'createdAt': createdAt.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final task = DownloadTask(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      author: json['author'] ?? '',
      thumbnailUrl: json['thumbnailUrl'] ?? '',
      formatLabel: json['formatLabel'] ?? '',
      ext: json['ext'] ?? 'mp4',
      isAudio: json['isAudio'] ?? false,
      category: json['category'],
      originalUrl: json['originalUrl'] ?? '',
      streamUrl: json['streamUrl'],
      audioStreamUrl: json['audioStreamUrl'],
      audioExt: json['audioExt'],
      audioTrackId: json['audioTrackId'],
      audioTrackName: json['audioTrackName'],
      headers:
          (json['headers'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
      preferredFormatId: json['preferredFormatId'],
      isHls: json['isHls'] as bool? ?? false,
      needsAudioMerge: json['needsAudioMerge'] ?? false,
      completionNote: json['completionNote'],
      savePath: json['savePath'],
      status: DownloadStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => DownloadStatus.completed,
      ),
      downloadedBytes: json['downloadedBytes'] ?? 0,
      totalBytes: json['totalBytes'] ?? 0,
      threadsCount: json['threadsCount'] ?? 1,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt']) ?? DateTime.now()
          : DateTime.now(),
      completedAt: json['completedAt'] != null
          ? DateTime.tryParse(json['completedAt'])
          : null,
    );
    task.initSegments();
    return task;
  }
}
