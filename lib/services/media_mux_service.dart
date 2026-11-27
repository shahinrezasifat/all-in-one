import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MuxResult {
  final bool success;
  final String error;

  const MuxResult({required this.success, this.error = ''});
}

/// Progress reports the native MediaMuxer pass sends back while copying
/// samples — keyed by an opaque token so parallel conversions stay separate.
typedef ConvertProgress = void Function(double progress);

/// Merges a video track and an audio track into ONE playable file.
///
/// High resolutions (4K / 2K / 1080p) are only published as separate
/// "video-only" and "audio-only" streams. Downloading just the video would
/// produce a silent file, so the download engine fetches both original tracks
/// and hands them to this service.
///
/// Both tracks are copied bit-for-bit (stream copy) — nothing is re-encoded,
/// so the original resolution, frame rate and audio bitrate survive exactly.
///
///  * Android  -> the platform's own MediaExtractor/MediaMuxer via a method
///    channel. No bundled binary, negligible APK size.
///  * Desktop  -> an installed `ffmpeg` binary, if there is one.
class MediaMuxService {
  static final MediaMuxService instance = MediaMuxService._();
  MediaMuxService._();

  static const MethodChannel _channel = MethodChannel(
    'snaptube_pure/media_mux',
  );
  static const MethodChannel _ffmpegChannel = MethodChannel(
    'snaptube_pure/ffmpeg_exec',
  );

  /// Native passes report progress against an opaque token so parallel
  /// conversions never overwrite each other's slider.
  final Map<String, ConvertProgress> _nativeProgressHooks = {};
  final Map<String, ConvertProgress> _ffmpegProgressHooks = {};
  bool _handlerInstalled = false;
  bool _ffmpegHandlerInstalled = false;

