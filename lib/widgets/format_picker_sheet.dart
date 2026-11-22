import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/extract_result.dart';
import '../services/download_manager.dart';
import '../services/permission_service.dart';
import '../services/virtual_folder_service.dart';
import '../theme/app_colors.dart';
import 'remote_image.dart';

/// iOS-inspired download format picker.
///
/// Everything the user needs at a glance: what each entry actually contains
/// (video + audio vs pure audio), its real container (MP4 / M4A / OPUS / MP3),
/// its bitrate or codec — and the size, big and bold on the right. The save
/// folder lives in a clean tappable row that opens a Cupertino-style picker,
/// and the thumbnail can be saved with a single tap.
class FormatPickerSheet extends StatefulWidget {
  final ExtractResult result;

  const FormatPickerSheet({super.key, required this.result});

  static Future<void> show(BuildContext context, ExtractResult result) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => FormatPickerSheet(result: result),
    );
  }

  @override
  State<FormatPickerSheet> createState() => _FormatPickerSheetState();
}

class _FormatPickerSheetState extends State<FormatPickerSheet> {
  static const Color _iosBlue = AppColors.primary;

  /// Every format the user ticked — several resolutions can be downloaded in
  /// ONE go (4K AND 1080p AND MP3), each becomes its own queue task.
  final List<MediaFormat> _selectedFormats = [];
  bool _downloadStarting = false;
  String _targetFolderName = 'Default';
  bool _thumbnailSaving = false;
  bool _thumbnailDone = false;

  /// Dubbed audio language picked by the user (null = the video's own
  /// original narration). Applies both to a muxed video download and to MP3.
  AudioLanguageOption? _selectedLanguage;

  @override
  void initState() {
    super.initState();
    if (widget.result.videoFormats.isNotEmpty) {
      _selectedFormats.add(widget.result.videoFormats.firstWhere(
        (f) => f.label.contains('2160') || f.label.contains('4K'),
        orElse: () => widget.result.videoFormats.firstWhere(
          (f) => f.label.contains('1440') || f.label.contains('2K'),
          orElse: () => widget.result.videoFormats.firstWhere(
            (f) => f.label.contains('1080'),
            orElse: () => widget.result.videoFormats.first,
          ),
        ),
      ));
    } else if (widget.result.audioFormats.isNotEmpty) {
      _selectedFormats.add(widget.result.audioFormats.first);
    }
  }

