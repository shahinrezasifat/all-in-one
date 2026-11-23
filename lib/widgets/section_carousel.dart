import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../theme/app_palette.dart';
import 'movie_card.dart';
import 'remote_image.dart';

/// A titled horizontal movie row with an "All ›" action, matching the
/// section-based catalog layout.
class SectionCarousel extends StatelessWidget {
  const SectionCarousel({
    super.key,
    required this.title,
    required this.movies,
    required this.onOpen,
    this.onSeeAll,
    this.soonDates = const {},
  });

  final String title;
  final List<MovieItem> movies;
  final ValueChanged<MovieItem> onOpen;
  final VoidCallback? onSeeAll;

  /// detailUrl -> release label, for "Coming Soon" sections.
  final Map<String, String> soonDates;

  @override
  Widget build(BuildContext context) {
    if (movies.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (onSeeAll != null)
                TextButton(
                  onPressed: onSeeAll,
                  style: TextButton.styleFrom(
                    foregroundColor: p.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: const Text('All ›'),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 178,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: movies.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final movie = movies[index];
              final soon = soonDates[movie.detailUrl];
              return SizedBox(
                width: 112,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _SectionPoster(
                      key: ValueKey(movie.detailUrl),
                      movie: movie,
                      onTap: () => onOpen(movie),
                    ),
                    if (soon != null)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: p.scrimAt(0.8),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                soon,
                                style: TextStyle(
                                  color: p.onScrim,
                                  fontSize: 8,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: p.scrimAt(0.8),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.notifications_none_rounded,
                                color: p.onScrim,
                                size: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Compact poster used inside carousels. It mirrors MovieCard's compact look
/// but is a separate widget so catalogue grids and carousels stay independent.
class _SectionPoster extends StatelessWidget {
  const _SectionPoster({super.key, required this.movie, required this.onTap});

  final MovieItem movie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    SmartNetworkImage(
                      url: movie.posterUrl,
                      fit: BoxFit.cover,
                      placeholderColor: p.surface,
                      placeholderIcon: Icons.movie_rounded,
                      accentColor: p.primary,
                    ),
                    Positioned(
                      top: 5,
                      left: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: p.scrimAt(0.78),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          MovieCard.languageOf(movie),
                          style: TextStyle(
                            color: p.onScrim,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    if (movie.rating > 0)
                      Positioned(
                        bottom: 5,
                        right: 5,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: p.scrimAt(0.86),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.star_rounded,
                                color: p.info,
                                size: 10,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                movie.rating.toStringAsFixed(1),
                                style: TextStyle(
                                  color: p.onScrim,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(7, 6, 7, 7),
                child: Text(
                  movie.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
