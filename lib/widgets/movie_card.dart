import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../theme/app_palette.dart';
import 'movie_detail_sheet.dart';
import 'remote_image.dart';

class MovieCard extends StatelessWidget {
  static final catalogGrid = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 150,
    childAspectRatio: .62,
    crossAxisSpacing: 12,
    mainAxisSpacing: 14,
  );

  final MovieItem movie;
  final VoidCallback? onTap;
  final bool compact;

  MovieCard({
    super.key,
    required this.movie,
    this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final quality = movie.quality.trim();

    return Container(
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: compact
            ? null
            : [
                BoxShadow(
                  color: context.palette.shadowAt(isDark ? 0.35 : 0.08),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap ?? () => MovieDetailSheet.show(context, movie),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Poster with floating badges
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      SmartNetworkImage(
                        url: movie.posterUrl,
                        fit: BoxFit.cover,
                        placeholderColor: context.palette.surface,
                        placeholderIcon:
                            movie.genres.contains('Music') ||
                                movie.genres.contains('Audio')
                            ? Icons.music_note_rounded
                            : Icons.movie_rounded,
                        accentColor: compact
                            ? context.palette.info
                            : context.palette.primary,
                      ),

                      if (!compact) ...[
                        // Gradient scrim at bottom of poster
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 60,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.transparent,
                                  context.palette.shadowAt(0.85),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                          ),
                        ),

                        if (quality.isNotEmpty)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    movie.quality.contains('FLAC') ||
                                        movie.quality.contains('320')
                                    ? context.palette.success
                                    : (movie.quality.contains('4K')
                                          ? context.palette.info
                                          : context.palette.primary),
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [
                                  BoxShadow(
                                    color: context.palette.shadowAt(0.4),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: Text(
                                movie.quality.contains('FLAC')
                                    ? 'FLAC HD'
                                    : (movie.quality.contains('4K')
                                          ? '4K UHD'
                                          : quality),
                                style: TextStyle(
                                  color: context.palette.background,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),

                        // Top-right Rating badge
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: context.palette.shadowAt(0.85),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.star_rounded,
                                  color: context.palette.info,
                                  size: 12,
                                ),
                                SizedBox(width: 3),
                                Text(
                                  '${movie.rating}',
                                  style: TextStyle(
                                    color: context.palette.onScrim,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // Bottom-left Provider badge
                        if (movie.providerName.isNotEmpty)
                          Positioned(
                            bottom: 8,
                            left: 8,
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: context.palette.error
                                    .withValues(alpha: 0.88),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                movie.providerName,
                                style: TextStyle(
                                  color: context.palette.onScrim,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),

                        // Bottom Floating Quick Download Action Icon
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: Material(
                            color: context.palette.primary,
                            borderRadius: BorderRadius.circular(20),
                            child: InkWell(
                              onTap:
                                  onTap ??
                                  () => MovieDetailSheet.show(context, movie),
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: EdgeInsets.all(6),
                                child: Icon(
                                  Icons.download_rounded,
                                  color: context.palette.onPrimary,
                                  size: 16,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // Title and Info
                Padding(
                  padding: compact
                      ? EdgeInsets.fromLTRB(8, 7, 8, 8)
                      : EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        movie.title,
                        maxLines: compact ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 12 : 13,
                          height: compact ? 1.2 : null,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (!compact) ...[
                        SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                '${movie.year} • ${movie.genres.isNotEmpty ? movie.genres.first : "Cinema"}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.palette.textSecondary,
                                ),
                              ),
                            ),
                            SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                movie.duration,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: context.palette.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
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
