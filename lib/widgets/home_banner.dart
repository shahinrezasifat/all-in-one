import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../services/image_cache_service.dart';
import 'looping_control_content.dart';
import 'remote_image.dart';

class HomeBanner extends StatefulWidget {
  const HomeBanner({
    super.key,
    required this.movies,
    required this.style,
    required this.autoPlay,
    required this.onOpen,
  });

  final List<MovieItem> movies;
  final String style;
  final bool autoPlay;
  final ValueChanged<MovieItem> onOpen;

  @override
  State<HomeBanner> createState() => _HomeBannerState();
}

class _HomeBannerState extends State<HomeBanner> {
  // A virtual middle page keeps the carousel swipeable in both directions.
  static const _origin = 10000;
  final _page = PageController(initialPage: _origin, viewportFraction: .34);
  Timer? _timer;
  int _index = _origin;
  int _settledIndex = _origin;
  final _palette = <String, Future<Color?>>{};
  bool _visible = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    _schedule();
  }

  @override
  void didUpdateWidget(covariant HomeBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.autoPlay != widget.autoPlay ||
        oldWidget.movies.length != widget.movies.length) {
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _page.dispose();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_visible || !widget.autoPlay || widget.movies.length < 2) return;
    _timer = Timer(const Duration(seconds: 5), () {
      if (_page.hasClients && ModalRoute.of(context)?.isCurrent != false) {
        _slideTo(_index + 1);
      }
      _schedule();
    });
  }

  void _slideTo(int page) {
    if (!_page.hasClients) return;
    _page.animateToPage(
      page,
      duration: Duration(
        milliseconds: MediaQuery.disableAnimationsOf(context) ? 1 : 420,
      ),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final movies = widget.movies;
    if (movies.isEmpty) {
      return const SizedBox.shrink();
    }
    final current = movies[(_index - _origin) % movies.length];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = (width * .73).clamp(185.0, 352.0);
            return Column(
              children: [
                SizedBox(
                  height: height + 32,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (Theme.of(context).brightness == Brightness.light)
                        _posterGlow(current),
                      if (movies.length == 1)
                        Center(
                          child: SizedBox(
                            width: height * .69,
                            height: height,
                            child: _poster(
                              current,
                              () => widget.onOpen(current),
                              sweep: _visible,
                            ),
                          ),
                        )
                      else
                        Stack(
                          fit: StackFit.expand,
                          children: [
                            IgnorePointer(
                              child: AnimatedBuilder(
                                animation: _page,
                                builder: (context, _) {
                                  final page = _page.hasClients
                                      ? _page.page ?? _index.toDouble()
                                      : _index.toDouble();
                                  final closest = page.round();
                                  final layers =
                                      [closest - 1, closest + 1, closest]..sort(
                                        (a, b) => (b - page).abs().compareTo(
                                          (a - page).abs(),
                                        ),
                                      );
                                  return Stack(
                                    alignment: Alignment.center,
                                    clipBehavior: Clip.none,
                                    children: [
                                      for (final index in layers)
                                        _layeredPoster(
                                          movies[(index - _origin) %
                                              movies.length],
                                          position: index - page,
                                          width: width,
                                          height: height,
                                          index: index,
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                            NotificationListener<ScrollNotification>(
                              onNotification: (event) {
                                if (event is ScrollStartNotification &&
                                    event.dragDetails != null) {
                                  _timer?.cancel();
                                }
                                if (event is ScrollEndNotification) {
                                  if (_settledIndex != _index) {
                                    setState(() => _settledIndex = _index);
                                  }
                                  _schedule();
                                }
                                return false;
                              },
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (event) {
                                  final offset =
                                      event.localPosition.dx - width / 2;
                                  if (offset.abs() <= height * .345) {
                                    widget.onOpen(current);
                                  } else {
                                    _slideTo(_index + (offset < 0 ? -1 : 1));
                                  }
                                },
                                child: PageView.builder(
                                  controller: _page,
                                  onPageChanged: (index) =>
                                      setState(() => _index = index),
                                  itemBuilder: (context, index) {
                                    final movie =
                                        movies[(index - _origin) %
                                            movies.length];
                                    return Semantics(
                                      button: true,
                                      selected: index == _index,
                                      label: movie.title,
                                      onTap: () {
                                        if (index == _index) {
                                          widget.onOpen(movie);
                                        } else {
                                          _slideTo(index);
                                        }
                                      },
                                      child: const SizedBox.expand(),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton(
                      onPressed: () => widget.onOpen(current),
                      child: LoopingControlContent(
                        trigger: _settledIndex,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.play_arrow_rounded, size: 18),
                            SizedBox(width: 6),
                            Text('Watch'),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Movie details',
                      onPressed: () => widget.onOpen(current),
                      icon: LoopingControlContent(
                        trigger: _settledIndex,
                        delay: const Duration(milliseconds: 900),
                        child: const Icon(Icons.info_outline_rounded),
                      ),
                    ),
                  ],
                ),
                if (movies.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 6),
                    child: Wrap(
                      spacing: 5,
                      children: [
                        for (var i = 0; i < movies.length; i++)
                          GestureDetector(
                            onTap: () => _slideTo(
                              _index + i - ((_index - _origin) % movies.length),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 220),
                                width: i == (_index - _origin) % movies.length
                                    ? 20
                                    : 6,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: i == (_index - _origin) % movies.length
                                      ? colors.primary
                                      : colors.onSurface.withValues(alpha: .20),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _posterGlow(MovieItem movie) {
    final key = '${movie.posterUrl}|${movie.backdropUrl}';
    if (!_palette.containsKey(key) && _palette.length >= 32) {
      _palette.remove(_palette.keys.first);
    }
    return FutureBuilder<Color?>(
      key: ValueKey(key),
      future: _palette.putIfAbsent(key, () => _posterColor(movie)),
      builder: (context, snapshot) => TweenAnimationBuilder<Color?>(
        tween: ColorTween(
          begin: Colors.transparent,
          end: snapshot.data?.withValues(alpha: .19) ?? Colors.transparent,
        ),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 360),
        builder: (_, tint, _) => IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: .62,
                colors: [tint ?? Colors.transparent, Colors.transparent],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<Color?> _posterColor(MovieItem movie) async {
    final cache = ImageCacheService.instance;
    try {
      for (final url in {movie.posterUrl, movie.backdropUrl}) {
        if (url.trim().isEmpty) continue;
        final bytes = await cache.getBytes(url.trim());
        if (bytes == null || bytes.isEmpty) continue;
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: 24,
          targetHeight: 24,
        );
        try {
          final image = (await codec.getNextFrame()).image;
          try {
            final pixels = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            if (pixels == null) continue;
            final buckets = <int, double>{};
            for (var offset = 0; offset < pixels.lengthInBytes; offset += 4) {
              if (pixels.getUint8(offset + 3) < 200) continue;
              final r = pixels.getUint8(offset);
              final g = pixels.getUint8(offset + 1);
              final b = pixels.getUint8(offset + 2);
              final tone = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
              if (tone.lightness < .12 ||
                  tone.lightness > .88 ||
                  tone.saturation < .16)
                continue;
              final key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5);
              buckets.update(
                key,
                (weight) => weight + tone.saturation,
                ifAbsent: () => tone.saturation,
              );
            }
            if (buckets.isEmpty) return null;
            final key = buckets.entries
                .reduce((a, b) => a.value >= b.value ? a : b)
                .key;
            return Color.fromARGB(
              255,
              ((key >> 6) & 7) * 32 + 16,
              ((key >> 3) & 7) * 32 + 16,
              (key & 7) * 32 + 16,
            );
          } finally {
            image.dispose();
          }
        } finally {
          codec.dispose();
        }
      }
    } catch (_) {
      // Artwork can be unavailable or undecodable.
    }
    return null;
  }

  Widget _layeredPoster(
    MovieItem movie, {
    required double position,
    required double width,
    required double height,
    required int index,
  }) {
    final distance = position.abs().clamp(0.0, 1.0);
    return Transform.translate(
      key: ValueKey(index),
      offset: Offset(position * width * .285, distance * 10),
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, .0012)
          ..rotateY(-position.clamp(-1.0, 1.0) * .25),
        child: SizedBox(
          width: height * .69 * (1 - .25 * distance),
          height: height * (1 - .24 * distance),
          child: _poster(
            movie,
            null,
            shade: distance,
            right: position > 0,
            sweep: _visible && index == _settledIndex,
          ),
        ),
      ),
    );
  }

  Widget _poster(
    MovieItem movie,
    VoidCallback? onTap, {
    double shade = 0,
    bool right = false,
    bool sweep = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = BorderRadius.circular(22);
    final url = movie.posterUrl.isNotEmpty
        ? movie.posterUrl
        : movie.backdropUrl;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? .45 : .20,
            ),
            blurRadius: 18,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Material(
        color: colors.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            label: movie.title,
            child: Stack(
              fit: StackFit.expand,
              children: [
                SmartNetworkImage(
                  url: url,
                  fallbackUrl: movie.backdropUrl,
                  fit: BoxFit.cover,
                  placeholder: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(
                            colors.primary.withValues(alpha: .22),
                            colors.surface,
                          ),
                          Color.alphaBlend(
                            colors.primary.withValues(alpha: .06),
                            colors.surface,
                          ),
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.movie_outlined,
                            size: 27,
                            color: colors.primary,
                          ),
                          const SizedBox(height: 9),
                          Text(
                            movie.title,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (sweep)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: RepaintBoundary(
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey((movie.id, _settledIndex)),
                          tween: Tween(begin: 0, end: 1),
                          duration: const Duration(milliseconds: 720),
                          curve: Curves.easeInOutCubic,
                          builder: (_, progress, _) => CustomPaint(
                            painter: _PosterSweep(
                              progress,
                              (1 - shade * 5).clamp(0.0, 1.0),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (shade > 0)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: right
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        end: right
                            ? Alignment.centerLeft
                            : Alignment.centerRight,
                        stops: const [0, .46, 1],
                        colors: [
                          Colors.black.withValues(alpha: .12 * shade),
                          Colors.black.withValues(alpha: .31 * shade),
                          Colors.black.withValues(alpha: .82 * shade),
                        ],
                      ),
                    ),
                  ),
                if (widget.style != 'poster')
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            widget.style == 'spotlight'
                                ? colors.primary.withValues(alpha: .30)
                                : Colors.black.withValues(alpha: .20),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PosterSweep extends CustomPainter {
  const _PosterSweep(this.progress, this.opacity);
  final double progress;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1 || opacity <= 0) return;
    final center = size.width * (-.75 + 2.5 * progress);
    final width = size.width * .30;
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(center - width, size.height * .32),
        Offset(center + width, size.height * .68),
        [
          Colors.transparent,
          Colors.white.withValues(alpha: .07 * opacity),
          Colors.white.withValues(alpha: .35 * opacity),
          Colors.white.withValues(alpha: .07 * opacity),
          Colors.transparent,
        ],
        const [0, .30, .50, .70, 1],
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_PosterSweep oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.opacity != opacity;
}
