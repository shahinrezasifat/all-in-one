import 'package:flutter/material.dart';
import '../models/extract_result.dart';
import '../theme/app_palette.dart';

/// A compact, modern "quality box" used inside the download bottom sheets.
///
/// Both the video/audio picker sheets lay these out two-per-row in a grid —
/// one row per layer — and only surface what actually matters when picking a
/// download: the quality, the container and roughly how big the file is.
class FormatGridBox extends StatelessWidget {
  final MediaFormat format;
  final bool isSelected;
  final bool isAudio;
  final VoidCallback onTap;

  FormatGridBox({
    super.key,
    required this.format,
    required this.isSelected,
    required this.isAudio,
    required this.onTap,
  });

  Color get _accent => AppPalette.current.primary;

  List<String> get _labelParts =>
      format.label.trim().split(RegExp(r'\s+'));

  /// "49 kbps AAC Audio (Best)" -> headline "49 kbps", sub "AAC Audio (Best)".
  String get _headline {
    final m = RegExp(r'^(\d+)\s*kbps\b', caseSensitive: false)
        .firstMatch(format.label.trim());
    if (m != null) return '${m.group(1)} kbps';
    return _labelParts.isEmpty ? format.label : _labelParts.first;
  }

  String get _subtitle {
    final m = RegExp(r'^\d+\s*kbps\s+(.+)$', caseSensitive: false)
        .firstMatch(format.label.trim());
    if (m != null) return m.group(1)!;
    return _labelParts.length > 1
        ? _labelParts.sublist(1).join(' ')
        : (format.note ?? '');
  }

  String get _size {
    if (format.fileSize == null || format.fileSize == 0) return 'Auto';
    return format.formattedSize;
  }

  bool get _is4k =>
      format.label.contains('2160') || format.label.toUpperCase().contains('4K');

  bool get _is2k =>
      format.label.contains('1440') || format.label.toUpperCase().contains('2K');

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = context.palette.card;
    final dimText =
        context.palette.textSecondary;

    return AnimatedContainer(
      duration: Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: isSelected
            ? _accent.withValues(alpha: isDark ? 0.14 : 0.08)
            : cardColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Quality headline + selection mark
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.1,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                          color: isSelected
                              ? _accent
                              : (context.palette.textPrimary),
                        ),
                      ),
                    ),
                    SizedBox(width: 6),
                    _SelectionDot(isSelected: isSelected, accent: _accent),
                  ],
                ),
                if (_subtitle.isNotEmpty) ...[
                  SizedBox(height: 2),
                  Text(
                    _subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: dimText),
                  ),
                ],
                Spacer(),
                // Container + merge hint + size
                Row(
                  children: [
                    _MiniChip(
                      text: format.ext.toUpperCase(),
                      color: _accent,
                    ),
                    if (_is4k) ...[
                      SizedBox(width: 4),
                      _MiniChip(text: '4K', color: context.palette.info),
                    ] else if (_is2k) ...[
                      SizedBox(width: 4),
                      _MiniChip(text: '2K', color: context.palette.info),
                    ] else if (format.needsAudioMerge) ...[
                      SizedBox(width: 4),
                      _MiniChip(
                        text: '+ AUDIO',
                        color: context.palette.success,
                      ),
                    ],
                    Spacer(),
                    Flexible(
                      child: Text(
                        _size,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: dimText,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionDot extends StatelessWidget {
  final bool isSelected;
  final Color accent;

  _SelectionDot({required this.isSelected, required this.accent});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Duration(milliseconds: 180),
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: isSelected
            ? LinearGradient(colors: [accent, accent.withValues(alpha: 0.75)])
            : null,
        color: isSelected ? null : Colors.transparent,
      ),
      child: isSelected
          ? Icon(Icons.check_rounded, size: 14, color: context.palette.textPrimary)
          : null,
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String text;
  final Color color;

  _MiniChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.4,
          color: color,
        ),
      ),
    );
  }
}
