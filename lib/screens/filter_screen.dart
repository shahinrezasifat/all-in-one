import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../services/movie_repository_service.dart';
import '../theme/app_palette.dart';
import '../widgets/movie_card.dart';
import '../widgets/movie_detail_sheet.dart';

/// Dedicated catalog filter screen: type tabs + Genre/Country/Year chips and a
/// compact poster grid, matching a modern streaming-app filter page.
class FilterScreen extends StatefulWidget {
  const FilterScreen({
    super.key,
    this.initialType = 'Movie',
    this.initialGenre,
  });

  final String initialType;
  final String? initialGenre;

  static Future<void> show(
    BuildContext context, {
    String initialType = 'Movie',
    String? initialGenre,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FilterScreen(
          initialType: initialType,
          initialGenre: initialGenre,
        ),
      ),
    );
  }

  @override
  State<FilterScreen> createState() => _FilterScreenState();
}

class _FilterScreenState extends State<FilterScreen> {
  late String _type;
  String? _genre;
  String? _country;
  int? _year;
  bool _searchOpen = false;
  final _searchCtrl = TextEditingController();

  static const _types = ['Anime', 'Movie', 'TV'];

  @override
  void initState() {
    super.initState();
    _type = 'All';
    _genre = widget.initialGenre;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<MovieItem> get _movies {
    final repo = MovieRepositoryService.instance;
    final query = _searchCtrl.text.trim().toLowerCase();
    var list = repo.getAllMovies();

    list = list.where((m) {
      final isAnime = m.isAnime;
      final isSeries = m.isSeries;
      final typeMatch = switch (_type) {
        'Anime' => isAnime,
        'TV' => isSeries && !isAnime,
        _ => !isSeries && !isAnime,
      };
      if (!typeMatch) return false;
      if (_genre != null &&
          !m.genres.any(
            (g) => g.toLowerCase() == _genre!.toLowerCase(),
          )) {
        return false;
      }
      if (_country != null &&
          !m.genres.any(
            (g) => g.toLowerCase() == _country!.toLowerCase(),
          )) {
        return false;
      }
      if (_year != null && m.year != _year) return false;
      if (query.isNotEmpty && !m.title.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList();

    list.sort((a, b) => b.rating.compareTo(a.rating));
    return list;
  }

  Future<void> _pickFilter(String kind) async {
    final repo = MovieRepositoryService.instance;
    final all = repo.getAllMovies();
    List<String> values;
    if (kind == 'Genre') {
      values = {
        for (final m in all)
          for (final g in m.genres)
            if (g.trim().isNotEmpty) g.trim(),
      }.toList()..sort();
    } else if (kind == 'Country') {
      values = {'India', 'Bangladesh', 'USA', 'UK', 'Japan', 'Korea'}
          .where(
            (c) => all.any(
              (m) => m.title.toLowerCase().contains(c.toLowerCase()),
            ),
          )
          .toList();
    } else {
      values = all.map((m) => m.year.toString()).toSet().toList()..sort();
    }
    if (values.isEmpty) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Choose $kind',
                style: TextStyle(
                  color: context.palette.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: values.length,
                itemBuilder: (context, index) {
                  final value = values[index];
                  final selected = switch (kind) {
                    'Genre' => _genre == value,
                    'Country' => _country == value,
                    _ => _year.toString() == value,
                  };
                  return ListTile(
                    title: Text(value),
                    selected: selected,
                    onTap: () => Navigator.of(context).pop(value),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      if (kind == 'Genre') _genre = picked;
      if (kind == 'Country') _country = picked;
      if (kind == 'Year') _year = int.tryParse(picked);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final movies = _movies;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.background,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: p.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: _searchOpen
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search movies',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                style: TextStyle(color: p.textPrimary, fontSize: 13),
              )
            : Text('Filter', style: TextStyle(color: p.textPrimary)),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: Icon(
              _searchOpen ? Icons.close_rounded : Icons.search_rounded,
              color: p.textPrimary,
            ),
            onPressed: () => setState(() {
              _searchOpen = !_searchOpen;
              if (!_searchOpen) _searchCtrl.clear();
            }),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: movies.isEmpty
                ? Center(
                    child: Text(
                      'No titles match these filters',
                      style: TextStyle(color: p.textSecondary, fontSize: 13),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      childAspectRatio: .56,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: movies.length,
                    itemBuilder: (context, index) {
                      final movie = movies[index];
                      return MovieCard(
                        key: ValueKey(movie.detailUrl),
                        movie: movie,
                        compact: true,
                        onTap: () => MovieDetailSheet.show(context, movie),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class OutlineButtonChip extends StatelessWidget {
  const OutlineButtonChip({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 3),
              Icon(Icons.expand_more_rounded, size: 14, color: p.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
