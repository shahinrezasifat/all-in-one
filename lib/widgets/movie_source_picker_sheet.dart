import 'package:flutter/material.dart';
import '../models/movie_model.dart';
import '../services/movie_repository_service.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../theme/app_colors.dart';

/// Step 2 of a movie download: after a format (resolution) is chosen, list
/// every repository/source that actually carries this movie in that format.
/// Already-resolved sources appear instantly; the rest stream in progressively
/// as each repo answers. The chosen [MovieSource] is returned to the caller.
class MovieSourcePickerSheet extends StatefulWidget {
  final MovieItem movie;
  final List<MovieSource> initialSources;
  final int height;
  final String formatLabel;

  const MovieSourcePickerSheet({
    super.key,
    required this.movie,
    required this.initialSources,
    required this.height,
    required this.formatLabel,
  });

  static Future<MovieSource?> show(
    BuildContext context, {
    required MovieItem movie,
    required List<MovieSource> initialSources,
    required int height,
    required String formatLabel,
  }) {
    return showModalBottomSheet<MovieSource?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MovieSourcePickerSheet(
        movie: movie,
        initialSources: initialSources,
        height: height,
        formatLabel: formatLabel,
      ),
    );
  }

  @override
  State<MovieSourcePickerSheet> createState() => _MovieSourcePickerSheetState();
}

class _MovieSourcePickerSheetState extends State<MovieSourcePickerSheet> {
  final List<MovieSource> _sources = [];
  MovieSource? _selected;
  bool _scanning = true;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  /// Only sources whose first byte is actually fetchable are added — dead
  /// links are hidden completely instead of failing at download time.
  Future<void> _addReachable(List<MovieSource> batch) async {
    final seen = <String>{};
    final candidates = batch.where((s) {
      if (!_matches(s)) return false;
      final url = _urlOf(s);
      if (url.isEmpty || seen.contains(url) || _hasUrl(s)) return false;
      seen.add(url);
      return true;
    }).toList();
    if (candidates.isEmpty) return;

    final reachable = <MovieSource>[];
    // At most 8 probes in flight — testing a large catalog batch at once would
    // otherwise open hundreds of sockets and skew the result with timeouts.
    for (var start = 0; start < candidates.length; start += 8) {
      final end = (start + 8 < candidates.length) ? start + 8 : candidates.length;
      final chunk = candidates.sublist(start, end);
      final checks = await Future.wait(
          chunk.map(ProviderEngineService.probeSource));
      for (var i = 0; i < chunk.length; i++) {
        if (checks[i]) reachable.add(chunk[i]);
      }
    }
    if (!mounted || _cancelled || reachable.isEmpty) return;
    setState(() {
      for (final s in reachable) {
        if (!_hasUrl(s)) _sources.add(s);
      }
    });
  }

  static String _urlOf(MovieSource s) =>
      s.downloadUrl.isNotEmpty ? s.downloadUrl : s.streamUrl;

  bool _matches(MovieSource s) =>
      widget.height <= 0 || _heightOf(s) == widget.height;

  bool _hasUrl(MovieSource s) =>
      _sources.any((x) => _urlOf(x) == _urlOf(s));

  static int _heightOf(MovieSource s) {
    final r = s.resolution.toLowerCase();
    if (r.contains('4k') || r.contains('2160')) return 2160;
    final m = RegExp(r'(\d{3,4})p?').firstMatch(r);
    if (m != null) return int.tryParse(m.group(1)!) ?? 0;
    if (r.contains('hd') && !r.contains('480')) return 720;
    if (r.contains('sd') || r.contains('480')) return 480;
    return 0;
  }

  Future<void> _startScan() async {
    // Instantly-verified sources from the movie's own resolved list first.
    await _addReachable(widget.initialSources);
    await ProviderEngineService.instance.resolveStreamsProgressively(
      widget.movie,
      onBatch: (batch) async => _addReachable(batch),
    );
    if (mounted && !_cancelled) setState(() => _scanning = false);
  }

  String _repoName(MovieSource s) {
    final n = s.repoName.isNotEmpty
        ? s.repoName
        : (s.providerName.isNotEmpty ? s.providerName : s.serverName);
    return n.trim().isEmpty ? 'Unknown source' : n;
  }

  String _size(MovieSource s) =>
      s.fileSize.trim().isEmpty ? 'size unknown' : s.fileSize;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = _selected;
    final repoService = MovieRepositoryService.instance;
    final enabledRepos = repoService.enabledRepositories.length;
    final totalRepos = repoService.repositories.length;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.82,
      ),
      margin: EdgeInsets.only(
        left: MediaQuery.of(context).size.width > 700
            ? (MediaQuery.of(context).size.width - 640) / 2
            : 0,
        right: MediaQuery.of(context).size.width > 700
            ? (MediaQuery.of(context).size.width - 640) / 2
            : 0,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBorder : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Choose a source',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${widget.movie.title} • ${widget.formatLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark
                              ? AppColors.darkTextSecondary
                              : AppColors.lightTextSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$enabledRepos of $totalRepos repositories enabled',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: isDark
                              ? AppColors.darkTextTertiary
                              : AppColors.lightTextTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          if (_scanning)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Scanning repositories… ${_sources.length} found',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _cancelled = true),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero),
                    child: const Text('Stop',
                        style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Flexible(
            child: _sources.isEmpty && !_scanning
                ? Padding(
                    padding: const EdgeInsets.all(40),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'No source has ${widget.formatLabel} for this movie.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                _cancelled = false;
                                _scanning = true;
                              });
                              _startScan();
                            },
                            icon: const Icon(Icons.refresh_rounded, size: 16),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    itemCount: _sources.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final s = _sources[i];
                      final isSelected =
                          selected != null && _urlOf(s) == _urlOf(selected);
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => setState(() => _selected = s),
                          borderRadius: BorderRadius.circular(14),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppColors.primary.withValues(
                                      alpha: isDark ? 0.14 : 0.08)
                                  : (isDark
                                      ? AppColors.darkCard
                                      : Colors.white),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: AppColors.primary
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Center(
                                    child: Text(
                                      _repoName(s).substring(0, 1).toUpperCase(),
                                      style: const TextStyle(
                                        color: AppColors.primary,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _repoName(s),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${s.resolution} • ${_size(s)} • ${s.format.toUpperCase()}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: isDark
                                              ? AppColors.darkTextTertiary
                                              : AppColors.lightTextTertiary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  isSelected
                                      ? Icons.check_circle_rounded
                                      : Icons.circle_outlined,
                                  size: 18,
                                  color: isSelected
                                      ? AppColors.primary
                                      : (isDark
                                          ? Colors.white30
                                          : Colors.black26),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              border: Border(
                top: BorderSide(
                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: selected == null
                          ? null
                          : () => Navigator.pop(context, selected),
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: Text(
                        selected == null
                            ? 'Select a source'
                            : 'Download from ${_repoName(selected)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        disabledBackgroundColor: isDark
                            ? Colors.white12
                            : Colors.grey.shade300,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
