import 'dart:async';

import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../theme/app_palette.dart';
import '../widgets/movie_card.dart';
import '../widgets/movie_detail_sheet.dart';

/// The complete library of the currently selected source, grouped by the
/// source's own sections and split into Movies / Series / Anime on one page.
class SourceLibraryScreen extends StatefulWidget {
  const SourceLibraryScreen({
    super.key,
    required this.repoId,
    required this.providerId,
    this.title = 'All titles',
    this.initialTab = 'All',
  });

  final String repoId;
  final String providerId;
  final String title;
  final String initialTab;

  static Future<void> show(
    BuildContext context, {
    required String repoId,
    required String providerId,
    String title = 'All titles',
    String initialTab = 'All',
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceLibraryScreen(
          repoId: repoId,
          providerId: providerId,
          title: title,
          initialTab: initialTab,
        ),
      ),
    );
  }

  @override
  State<SourceLibraryScreen> createState() => _SourceLibraryScreenState();
}

class _SourceLibraryScreenState extends State<SourceLibraryScreen> {
  final _engine = ProviderEngineService.instance;
  final List<MovieItem> _all = [];
  final Set<String> _seen = {};
  bool _loading = false;
  bool _done = false;
  int _page = 0;
  late String _tab;
  String? _error;

  static const _tabs = ['All', 'Movies', 'Series', 'Anime'];
  static const _maxPages = 12;
  static const _budget = Duration(seconds: 10);

  String get _category => switch (_tab) {
        'Movies' => 'movies',
        'Series' => 'series',
        'Anime' => 'anime',
        _ => 'all',
      };

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    unawaited(_loadAll());
  }

  Future<void> _loadAll() async {
    if (_loading || _done) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final deadline = DateTime.now().add(_budget);
    try {
      while (_page <= _maxPages && DateTime.now().isBefore(deadline)) {
        final batch = await _engine.fetchCatalog(
          repoId: widget.repoId,
          providerId: widget.providerId,
          page: _page,
        );
        final fresh = batch.where((m) => _seen.add(m.detailUrl)).toList();
        if (!mounted) return;
        setState(() {
          _all.addAll(fresh);
          _page++;
        });
        if (batch.isEmpty || fresh.isEmpty) break;
      }
      if (mounted) setState(() => _done = true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<MovieItem> get _visible {
    return _all.where((movie) {
      return switch (_tab) {
        'Movies' => !movie.isSeries && !movie.isAnime,
        'Series' => movie.isSeries && !movie.isAnime,
        'Anime' => movie.isAnime,
        _ => true,
      };
    }).toList();
  }

  Map<String, List<MovieItem>> get _sections {
    final grouped = <String, List<MovieItem>>{};
    for (final movie in _visible) {
      final label = movie.catalogGroups.isNotEmpty
          ? movie.catalogGroups.first
          : switch (_tab) {
              'Movies' => 'Movies',
              'Series' => 'Series',
              'Anime' => 'Anime',
              _ => movie.isSeries ? 'Series' : 'Movies',
            };
      grouped.putIfAbsent(label, () => []).add(movie);
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final groups = _sections;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.background,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: TextStyle(color: p.textPrimary)),
            Text(
              '${_all.length} titles · ${widget.providerId}',
              style: TextStyle(color: p.textSecondary, fontSize: 10.5),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _tabs.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final tab = _tabs[index];
                final active = _tab == tab;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: ChoiceChip(
                    label: Text(tab),
                    selected: active,
                    onSelected: (_) => setState(() => _tab = tab),
                    selectedColor: p.primary,
                    backgroundColor: p.card,
                    side: BorderSide(color: active ? p.primary : p.border),
                    labelStyle: TextStyle(
                      color: active ? p.onPrimary : p.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: _all.isEmpty && _loading
                ? Center(child: CircularProgressIndicator(color: p.primary))
                : _all.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error ??
                                'No titles were returned by this source yet.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
                        itemCount: groups.length + (_done ? 0 : 1),
                        itemBuilder: (context, index) {
                          if (index == groups.length) {
                            return Padding(
                              padding: const EdgeInsets.all(20),
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: p.primary,
                                ),
                              ),
                            );
                          }
                          final entry = groups.entries.elementAt(index);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  6,
                                  14,
                                  6,
                                  8,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 3,
                                      height: 16,
                                      decoration: BoxDecoration(
                                        color: p.primary,
                                        borderRadius:
                                            BorderRadius.circular(3),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        entry.key,
                                        style: TextStyle(
                                          color: p.textPrimary,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${entry.value.length}',
                                      style: TextStyle(
                                        color: p.textSecondary,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              GridView.builder(
                                shrinkWrap: true,
                                physics:
                                    const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  childAspectRatio: .58,
                                  crossAxisSpacing: 9,
                                  mainAxisSpacing: 11,
                                ),
                                itemCount: entry.value.length,
                                itemBuilder: (context, i) {
                                  final movie = entry.value[i];
                                  return MovieCard(
                                    key: ValueKey(movie.detailUrl),
                                    movie: movie,
                                    compact: true,
                                    onTap: () =>
                                        MovieDetailSheet.show(context, movie),
                                  );
                                },
                              ),
                            ],
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
