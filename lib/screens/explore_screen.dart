import 'package:flutter/material.dart';
import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/preference_service.dart';
import '../services/speech_service.dart';
import '../services/movie_repository_service.dart';
import '../theme/app_palette.dart';
import '../widgets/video_card.dart';

class ExploreScreen extends StatefulWidget {
  final String? initialQuery;

  ExploreScreen({super.key, this.initialQuery});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<String> _suggestions = [];
  List<VideoItem> _searchResults = [];
  bool _isLoading = false;
  bool _hasSearched = false;

  final List<String> _popularTags = [
    'Music Hits 2026', 'Alan Walker', 'Trending Shorts', 'Gaming Highlights',
    'Anime Remastered', '4K Nature 60fps', 'Podcast', 'Tech Reviews'
  ];

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _searchCtrl.text = widget.initialQuery!;
      _performSearch(widget.initialQuery!);
    }
  }

  Future<void> _onQueryChanged(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _suggestions = [];
      });
      return;
    }
    final sugg = await SearchService.instance.getSearchSuggestions(query);
    if (mounted) {
      setState(() {
        _suggestions = sugg;
      });
    }
  }

  Future<void> _performSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;

    setState(() {
      _isLoading = true;
      _hasSearched = true;
      _suggestions = [];
    });

    final results = await SearchService.instance.searchVideos(q);

    if (mounted) {
      setState(() {
        _searchResults = results;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Container(
          height: 44,
          decoration: BoxDecoration(
            color: context.palette.card,
            borderRadius: BorderRadius.circular(14),
          ),
          child: TextField(
            controller: _searchCtrl,
            autofocus: false,
            decoration: InputDecoration(
              hintText: 'Search YouTube, Music, Videos...',
              prefixIcon: Icon(Icons.search_rounded, color: context.palette.primary, size: 20),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() {
                          _searchResults = [];
                          _suggestions = [];
                          _hasSearched = false;
                        });
                      },
                    )
                  : null,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: _onQueryChanged,
            onSubmitted: _performSearch,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Voice search',
            icon: Icon(Icons.mic_rounded, color: context.palette.primary),
            onPressed: () async {
              final spoken = await SpeechService.instance.recognize();
              if (spoken == null || spoken.isEmpty || !mounted) return;
              _searchCtrl.text = spoken;
              _performSearch(spoken);
            },
          ),
          TextButton(
            onPressed: () => _performSearch(_searchCtrl.text),
            child: Text('Search', style: TextStyle(color: context.palette.primary, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Main results or popular tags
          if (_isLoading)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: context.palette.primary),
                  SizedBox(height: 16),
                  Text('Searching high quality streams...'),
                ],
              ),
            )
          else if (_hasSearched && _searchResults.isEmpty)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search_off_rounded, size: 64, color: context.palette.primary),
                  SizedBox(height: 16),
                  Text(
                    'No videos found for "${_searchCtrl.text}"',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  SizedBox(height: 8),
                  Text('Try different keywords or paste a direct video link.'),
                ],
              ),
            )
          else if (_searchResults.isNotEmpty)
            ListView.builder(
              padding: EdgeInsets.all(16),
              itemCount: _searchResults.length + 1,
              itemBuilder: (context, index) {
                if (index == _searchResults.length) {
                  return SizedBox(height: 80);
                }
                final video = _searchResults[index];
                return VideoCard(video: video);
              },
            )
          else
            // Popular Discover Tags
            ListView(
              padding: EdgeInsets.all(16),
              children: [
                _buildRecentSearches(),
                SizedBox(height: 20),
                _buildEveryoneSearching(),
                SizedBox(height: 20),
                _buildHotMovies(isDark),
                SizedBox(height: 24),
                Text(
                  'Popular Searches',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 10,
                  children: _popularTags.map((tag) {
                    return ActionChip(
                      label: Text(tag),
                      avatar: Icon(Icons.trending_up, size: 16, color: context.palette.primary),
                      backgroundColor: context.palette.card,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      onPressed: () {
                        _searchCtrl.text = tag;
                        _performSearch(tag);
                      },
                    );
                  }).toList(),
                ),
                SizedBox(height: 24),
                Text(
                  'Explore by Platform',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 12),
                _buildPlatformCard('YouTube Trending', Icons.video_collection_rounded, context.palette.error, () {
                  _performSearch('Trending YouTube');
                }, isDark),
                SizedBox(height: 10),
                _buildPlatformCard('TikTok Viral Sounds', Icons.music_note_rounded, context.palette.info, () {
                  _performSearch('Viral TikTok Sounds');
                }, isDark),
                SizedBox(height: 10),
                _buildPlatformCard('Hi-Fi Audio Search', Icons.headphones_rounded, context.palette.success, () {
                  _performSearch('official audio high quality');
                }, isDark),
              ],
            ),

          // Auto-suggestions Overlay
          if (_suggestions.isNotEmpty)
            Positioned(
              top: 0,
              left: 16,
              right: 16,
              child: Container(
                decoration: BoxDecoration(
                  color: context.palette.card,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: context.palette.shadowAt(0.3),
                      blurRadius: 20,
                      offset: Offset(0, 10),
                    )
                  ],
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.symmetric(vertical: 8),
                  itemCount: _suggestions.length.clamp(0, 8),
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    color: context.palette.border,
                  ),
                  itemBuilder: (context, index) {
                    final s = _suggestions[index];
                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.history_rounded, size: 18, color: context.palette.textSecondary),
                        title: Text(s, style: TextStyle(fontSize: 14)),
                        trailing: Icon(Icons.north_west_rounded, size: 16, color: context.palette.textSecondary),
                        onTap: () {
                          _searchCtrl.text = s;
                          _performSearch(s);
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRecentSearches() {
    final recent = PreferenceService.instance.recentVideoSearches.take(6).toList();
    if (recent.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Recent', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            TextButton(
              onPressed: () => setState(
                () => PreferenceService.instance.clearRecentSearches(),
              ),
              child: Text('Clear', style: TextStyle(color: p.textSecondary, fontSize: 12)),
            ),
          ],
        ),
        SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final term in recent)
              ActionChip(
                label: Text(term, style: TextStyle(fontSize: 11)),
                backgroundColor: p.card,
                onPressed: () {
                  _searchCtrl.text = term;
                  _performSearch(term);
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildEveryoneSearching() {
    final terms = [
      'The Wheel of Time',
      'Bridgerton',
      'Naruto: Shippuden',
      'Shadow and Bone',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '🔥 Everyone is searching',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final term in terms)
              ActionChip(
                label: Text(term, style: TextStyle(fontSize: 11)),
                backgroundColor: context.palette.card,
                onPressed: () {
                  _searchCtrl.text = term;
                  _performSearch(term);
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildHotMovies(bool isDark) {
    final movies = MovieRepositoryService.instance.getAllMovies()
      ..sort((a, b) => b.rating.compareTo(a.rating));
    final top = movies.take(5).toList();
    if (top.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('📈 Hot Movies', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        SizedBox(height: 10),
        SizedBox(
          height: 76,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: top.length,
            separatorBuilder: (_, __) => SizedBox(width: 10),
            itemBuilder: (context, index) {
              final movie = top[index];
              return Container(
                width: 220,
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: p.card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: index == 0 ? p.primary : p.selectedBg,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Center(
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            color: index == 0 ? p.onPrimary : p.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            movie.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '⭐ ${movie.rating} · ${movie.year} · ${movie.genres.take(2).join(', ')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: p.textSecondary, fontSize: 10),
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

  Widget _buildPlatformCard(String title, IconData icon, Color color, VoidCallback onTap, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          onTap: onTap,
          leading: Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          title: Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          trailing: Icon(Icons.chevron_right_rounded, color: context.palette.textSecondary),
        ),
      ),
    );
  }
}
