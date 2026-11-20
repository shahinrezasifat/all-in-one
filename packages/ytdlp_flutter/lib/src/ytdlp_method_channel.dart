import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'models.dart';
import 'ytdlp_platform.dart';

/// Method-channel backend, used on Android where the Kotlin side wraps
/// youtubedl-android (bundled Python + FFmpeg + runtime-updatable yt-dlp).
class MethodChannelYtdlp extends YtdlpPlatform {
  static const _channel = MethodChannel('ytdlp_flutter');
  static const _progressChannel = EventChannel('ytdlp_flutter/progress');

  final Map<String, void Function(YtdlpProgress)> _progressListeners = {};
  StreamSubscription<dynamic>? _progressSub;

  void _ensureProgressStream() {
    _progressSub ??=
        _progressChannel.receiveBroadcastStream().listen((dynamic event) {
      if (event is! Map) return;
      final taskId = event['taskId'] as String?;
      final listener = taskId == null ? null : _progressListeners[taskId];
      if (listener == null) return;
      final received = (event['downloadedBytes'] as num?)?.toInt();
      final total = (event['totalBytes'] as num?)?.toInt();
      listener(YtdlpProgress(
        fraction: received != null && total != null && total > 0 ? received / total : null,
        downloadedBytes: received,
        totalBytes: total,
        etaSeconds: (event['etaSeconds'] as num?)?.toInt(),
        speedBytesPerSecond: (event['speedBytesPerSecond'] as num?)?.toDouble(),
      ));
    });
  }

  @override
  Future<void> init() async {
    await _channel.invokeMethod<void>('init');
  }

  @override
  Future<VideoInfo> getVideoInfo(String url) async {
    final jsonString =
        await _channel.invokeMethod<String>('getVideoInfo', {'url': url});
    if (jsonString == null || jsonString.isEmpty) {
      throw const YtdlpException('getVideoInfo returned no data');
    }
    return VideoInfo.fromInfoDict(
        jsonDecode(jsonString) as Map<String, dynamic>,
        keepRaw: true);
  }

  @override
  Future<String> downloadAudio(
    String url,
    String outputDir, {
    required String taskId,
    String format = 'bestaudio/best',
    String? audioFormat,
    Map<String, String> headers = const {},
    void Function(YtdlpProgress progress)? onProgress,
  }) async {
    if (onProgress != null) {
      _ensureProgressStream();
      _progressListeners[taskId] = onProgress;
    }
    try {
      final path = await _channel.invokeMethod<String>('downloadAudio', {
        'url': url,
        'outputDir': outputDir,
        'taskId': taskId,
        'format': format,
        if (headers.isNotEmpty) 'headers': headers,
        if (audioFormat != null) 'audioFormat': audioFormat,
      });
      if (path == null || path.isEmpty) {
        throw const YtdlpException('Download finished but no file path');
      }
      return path;
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') throw YtdlpCancelledException(taskId);
      throw YtdlpException(e.message ?? e.code, details: e.details?.toString());
    } finally {
      _progressListeners.remove(taskId);
    }
  }

  @override
  Future<bool> cancel(String taskId) async {
    return await _channel.invokeMethod<bool>('cancel', {'taskId': taskId}) ??
        false;
  }

  @override
  Future<String> update() async {
    return await _channel.invokeMethod<String>('update') ?? 'unknown';
  }
}