  void _toggleFormat(MediaFormat f) {
    setState(() {
      if (_selectedFormats.any((s) => s.id == f.id)) {
        _selectedFormats.removeWhere((s) => s.id == f.id);
      } else {
        _selectedFormats.add(f);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Label intelligence — turn raw extractor labels into clean, honest parts so
  // the sheet never shows a garbled or half-truncated format name.
  // ---------------------------------------------------------------------------

  static final RegExp _audioLabelRe = RegExp(
    r'^(\d+)\s*kbps\s*([A-Za-z0-9]+)\s*Audio(?:\s*\(Best\))?',
  );

  ({String headline, String sub}) _audioParts(MediaFormat f) {
    final m = _audioLabelRe.firstMatch(f.label.trim());
    if (m != null) {
      final codec = m.group(2)!.toUpperCase();
      final best = f.label.contains('(Best)') || f.note == 'High Quality';
      return (
        headline: '${m.group(1)} kbps',
        sub: '$codec audio${best ? ' • Best quality' : ''}',
      );
    }
    // Any other source's audio label: keep it whole, never chop a name in half.
    return (headline: f.label, sub: '${f.ext.toUpperCase()} audio file');
  }

  ({String headline, String sub}) _videoParts(MediaFormat f) {
    final isMuxed = !f.needsAudioMerge;
    final details = <String>[
      if (f.ext.toUpperCase() != 'MP4') f.ext.toUpperCase(),
      if (isMuxed) 'Video + audio',
    ];
    return (
      headline: f.label,
      sub: details.isEmpty
          ? (f.note ?? 'High quality video')
          : details.join(' • '),
    );
  }

  String _sizeText(MediaFormat f) {
    int bytes = f.fileSize ?? 0;
    if (bytes <= 0) {
      bytes = MediaFormat.estimateSizeBytes(
        durationSeconds: widget.result.durationSeconds,
        type: f.type,
        resolutionOrBitrate: f.label,
      );
    }
    final mb = bytes / (1024 * 1024);
    if (mb > 1000) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  String _totalSizeText() {
    int bytes = 0;
    for (final f in _selectedFormats) {
      int b = f.fileSize ?? 0;
      if (b <= 0) {
        b = MediaFormat.estimateSizeBytes(
          durationSeconds: widget.result.durationSeconds,
          type: f.type,
          resolutionOrBitrate: f.label,
        );
      }
      bytes += b;
    }
    if (bytes <= 0) return '';
    final mb = bytes / (1024 * 1024);
    if (mb > 1000) return ' • ${(mb / 1024).toStringAsFixed(1)} GB';
    return ' • ${mb.toStringAsFixed(0)} MB';
  }

  Future<void> _onDownloadPressed() async {
    if (_selectedFormats.isEmpty || _downloadStarting) return;
    setState(() => _downloadStarting = true);

    // Ensure storage permissions are requested
    final hasPerm = await PermissionService.instance.hasStoragePermission();
    if (!hasPerm) {
      await PermissionService.instance.requestStoragePermission();
    }

    // ONE tap queues EVERY ticked resolution — each download runs on its
    // own single direct connection, exactly as requested.
    final picks = List<MediaFormat>.from(_selectedFormats);
    try {
      for (final format in picks) {
        final task = await DownloadManager.instance.startDownload(
          video: widget.result,
          format: format,
          audioTrackId: _selectedLanguage?.id,
          audioTrackName: _selectedLanguage?.name,
        );
        if (_targetFolderName != 'Default') {
          await VirtualFolderService.instance
              .addItemToFolderByName(_targetFolderName, task.id);
        }
      }
    } finally {
      if (mounted) setState(() => _downloadStarting = false);
    }

    if (mounted) {
      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.darkCard,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          content: Row(
            children: [
              const Icon(Icons.download_done_rounded, color: AppColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  picks.length == 1
                      ? 'Downloading "${widget.result.title}" to Folder "$_targetFolderName"'
                      : '${picks.length} downloads queued for "${widget.result.title}" → "$_targetFolderName"',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  Future<void> _downloadThumbnail() async {
    if (_thumbnailSaving || _thumbnailDone) return;
    final result = widget.result;
    if (result.thumbnailUrl.isEmpty) return;
    setState(() => _thumbnailSaving = true);
    try {
      await DownloadManager.instance.startThumbnailDownload(
        title: result.title,
        author: result.author,
        platform: result.platform,
        originalUrl: result.originalUrl,
        thumbnailUrl: result.thumbnailUrl,
      );
      if (!mounted) return;
      setState(() => _thumbnailDone = true);
      _toast('Thumbnail queued in Downloads');
    } catch (_) {
      _toast('Could not queue the thumbnail');
    } finally {
      if (mounted) setState(() => _thumbnailSaving = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.darkCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text(message, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Future<void> _openFolderPicker() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (ctx) => _FolderPickerSheet(
            selectedName: _targetFolderName,
            onCreateFolder: () async {
              Navigator.pop(ctx);
              await _createFolder();
            },
          ),
    );
    if (picked != null && picked.isNotEmpty && mounted) {
      setState(() => _targetFolderName = picked);
    }
  }

  Future<void> _createFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'New Folder',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'e.g. Action Movies, Favorite Songs',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text(
              'Create',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await VirtualFolderService.instance.createFolder(
        name,
        baseDirectory: DownloadManager.instance.downloadDirectory,
      );
      if (mounted) setState(() => _targetFolderName = name);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
        maxWidth: 680,
      ),
      margin: EdgeInsets.only(
        left: MediaQuery.of(context).size.width > 700
            ? (MediaQuery.of(context).size.width - 680) / 2
            : 0,
        right: MediaQuery.of(context).size.width > 700
            ? (MediaQuery.of(context).size.width - 680) / 2
            : 0,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dragHandle(isDark),
          _header(),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              children: [
                _locationCard(isDark),
                if (widget.result.thumbnailUrl.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _sectionLabel('THUMBNAIL'),
                  _card(isDark, children: [_thumbnailRow(isDark)]),
                ],
                if (widget.result.videoFormats.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _sectionLabel(
                    'VIDEO • ${widget.result.videoFormats.length} option${widget.result.videoFormats.length == 1 ? '' : 's'}',
                  ),
                  _card(
                    isDark,
                    children: [
                      for (int i = 0; i < widget.result.videoFormats.length; i++)
                        _formatRow(
                          widget.result.videoFormats[i],
                          isAudio: false,
                          isLast: i == widget.result.videoFormats.length - 1,
                          isDark: isDark,
                        ),
                    ],
                  ),
                ],
                if (widget.result.audioLanguages.length > 1) ...[
                  const SizedBox(height: 18),
                  _sectionLabel(
                    'AUDIO LANGUAGE • ${widget.result.audioLanguages.length} tracks',
                  ),
                  _card(isDark, children: [_languageChips(isDark)]),
                ],
                if (widget.result.audioFormats.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _sectionLabel(
                    'AUDIO ONLY • ${widget.result.audioFormats.length} option${widget.result.audioFormats.length == 1 ? '' : 's'}',
                  ),
                  _card(
                    isDark,
                    children: [
                      for (int i = 0; i < widget.result.audioFormats.length; i++)
                        _formatRow(
                          widget.result.audioFormats[i],
                          isAudio: true,
                          isLast: i == widget.result.audioFormats.length - 1,
                          isDark: isDark,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          _ctaButton(),
        ],
      ),
    );
  }

  Widget _dragHandle(bool isDark) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 10),
        width: 40,
        height: 4.5,
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkBorder : Colors.black26,
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  Widget _header() {
    final result = widget.result;
    final details = [
      if (result.author.isNotEmpty) result.author,
      if (result.duration.isNotEmpty) result.duration,
    ].join(' • ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.primaryDeep, AppColors.primary],
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SmartNetworkImage(
                url: result.thumbnailUrl,
                width: 82,
                height: 58,
                fit: BoxFit.cover,
                placeholderColor: AppColors.darkCard,
                placeholderIcon: Icons.movie_creation_rounded,
                accentColor: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16,
                    ),
                  ),
                  if (details.isNotEmpty)
                    Text(details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFFCE1E6), fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 7),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.darkTextSecondary
              : Colors.grey.shade600,
        ),
      ),
    );
  }

  Widget _card(bool isDark, {required List<Widget> children}) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  // ---------------------------------------------------------------------------
  // Save location — one clean iOS row instead of the old chip strip.
  // ---------------------------------------------------------------------------

  Widget _locationCard(bool isDark) {
    return _card(
      isDark,
      children: [
        InkWell(
          onTap: _openFolderPicker,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.accentGold.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(
                    CupertinoIcons.folder_fill,
                    color: AppColors.accentGold,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Save to folder',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _targetFolderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? AppColors.darkTextSecondary
                              : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _targetFolderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _iosBlue,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                ),
                Icon(
                  CupertinoIcons.right_chevron,
                  size: 15,
                  color: isDark ? AppColors.darkTextTertiary : Colors.grey.shade400,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Audio language — dubbed videos (MrBeast & co.) ship 10-20 separate audio
  // tracks. Whatever is picked here becomes the audio of the downloaded video
  // (muxed losslessly) or of the MP3.
  // ---------------------------------------------------------------------------

  Widget _languageChips(bool isDark) {
    final langs = widget.result.audioLanguages;
    final dubbed = langs.where((l) => !l.isDefault).toList();
    final original = langs.firstWhere((l) => l.isDefault,
        orElse: () => langs.first);

    return SizedBox(
      height: 60,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        children: [
          _langChip(
            text: '${original.name} • Original',
            on: _selectedLanguage == null,
            isDark: isDark,
            onTap: () => setState(() => _selectedLanguage = null),
          ),
          for (final l in dubbed)
            _langChip(
              text: l.name,
              on: _selectedLanguage?.id == l.id,
              isDark: isDark,
              onTap: () => setState(() => _selectedLanguage = l),
            ),
        ],
      ),
    );
  }

  Widget _langChip({
    required String text,
    required bool on,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: on
                ? _iosBlue.withValues(alpha: 0.16)
                : (isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              if (on)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.check_rounded, size: 15, color: _iosBlue),
                ),
              Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                  color: on
                      ? _iosBlue
                      : (isDark ? Colors.white70 : Colors.black87),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Thumbnail one-click row
  // ---------------------------------------------------------------------------

  Widget _thumbnailRow(bool isDark) {
    return InkWell(
      onTap: _downloadThumbnail,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.accentGreen.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(
                CupertinoIcons.photo_camera_solid,
                color: AppColors.accentGreen,
                size: 19,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Thumbnail image',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Save the cover picture with one tap',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey),
                  ),
                ],
              ),
            ),
            _thumbnailButton(),
          ],
        ),
      ),
    );
  }

  Widget _thumbnailButton() {
    if (_thumbnailDone) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, color: AppColors.accentGreen, size: 20),
          SizedBox(width: 4),
          Text(
            'Queued',
            style: TextStyle(
              color: AppColors.accentGreen,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: _iosBlue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: _thumbnailSaving
          ? const SizedBox(
              width: 15,
              height: 15,
              child: CupertinoActivityIndicator(radius: 7),
            )
          : const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.download_rounded, size: 15, color: FormatPickerSheetStyle.accent),
                SizedBox(width: 5),
                Text(
                  'Download',
                  style: TextStyle(
                    color: FormatPickerSheetStyle.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // Format rows — iOS list style: name + truth, container chip, bold size.
  // ---------------------------------------------------------------------------

  Widget _formatRow(
    MediaFormat format, {
    required bool isAudio,
    required bool isLast,
    required bool isDark,
  }) {
    final selected = _selectedFormats.any((s) => s.id == format.id);
    final parts = isAudio ? _audioParts(format) : _videoParts(format);
    final sizeText = _sizeText(format);

    // Exactly what the finished file will hold.
    final String kind;
    final Color kindColor;
    if (isAudio) {
      kind = 'Audio only';
      kindColor = AppColors.accentGold;
    } else if (format.needsAudioMerge) {
      kind = 'Video + Audio';
      kindColor = _iosBlue;
    } else {
      kind = 'Video + Audio';
      kindColor = _iosBlue;
    }

    return InkWell(
      onTap: () => _toggleFormat(format),
      child: Container(
        color: selected
            ? (isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : _iosBlue.withValues(alpha: 0.06))
            : null,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            _SelectionRing(selected: selected),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          parts.headline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      _containerChip(format.ext, isDark),
                      if (format.badge != null) ...[
                        const SizedBox(width: 5),
                        _badgeChip(format.badge!, isDark),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${parts.sub}  •  $kind',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isDark
                          ? AppColors.darkTextSecondary
                          : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  sizeText,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: selected
                        ? _iosBlue
                        : (isDark ? Colors.white : Colors.black87),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isAudio ? 'audio' : 'video',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: kindColor.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _containerChip(String ext, bool isDark) {
    final upper = ext.toUpperCase();
    final color = switch (upper) {
      'MP4' || 'M4V' => _iosBlue,
      'MP3' => AppColors.accentGreen,
      'M4A' || 'AAC' => AppColors.accentGold,
      _ => AppColors.accentBlue,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        upper,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
          color: color,
        ),
      ),
    );
  }

  Widget _badgeChip(String badge, bool isDark) {
    final Color color;
    switch (badge.toUpperCase()) {
      case '8K':
      case '4K':
        color = const Color(0xFFFF2D55); // Red/pink 4K
        break;
      case '2K':
      case 'FHD':
        color = const Color(0xFF5856D6); // Indigo FHD/2K
        break;
      case 'HD':
        color = const Color(0xFF007AFF); // Blue HD
        break;
      case 'HQ':
        color = const Color(0xFFFF9500); // Orange HQ
        break;
      case 'FAST':
        color = const Color(0xFF34C759); // Green FAST
        break;
      default:
        color = const Color(0xFF007AFF);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        badge,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
          color: color,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom CTA
  // ---------------------------------------------------------------------------

  Widget _ctaButton() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final count = _selectedFormats.length;
    final hasPick = count > 0;
    final String label;
    if (!hasPick) {
      label = 'Select at least one format';
    } else if (count == 1) {
      label =
          'Download ${_selectedFormats.first.label}'
          '${_selectedLanguage != null ? ' • ${_selectedLanguage!.name}' : ''}'
          '${_totalSizeText()}';
    } else {
      label = 'Download $count formats${_totalSizeText()}';
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightBg,
        border: Border(
          top: BorderSide(
            color: isDark ? AppColors.darkBorder : Colors.black12,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 50,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: hasPick ? AppColors.primaryGradient : null,
              color: hasPick ? null : Colors.grey.shade700,
              borderRadius: BorderRadius.circular(15),
              boxShadow: hasPick
                  ? [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.35),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : const [],
            ),
            child: ElevatedButton(
              onPressed: hasPick && !_downloadStarting ? _onDownloadPressed : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                backgroundColor: Colors.transparent,
                disabledBackgroundColor: Colors.transparent,
                elevation: 0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.download_rounded, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _downloadStarting ? 'Starting…' : label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// iOS radio-style selection indicator.
class _SelectionRing extends StatelessWidget {
  final bool selected;
  const _SelectionRing({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? FormatPickerSheetStyle.accent
            : FormatPickerSheetStyle.accent.withValues(alpha: .10),
      ),
      child: selected
          ? const Icon(
              CupertinoIcons.checkmark_alt,
              size: 14,
              color: Colors.white,
            )
          : null,
    );
  }
}

/// Tiny helper so [_SelectionRing] can reach the accent color without a
/// BuildContext at paint time.
class FormatPickerSheetStyle {
  static const Color accent = AppColors.primary;
}

// -----------------------------------------------------------------------------
// Cupertino-style folder picker sheet
// -----------------------------------------------------------------------------

class _FolderPickerSheet extends StatelessWidget {
  final String selectedName;
  final VoidCallback onCreateFolder;
  const _FolderPickerSheet({
    required this.selectedName,
    required this.onCreateFolder,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final folders = VirtualFolderService.instance.folders;
    final names = ['Default', ...folders.map((f) => f.name)];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.55,
        ),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard : Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Text(
              'Save to folder',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: names.length,
                separatorBuilder:
                    (_, _) => Divider(
                      height: 1,
                      indent: 16,
                      color: isDark ? Colors.white12 : Colors.black12,
                    ),
                itemBuilder: (context, index) {
                  final name = names[index];
                  final isSelected = name == selectedName;
                  return ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    leading: Icon(
                      name == 'Default'
                          ? CupertinoIcons.folder
                          : CupertinoIcons.folder_fill,
                      color:
                          name == 'Default'
                              ? Colors.grey
                              : AppColors.accentGold,
                    ),
                    title: Text(
                      name,
                      style: TextStyle(
                        fontWeight:
                            isSelected ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                    trailing:
                        isSelected
                            ? const Icon(
                                CupertinoIcons.checkmark_alt,
                                color: FormatPickerSheetStyle.accent,
                              )
                            : null,
                    onTap: () => Navigator.pop(context, name),
                  );
                },
              ),
            ),
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: isDark ? Colors.white12 : Colors.black12,
            ),
            ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              leading: const Icon(
                CupertinoIcons.add_circled_solid,
                color: FormatPickerSheetStyle.accent,
              ),
              title: const Text(
                'New Folder',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: FormatPickerSheetStyle.accent,
                ),
              ),
              onTap: onCreateFolder,
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
