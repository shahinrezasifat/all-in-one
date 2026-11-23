import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../theme/app_palette.dart';
import '../services/image_cache_service.dart';

/// Robust network image backed by the persistent 50 MB [ImageCacheService].
/// Never leaves a broken/grey tile: stale or blocked CDN art (e.g. Spotify
/// `i.scdn.co`) degrades gracefully to a clean placeholder (initials or an
/// icon) while loading and on any error, instead of a blank box.
///
/// It deliberately does NOT use `Image.network`: Flutter's engine fetches with
/// a bare "Dart/x" User-Agent that many image CDNs reject with 403, and it
/// keeps NOTHING on disk, so every relaunch re-downloaded every poster — the
/// main source of the app's lag. Now bytes come memory → disk → browser-UA
/// network through the shared cache, so revisited art paints instantly with
/// zero network, and [prefetch] pre-loads lists before they scroll into view.
class SmartNetworkImage extends StatefulWidget {
  final String url;
  final String? fallbackUrl;
  final Widget? placeholder;
  final double? width;
  final double? height;
  final BoxFit fit;
  final IconData placeholderIcon;
  final String? fallbackInitials;
  final BorderRadius? borderRadius;
  final Color? placeholderColor;
  final Color? accentColor;

  SmartNetworkImage({
    super.key,
    required this.url,
    this.fallbackUrl,
    this.placeholder,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholderIcon = Icons.image_rounded,
    this.fallbackInitials,
    this.borderRadius,
    this.placeholderColor,
    this.accentColor,
  });

  static String initialsFor(String text) {
    final parts = text
        .replaceAll(RegExp(r'[^A-Za-z0-9 ]'), '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  /// Preload art into the 50 MB cache WITHOUT waiting — call right after a
  /// list/search result arrives so scrolling later is instant and offline.
  static void prefetch(Iterable<String> urls) =>
      ImageCacheService.instance.prefetch(urls);

  @override
  State<SmartNetworkImage> createState() => _SmartNetworkImageState();
}

class _SmartNetworkImageState extends State<SmartNetworkImage> {
  Uint8List? _bytes;
  bool _failed = false;

  // Guards against the classic list-recycle image swap: when a scrolled tile is
  // reused for a different URL, the previous in-flight fetch may still resolve.
  // Every load bumps this token; a response is only applied if its token is
  // still the current one, so stale/mismatched art can never be painted.
  int _loadId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SmartNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.fallbackUrl != widget.fallbackUrl) {
      // Invalidate any outstanding fetch before starting the new one.
      _loadId++;
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  @override
  void dispose() {
    _loadId++; // Cancel any pending apply-after-dispose.
    super.dispose();
  }

  Future<void> _load() async {
    final myLoad = ++_loadId;
    final url = widget.url.trim();
    bool isCurrent() => mounted && myLoad == _loadId;

    final alternate = widget.fallbackUrl?.trim() ?? '';
    final cache = ImageCacheService.instance;
    var bytes = url.isEmpty ? null : await cache.getBytes(url);
    if ((bytes == null || bytes.isEmpty) &&
        alternate.isNotEmpty && alternate != url && isCurrent()) {
      bytes = await cache.getBytes(alternate);
    }
    if (isCurrent()) {
      setState(() {
        _bytes = bytes;
        _failed = bytes == null || bytes.isEmpty;
      });
    }
  }

  Widget _buildPlaceholder() {
    if (widget.placeholder != null) return widget.placeholder!;
    final p = context.palette;
    final placeholder = widget.placeholderColor ?? p.background;
    final accent = widget.accentColor ?? p.success;
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: placeholder,
        borderRadius: widget.borderRadius,
      ),
      child: Center(
        child: (widget.fallbackInitials != null && widget.fallbackInitials!.isNotEmpty)
            ? Text(
                widget.fallbackInitials!,
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w900,
                  fontSize: (widget.height ?? 24) * 0.4,
                ),
              )
            : Icon(widget.placeholderIcon,
                color: accent, size: (widget.height ?? 24) * 0.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    Widget img;

    if (bytes == null || _failed) {
      // Loading, empty, or blocked-and-failed: always show the graceful tile.
      img = _buildPlaceholder();
    } else {
      // Decode at the size actually displayed (device pixels), NOT full CDN
      // resolution — dozens of full-size posters decoded in the ImageCache is
      // what made scrolling heavy. This cuts decoded RAM by 5-10x per tile.
      final dpr = MediaQuery.of(context).devicePixelRatio;
      // The banner is rendered with width: double.infinity; multiplying and
      // rounding Infinity throws "Unsupported operation: Infinity or NaN toInt".
      // Clamp the double first (and skip non-finite widths entirely).
      final w = widget.width;
      final hintW = (w != null && w.isFinite && dpr.isFinite)
          ? (w * dpr).clamp(64.0, 1600.0).round()
          : null;
      img = Image.memory(
        bytes,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: hintW,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }

    if (widget.borderRadius != null) {
      img = ClipRRect(borderRadius: widget.borderRadius!, child: img);
    }
    return img;
  }
}
