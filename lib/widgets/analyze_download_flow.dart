import 'package:flutter/material.dart';
import 'package:ytdlp_flutter/ytdlp_flutter.dart';

import '../models/extract_result.dart';
import '../services/extractor_service.dart';
import '../services/yt_dlp_service.dart';
import '../theme/app_colors.dart';
import 'format_picker_sheet.dart';

/// Shared "tap Download -> analyze -> pick a quality" flow.
///
/// The old flow showed a one-second snackbar and then nothing at all when the
/// extractor failed, which looked like a dead app. Here the user always sees a
/// real progress screen while the analysis runs, and an explicit reason (with
/// a retry) when it cannot produce any stream.
Future<void> analyzeAndPickFormat(
  BuildContext context, {
  required String url,
  String analyzingText = 'Checking available formats',
}) async {
  url = YtDlpService.youtubeVideoUrl(url) ?? url.trim();
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);

  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AnalyzingOverlay(text: analyzingText),
  );
  navigator.push(route);

  ExtractResult? result;
  Object? failure;
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  final directMedia = RegExp(
    r'\.(mp4|webm|m4v|m4a|mp3|mov|mkv|m3u8|mpd|aac|ogg)$',
  ).hasMatch(path);
  try {
    if (!directMedia) {
      try {
        result = await resolveNativeFormats(url);
      } catch (error) {
        failure = error;
      }
    }
    if (result == null) {
      try {
        result = await ExtractorService.instance.extract(url);
      } catch (error) {
        failure ??= error;
      }
    }
    if (directMedia &&
        (result == null ||
            (result.videoFormats.isEmpty && result.audioFormats.isEmpty))) {
      result = await resolveNativeFormats(url);
    }
  } catch (error) {
    failure ??= error;
  } finally {
    if (route.isActive) navigator.removeRoute(route);
  }
  if (!navigator.mounted || !messenger.mounted) return;

  if (failure != null && result == null) {
    debugPrint('Format analysis failed for $url: $failure');
    _showRetry(
      messenger,
      'Could not read this video: ${_short(failure.toString())}',
      () {
        // The snackbar can be tapped long after the Navigator state is gone.
        // Always use a live context from the messenger that owns the snackbar.
        if (!navigator.mounted || !messenger.mounted) return;
        analyzeAndPickFormat(
          messenger.context,
          url: url,
          analyzingText: analyzingText,
        );
      },
    );
    return;
  }

  if (result == null ||
      (result.videoFormats.isEmpty && result.audioFormats.isEmpty)) {
    _showRetry(
      messenger,
      'No downloadable quality was returned for this video. It may be '
      'private, age restricted or region blocked.',
      () {
        // The snackbar can be tapped long after the Navigator state is gone.
        // Always use a live context from the messenger that owns the snackbar.
        if (!navigator.mounted || !messenger.mounted) return;
        analyzeAndPickFormat(
          messenger.context,
          url: url,
          analyzingText: analyzingText,
        );
      },
    );
    return;
  }

  if (!navigator.mounted) return;
  FormatPickerSheet.show(navigator.context, result);
}

Future<ExtractResult?> resolveNativeFormats(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.host.isEmpty ||
      !const ['http', 'https'].contains(uri.scheme)) {
    return null;
  }
  final engine = YtDlpService.instance;
  final info = await engine.resolve(url);
  if (info == null || info.id.isEmpty) return null;
  final qualities = engine.qualities(info);
  if (qualities.isEmpty) return null;
  return _resultFromYtDlp(info, qualities, url);
}

ExtractResult _resultFromYtDlp(
  VideoInfo info,
  List<YtDlpQuality> qualities,
  String url,
) {
  final videoFormats = <MediaFormat>[];
  final audioFormats = <MediaFormat>[];

  for (int i = 0; i < qualities.length; i++) {
    final q = qualities[i];
    final isAudio = q.label.toLowerCase().contains('audio');
    final badge = q.is4k
        ? '4K'
        : (q.label.contains('1080')
              ? 'FHD'
              : (q.label.contains('720') ? 'HD' : null));
    final format = MediaFormat(
      id: 'ytdlp_${i}_${q.label}',
      label: q.label,
      ext: isAudio ? 'mp3' : 'mp4',
      type: isAudio ? MediaType.audio : MediaType.video,
      badge: isAudio ? 'HQ' : badge,
      note: q.subtitle,
    );
    if (isAudio) {
      audioFormats.add(format);
    } else {
      videoFormats.add(format);
    }
  }

  return ExtractResult(
    id: info.id.isNotEmpty
        ? info.id
        : 'yt_${DateTime.now().millisecondsSinceEpoch}',
    title: info.title.isNotEmpty ? info.title : 'Video',
    author: info.uploader ?? '',
    duration: _durationLabel(info.durationSeconds),
    thumbnailUrl: info.thumbnailUrl ?? '',
    originalUrl: url,
    platform: ExtractorService.instance.detectPlatform(url),
    videoFormats: videoFormats,
    audioFormats: audioFormats,
  );
}

String _durationLabel(double? seconds) {
  if (seconds == null || !seconds.isFinite || seconds <= 0) return '';
  final time = Duration(seconds: seconds.round());
  final minutes = time.inMinutes.remainder(60).toString();
  final remainder = time.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (time.inHours == 0) return '$minutes:$remainder';
  return '${time.inHours}:${minutes.padLeft(2, '0')}:$remainder';
}

void _showRetry(
  ScaffoldMessengerState messenger,
  String message,
  VoidCallback retry,
) {
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.darkCard,
      duration: const Duration(seconds: 6),
      content: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppColors.accentRed,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12.5),
            ),
          ),
        ],
      ),
      action: SnackBarAction(
        label: 'RETRY',
        textColor: AppColors.primary,
        onPressed: retry,
      ),
    ),
  );
}

String _short(String message) {
  final clean = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.length <= 90 ? clean : '${clean.substring(0, 87)}...';
}

/// Blocking progress card shown while the extractor is working.
class AnalyzingOverlay extends StatelessWidget {
  final String text;

  const AnalyzingOverlay({super.key, this.text = 'Checking available formats'});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
          decoration: BoxDecoration(
            color: AppColors.darkCard,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 38,
                height: 38,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Looking for video and audio tracks at the source.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
