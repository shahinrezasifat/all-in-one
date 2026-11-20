import 'package:flutter/material.dart';
import '../models/video_item.dart';
import '../services/search_service.dart';
import '../theme/app_colors.dart';
import '../widgets/video_card.dart';

class ExploreScreen extends StatefulWidget {
  final String? initialQuery;

  const ExploreScreen({super.key, this.initialQuery});

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
            color: isDark ? AppColors.darkCard : AppColors.lightCard,
            borderRadius: BorderRadius.circular(14),
          ),
          child: TextField(
            controller: _searchCtrl,
            autofocus: false,
            decoration: InputDecoration(
              hintText: 'Search YouTube, Music, Videos...',
              prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary, size: 20),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
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
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: _onQueryChanged,
            onSubmitted: _performSearch,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _performSearch(_searchCtrl.text),
            child: const Text('Search', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Main results or popular tags
          if (_isLoading)
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: AppColors.primary),
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
                  const Icon(Icons.search_off_rounded, size: 64, color: AppColors.primary),
                  const SizedBox(height: 16),
                  Text(
                    'No videos found for "${_searchCtrl.text}"',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  const Text('Try different keywords or paste a direct video link.'),
                ],
              ),
            )
          else if (_searchResults.isNotEmpty)
            ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _searchResults.length + 1,
              itemBuilder: (context, index) {
                if (index == _searchResults.length) {
                  return const SizedBox(height: 80);
                }
                final video = _searchResults[index];
                return VideoCard(video: video);
              },
            )
          else
            // Popular Discover Tags
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Popular Searches',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 10,
                  children: _popularTags.map((tag) {
                    return ActionChip(
                      label: Text(tag),
                      avatar: const Icon(Icons.trending_up, size: 16, color: AppColors.primary),
                      backgroundColor: isDark ? AppColors.darkCard : Colors.grey.shade200,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      onPressed: () {
                        _searchCtrl.text = tag;
                        _performSearch(tag);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Explore by Platform',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                _buildPlatformCard('YouTube Trending', Icons.video_collection_rounded, AppColors.accentRed, () {
                  _performSearch('Trending YouTube');
                }, isDark),
                const SizedBox(height: 10),
                _buildPlatformCard('TikTok Viral Sounds', Icons.music_note_rounded, AppColors.accentGold, () {
                  _performSearch('Viral TikTok Sounds');
                }, isDark),
                const SizedBox(height: 10),
                _buildPlatformCard('Hi-Fi Audio Search', Icons.headphones_rounded, AppColors.accentGreen, () {
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
                  color: isDark ? AppColors.darkCard : AppColors.lightCard,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    )
                  ],
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _suggestions.length.clamp(0, 8),
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                  ),
                  itemBuilder: (context, index) {
                    final s = _suggestions[index];
                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.history_rounded, size: 18, color: Colors.grey),
                        title: Text(s, style: const TextStyle(fontSize: 14)),
                        trailing: const Icon(Icons.north_west_rounded, size: 16, color: Colors.grey),
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

  Widget _buildPlatformCard(String title, IconData icon, Color color, VoidCallback onTap, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          onTap: onTap,
          leading: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
        ),
      ),
    );
  }
}
