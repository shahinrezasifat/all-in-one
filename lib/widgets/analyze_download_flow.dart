import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ytdlp_flutter/ytdlp_flutter.dart';

import '../models/extract_result.dart';
import '../services/extractor_service.dart';
import '../services/yt_dlp_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_palette.dart';
import 'format_picker_sheet.dart';

/// Shared "tap Download -> analyze -> pick a quality" flow.
///
/// The user sees a real progress screen while the analysis runs,
/// and an explicit reason (with a retry) if formats cannot be produced.
Future<void> analyzeAndPickFormat(
  BuildContext context, {
  required String url,
  String analyzingText = 'Checking available formats',
}) async {
  url = YtDlpService.youtubeVideoUrl(url) ?? url.trim();
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);

  final progress = ValueNotifier<double>(0.04);
  final stage = ValueNotifier<String>('Checking the link');
  var cancelled = false;
  Timer? ticker;
  var milestone = 0.04;

  void advance(double value, String label) {
    milestone = value > milestone ? value : milestone;
    stage.value = label;
    if (value > progress.value) progress.value = value;
  }

  // Smooth continuous progress ticker so the ring/percentage never freezes
  ticker = Timer.periodic(const Duration(milliseconds: 60), (_) {
    if (progress.value < milestone) {
      progress.value = (progress.value + 0.015).clamp(0.0, milestone);
    } else if (progress.value < 0.90 && milestone < 0.90) {
      progress.value = (progress.value + 0.002).clamp(0.0, 0.90);
    }
  });

  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AnalyzingOverlay(
      text: analyzingText,
      progress: progress,
      stage: stage,
      onCancel: () => cancelled = true,
    ),
  );
  navigator.push(route);

  ExtractResult? result;
  Object? failure;
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  final directMedia = RegExp(
    r'\.(mp4|webm|m4v|m4a|mp3|mov|mkv|m3u8|mpd|aac|ogg)$',
  ).hasMatch(path);

  Future<ExtractResult?> guarded(Future<ExtractResult?> Function() run) async {
    try {
      return await run();
    } catch (error) {
      failure ??= error;
      return null;
    }
  }

  bool usable(ExtractResult? value) =>
      value != null &&
      (value.videoFormats.isNotEmpty || value.audioFormats.isNotEmpty);

  try {
    advance(0.18, 'Reading source link');
    // Both resolution paths run in parallel
    final jobs = <Future<(int, ExtractResult?)>>[];
    if (!directMedia) {
      jobs.add(
        guarded(() => resolveNativeFormats(url)).then((v) => (0, v)),
      );
      jobs.add(
        guarded(() => ExtractorService.instance.extract(url)).then((v) => (1, v)),
      );
    } else {
      jobs.add(
        guarded(() => resolveNativeFormats(url)).then((v) => (0, v)),
      );
    }
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var pending = List<int>.generate(jobs.length, (i) => i);
    while (pending.isNotEmpty && DateTime.now().isBefore(deadline) && !cancelled) {
      final finished = await Future.any(
        pending.map((i) => jobs[i].then((value) => (i, value))),
      );
      final (index, pair) = finished;
      pending.remove(index);
      final (_, value) = pair;
      advance(0.55 + (0.32 * (jobs.length - pending.length) / jobs.length),
          'Fetching stream resolutions');
      if (usable(value)) {
        result = value;
        break;
      }
    }
    advance(0.95, 'Preparing quality options');
  } catch (error) {
    failure ??= error;
  } finally {
    ticker?.cancel();
    advance(1.0, 'Done');
    if (route.isActive) navigator.removeRoute(route);
  }
  if (!navigator.mounted || !messenger.mounted) return;

  if (failure != null && result == null) {
    debugPrint('Format analysis failed for $url: $failure');
    _showRetry(
      messenger,
      'Could not read this video: ${_short(failure.toString())}',
      () {
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
      !['http', 'https'].contains(uri.scheme)) {
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
      backgroundColor: AppPalette.current.card,
      duration: const Duration(seconds: 6),
      content: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: AppPalette.current.error,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppPalette.current.textPrimary, fontSize: 12.5),
            ),
          ),
        ],
      ),
      action: SnackBarAction(
        label: 'RETRY',
        textColor: AppPalette.current.primary,
        onPressed: retry,
      ),
    ),
  );
}

String _short(String message) {
  final clean = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.length <= 90 ? clean : '${clean.substring(0, 87)}...';
}

/// Ultra-modern glassmorphic progress dialog overlay with smooth animations.
class AnalyzingOverlay extends StatelessWidget {
  final String text;
  final ValueListenable<double>? progress;
  final ValueListenable<String>? stage;
  final VoidCallback? onCancel;

  const AnalyzingOverlay({
    super.key,
    this.text = 'Checking available formats',
    this.progress,
    this.stage,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = context.palette.primary;

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xCC161A26)
                    : const Color(0xEEFFFFFF),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.16)
                      : Colors.black.withValues(alpha: 0.10),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
                    blurRadius: 32,
                    spreadRadius: -4,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Animated Progress Ring with Glow Effect
                  ValueListenableBuilder<double>(
                    valueListenable: progress ?? ValueNotifier<double>(0.0),
                    builder: (context, value, _) {
                      final targetPct = value.clamp(0.0, 1.0);

                      return TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0.0, end: targetPct),
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutCubic,
                        builder: (context, animVal, _) {
                          final pctInt = (animVal * 100).round();

                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 80,
                                height: 80,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    // Outer Glowing Aura
                                    Container(
                                      width: 76,
                                      height: 76,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: accent.withValues(alpha: 0.12),
                                        boxShadow: [
                                          BoxShadow(
                                            color: accent.withValues(alpha: 0.25),
                                            blurRadius: 18,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                    ),
                                    // Circular Progress Ring
                                    SizedBox(
                                      width: 72,
                                      height: 72,
                                      child: CircularProgressIndicator(
                                        value: animVal <= 0 ? null : animVal,
                                        strokeWidth: 5.5,
                                        strokeCap: StrokeCap.round,
                                        backgroundColor: isDark
                                            ? Colors.white.withValues(alpha: 0.08)
                                            : Colors.black.withValues(alpha: 0.06),
                                        color: accent,
                                      ),
                                    ),
                                    Text(
                                      '$pctInt%',
                                      style: TextStyle(
                                        color: isDark ? Colors.white : AppColors.primary,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              // Linear Progress Bar
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                  value: animVal <= 0 ? null : animVal,
                                  minHeight: 6,
                                  backgroundColor: isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.black.withValues(alpha: 0.06),
                                  color: accent,
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 20),

                  // Header Title
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Animated Stage Subtitle
                  ValueListenableBuilder<String>(
                    valueListenable: stage ?? ValueNotifier<String>('Starting…'),
                    builder: (context, label, _) => AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(scale: anim, child: child),
                      ),
                      child: Container(
                        key: ValueKey<String>(label),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: accent,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: accent.withValues(alpha: 0.6),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: accent,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Cancel Button
                  if (onCancel != null) ...[
                    const SizedBox(height: 20),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          onCancel!();
                          Navigator.of(context, rootNavigator: true).pop();
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 9),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.12)
                                  : Colors.black.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              color: isDark ? Colors.white70 : Colors.black87,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