  void _installNativeProgressHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'muxProgress') {
        final token = (call.arguments as Map?)?['token']?.toString() ?? '';
        final p =
            ((call.arguments as Map?)?['progress'] as num?)?.toDouble() ?? 0;
        _nativeProgressHooks[token]?.call(p.clamp(0.0, 1.0));
      }
    });
  }

  void _installFfmpegProgressHandler() {
    if (_ffmpegHandlerInstalled) return;
    _ffmpegHandlerInstalled = true;
    _ffmpegChannel.setMethodCallHandler((call) async {
      if (call.method == 'ffmpegProgress') {
        final token = (call.arguments as Map?)?['token']?.toString() ?? '';
        final p =
            ((call.arguments as Map?)?['progress'] as num?)?.toDouble() ?? 0;
        _ffmpegProgressHooks[token]?.call(p.clamp(0.0, 1.0));
      }
    });
  }

  /// MediaMetadataRetriever on Android; null elsewhere (callers then run
  /// conversions with a time-based fallback estimate).
  Future<int?> durationMsOf(String path) async {
    if (!Platform.isAndroid) return null;
    try {
      final ms = await _channel.invokeMethod<int>('durationMs', {'path': path});
      return (ms != null && ms > 0) ? ms : null;
    } catch (_) {
      return null;
    }
  }

  Future<MuxResult> merge({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    ConvertProgress? onProgress,
  }) async {
    if (!File(videoPath).existsSync()) {
      return const MuxResult(success: false, error: 'Video part is missing');
    }
    if (!File(audioPath).existsSync()) {
      return const MuxResult(success: false, error: 'Audio part is missing');
    }

    try {
      _deleteIfExists(outputPath);

      if (Platform.isAndroid) {
        _installNativeProgressHandler();
        if (onProgress != null) {
          _nativeProgressHooks[outputPath] = onProgress;
        }
        try {
          final dynamic res = await _channel.invokeMethod('merge', {
            'videoPath': videoPath,
            'audioPath': audioPath,
            'outputPath': outputPath,
            'token': outputPath,
          });
          final ok = res == true || (res is Map && res['ok'] == true);
          if (ok && _isNonEmptyFile(outputPath)) {
            onProgress?.call(1.0);
            return const MuxResult(success: true);
          }
        } on MissingPluginException {
          // No native handler registered - fall through to the FFmpeg CLI.
        } catch (e) {
          debugPrint(
            'Native MediaMuxer failed: $e. Falling back to FFmpeg CLI...',
          );
        } finally {
          _nativeProgressHooks.remove(outputPath);
        }
      }

      if (Platform.isAndroid) {
        final durationMs = await durationMsOf(videoPath);
        final lower = outputPath.toLowerCase();
        final isMp4 =
            lower.endsWith('.mp4') ||
            lower.endsWith('.m4v') ||
            lower.endsWith('.mov');
        final args = <String>[
          '-y',
          '-v',
          'error',
          '-i',
          videoPath,
          '-i',
          audioPath,
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-c',
          'copy',
          if (isMp4) ...['-strict', '-2', '-movflags', '+faststart'],
          outputPath,
        ];
        final ok = await _runBundledFfmpeg(
          args,
          durationMsHint: durationMs,
          onProgress: onProgress,
        );
        if (ok && _isNonEmptyFile(outputPath)) {
          onProgress?.call(1.0);
          return const MuxResult(success: true);
        }
        _deleteIfExists(outputPath);
      }

      return await _mergeWithFfmpeg(
        videoPath,
        audioPath,
        outputPath,
        onProgress: onProgress,
      );
    } catch (e) {
      debugPrint('Merge failed for $outputPath: $e');
      return MuxResult(success: false, error: e.toString());
    }
  }

  static bool _isNonEmptyFile(String path) {
    try {
      final f = File(path);
      return f.existsSync() && f.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  static void _deleteIfExists(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  String? _resolvedFfmpeg;

  Future<String?> _ffmpegBinary() async {
    final cached = _resolvedFfmpeg;
    if (cached != null) return cached;

    final home = Platform.environment['HOME'] ?? '';
    final candidates = <String>[
      'ffmpeg',
      if (home.isNotEmpty) '$home/.local/bin/ffmpeg',
      '/usr/bin/ffmpeg',
      '/usr/local/bin/ffmpeg',
    ];

    for (final candidate in candidates) {
      if (candidate.startsWith('/') && !File(candidate).existsSync()) continue;
      try {
        final probe = await Process.run(candidate, const [
          '-version',
        ], runInShell: Platform.isWindows);
        if (probe.exitCode == 0) {
          _resolvedFfmpeg = candidate;
          return candidate;
        }
      } catch (_) {}
    }
    return null;
  }

  /// Converts any downloaded video into a real MP4 file.
  ///
  /// First remuxes without quality loss. If the source codecs cannot be
  /// stored in MP4, transcodes to broadly supported MPEG-4 video/AAC audio.
  /// Returns null only when FFmpeg is unavailable or both MP4 paths fail.
  Future<String?> convertToMp4(
    String inputPath, {
    ConvertProgress? onProgress,
  }) async {
    final input = File(inputPath);
    if (!input.existsSync()) return null;

    final dot = inputPath.lastIndexOf('.');
    final base = dot > 0 ? inputPath.substring(0, dot) : inputPath;
    final outPath = '$base.mp4';
    if (outPath.toLowerCase() == inputPath.toLowerCase()) return outPath;

    final durationMs = await durationMsOf(inputPath);
    final remuxArgs = <String>[
      '-y',
      '-v',
      'error',
      '-i',
      inputPath,
      '-c',
      'copy',
      '-strict',
      '-2',
      '-movflags',
      '+faststart',
      outPath,
    ];

    final binary = Platform.isAndroid ? null : await _ffmpegBinary();
    if (!Platform.isAndroid && binary == null) return null;

    Future<bool> run(List<String> args) async {
      if (Platform.isAndroid) {
        return _runBundledFfmpeg(
          args,
          durationMsHint: durationMs,
          onProgress: onProgress,
        );
      }
      return _runFfmpegProcess(binary!, args, onProgress: onProgress);
    }

    if (await run(remuxArgs) && _isNonEmptyFile(outPath)) {
      onProgress?.call(1.0);
      return outPath;
    }
    _deleteIfExists(outPath);

    // Some valid source codecs (for example VP9/AV1 variants) have no MP4
    // mux path in a platform's FFmpeg build. Encode those into a compatible
    // MP4 container so normal downloads consistently retain an .mp4 result.
    final encodeArgs = <String>[
      '-y',
      '-v',
      'error',
      '-i',
      inputPath,
      '-map',
      '0:v:0?',
      '-map',
      '0:a:0?',
      '-c:v',
      'mpeg4',
      '-q:v',
      '3',
      '-c:a',
      'aac',
      '-b:a',
      '192k',
      '-movflags',
      '+faststart',
      '-f',
      'mp4',
      outPath,
    ];
    if (await run(encodeArgs) && _isNonEmptyFile(outPath)) {
      onProgress?.call(1.0);
      return outPath;
    }
    _deleteIfExists(outPath);
    return null;
  }

  Future<String?> convertToMp3(
    String inputPath, {
    String? outPath,
    int kbitRate = 320,
    ConvertProgress? onProgress,
  }) async {
    final input = File(inputPath);
    if (!input.existsSync()) return null;

    final dot = inputPath.lastIndexOf('.');
    final base = dot > 0 ? inputPath.substring(0, dot) : inputPath;
    var out = outPath ?? '$base.mp3';
    if (out.toLowerCase() == inputPath.toLowerCase())
      out = '$inputPath.tmp.mp3';

    final args = <String>[
      '-y',
      '-v',
      'error',
      '-i',
      inputPath,
      '-vn',
      '-c:a',
      'libmp3lame',
      '-b:a',
      '${kbitRate}k',
      '-f',
      'mp3',
      out,
    ];
    final durationMs = await durationMsOf(inputPath);

    if (Platform.isAndroid) {
      final ok = await _runBundledFfmpeg(
        args,
        durationMsHint: durationMs,
        onProgress: onProgress,
      );
      if (ok && _isNonEmptyFile(out)) {
        onProgress?.call(1.0);
        return out;
      }
      _deleteIfExists(out);
      return null;
    }

    final binary = await _ffmpegBinary();
    if (binary == null) return null;
    final ok = await _runFfmpegProcess(binary, args, onProgress: onProgress);
    if (ok && _isNonEmptyFile(out)) {
      onProgress?.call(1.0);
      return out;
    }
    _deleteIfExists(out);
    return null;
  }

  /// Runs youtubedl-android's bundled FFmpeg executable through the native
  /// channel. Its `-progress pipe:1` output carries processed media time,
  /// which the caller's duration hint turns into a real 0..1 slider value.
  /// Uses a unique token so parallel conversions cannot share progress.
  Future<bool> _runBundledFfmpeg(
    List<String> args, {
    required int? durationMsHint,
    ConvertProgress? onProgress,
  }) async {
    _installFfmpegProgressHandler();
    final token = 'ffmpeg_${DateTime.now().microsecondsSinceEpoch}_'
        '${args.hashCode}';
    if (onProgress != null) _ffmpegProgressHooks[token] = onProgress;
    final runArgs = <String>[
      '-hide_banner',
      '-loglevel',
      'info',
      '-nostdin',
      '-progress',
      'pipe:1',
      ...args.where((a) => a != '-v' && a != 'error'),
    ];
    try {
      final ok =
          await _ffmpegChannel.invokeMethod<bool>('run', {
            'args': runArgs,
            'token': token,
            'durationMs': durationMsHint ?? 0,
          }) ??
          false;
      if (!ok) debugPrint('Bundled FFmpeg exited non-zero: ${args.join(' ')}');
      return ok;
    } on MissingPluginException catch (e) {
      debugPrint('FFmpeg channel unavailable: $e');
      return false;
    } on PlatformException catch (e) {
      debugPrint('FFmpeg failed: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('FFmpeg crashed: $e');
      return false;
    } finally {
      _ffmpegProgressHooks.remove(token);
    }
  }

  /// Desktop ffmpeg with `-progress pipe:1`: out_time_ms lines drive the
  /// slider; duration is read off the banner when none was supplied.
  Future<bool> _runFfmpegProcess(
    String binary,
    List<String> args, {
    ConvertProgress? onProgress,
  }) async {
    // The callers pass '-v error' for quiet logs; the progress pipeline needs
    // the banner (for Duration:) and the machine-readable progress stream.
    final runArgs = <String>[
      '-hide_banner',
      '-loglevel',
      'info',
      '-progress',
      'pipe:1',
      ...args.where((a) => a != 'error' && a != '-v'),
    ];
    final durMs = RegExp(r'Duration: (\d+):(\d+):(\d+)\.(\d+)');
    try {
      final proc = await Process.start(
        binary,
        runArgs,
        runInShell: Platform.isWindows,
      );
      int total = 0;
      final done = Completer<bool>();
      proc.stdout.listen((b) {
        final text = utf8.decode(b, allowMalformed: true);
        for (final line in text.split('\n')) {
          if (line.startsWith('out_time_ms=') ||
              line.startsWith('out_time_us=')) {
            final us = int.tryParse(line.split('=').last.trim()) ?? 0;
            if (total > 0) {
              onProgress?.call((us / 1000 / total).clamp(0.0, 0.995));
            }
          }
        }
      });
      final stderrBuf = StringBuffer();
      proc.stderr.listen((b) {
        final text = utf8.decode(b, allowMalformed: true);
        stderrBuf.write(text);
        final m = durMs.firstMatch(text);
        if (m != null && total == 0) {
          total =
              (int.parse(m.group(1)!) * 3600 +
                      int.parse(m.group(2)!) * 60 +
                      int.parse(m.group(3)!)) *
                  1000 +
              int.parse(m.group(4)!) * 10;
        }
      });
      proc.exitCode.then((code) {
        if (code != 0) debugPrint('ffmpeg failed: $stderrBuf');
        if (!done.isCompleted) done.complete(code == 0);
      });
      return await done.future;
    } catch (e) {
      debugPrint('ffmpeg process crashed: $e');
      return false;
    }
  }

  Future<MuxResult> _mergeWithFfmpeg(
    String videoPath,
    String audioPath,
    String outputPath, {
    ConvertProgress? onProgress,
  }) async {
    final binary = await _ffmpegBinary();
    if (binary == null) {
      return const MuxResult(
        success: false,
        error: 'No media merger available on this device',
      );
    }

    final lower = outputPath.toLowerCase();
    final isMp4 =
        lower.endsWith('.mp4') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.mov');

    final args = <String>[
      '-y',
      '-v',
      'error',
      '-i',
      videoPath,
      '-i',
      audioPath,
      '-map',
      '0:v:0',
      '-map',
      '1:a:0',
      '-c',
      'copy',
      if (isMp4) ...['-movflags', '+faststart'],
      outputPath,
    ];

    final ok = await _runFfmpegProcess(binary, args, onProgress: onProgress);
    if (ok && _isNonEmptyFile(outputPath)) {
      onProgress?.call(1.0);
      return const MuxResult(success: true);
    }
    return MuxResult(
      success: false,
      error: 'ffmpeg mux exited non-zero (output missing or empty)',
    );
  }
}
