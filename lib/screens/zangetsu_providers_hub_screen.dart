import 'package:flutter/material.dart';

import '../models/movie_model.dart';
import '../services/movie_repository_service.dart';
import '../services/provider_engine/cloudstream_runtime.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../services/settings_service.dart';
import '../theme/app_palette.dart';
import '../widgets/remote_image.dart';
import 'movie_screen.dart';

enum _Section {
  cloudstream(
    'CloudStream Extensions',
    'Movies, Series, BDIX, Live TV, OTT',
    Icons.movie_filter_rounded,
    Color(0xFF10B981), // Emerald Green
  ),
  zangetsu(
    'Native JS Streaming Engines',
    'QuickJS Scrapers (Zangetsu & Mewtwo)',
    Icons.flash_on_rounded,
    Color(0xFFF59E0B), // Vivid Amber
  ),
  aniyomi(
    'Aniyomi Anime Extensions',
    'Anime Scrapers & Video Sources',
    Icons.animation_rounded,
    Color(0xFFEC4899), // Hot Pink
  ),
  mihon(
    'Mihon Extensions',
    'Manga, Manhwa & Comics (Keiyoushi)',
    Icons.menu_book_rounded,
    Color(0xFF3B82F6), // Sapphire Blue
  ),
  lnreader(
    'LNReader Plugins',
    'Light & Web Novel Chapter Readers',
    Icons.auto_stories_rounded,
    Color(0xFF8B5CF6), // Royal Violet
  ),
  adult(
    '18+ Extensions (Privacy Gated)',
    'Privacy-Gated 18+ Streaming Scrapers',
    Icons.lock_rounded,
    Color(0xFFEF4444), // Crimson Red
  );

  const _Section(this.label, this.description, this.icon, this.accentColor);
  final String label;
  final String description;
  final IconData icon;
  final Color accentColor;

  bool includes(MovieRepository repo) {
    if (this == adult) {
      return repo.isAdult ||
          repo.effectiveEcosystem == 'adult' ||
          repo.providers.any((p) => p.isAdult);
    }
    if (repo.isAdult || repo.effectiveEcosystem == 'adult') return false;
    return repo.effectiveEcosystem == name;
  }
}

/// Runs a full analysis/update pass for every repository ecosystem and shows
/// the outcome. Safe to tap repeatedly — the service de-duplicates runs.
Future<void> _runAnalysis(BuildContext context) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: SizedBox(
        height: 90,
        child: Center(child: CircularProgressIndicator()),
      ),
    ),
  );
  final result = await MovieRepositoryService.instance.analyzeAndUpdateAll();
  if (nav.canPop()) nav.pop();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(
        'Analyzed ${result.checked} repositories · '
        '${result.updated} updated · ${result.failed} offline',
      ),
    ),
  );
}

class ZangetsuProvidersHubScreen extends StatelessWidget {
  const ZangetsuProvidersHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = MovieRepositoryService.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Provider Hub',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.4),
        ),
        actions: [
          IconButton(
            tooltip: 'Analyze & update all repositories',
            icon: const Icon(Icons.analytics_outlined),
            onPressed: () => _runAnalysis(context),
          ),
        ],
      ),
      body: FutureBuilder(
        future: service.ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Could not load repositories.'));
          }
          if (snapshot.connectionState != ConnectionState.done &&
              service.repositories.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListenableBuilder(
            listenable: Listenable.merge([service, SettingsService.instance]),
            builder: (context, _) {
              final repos = service.repositories;
              final totalRepos = repos.length;
              final totalInstalled = repos
                  .expand((r) => r.providers)
                  .where((prov) => prov.isInstalled)
                  .length;

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                children: [
                  // Summary Banner
                  _HubHeaderCard(
                    totalRepos: totalRepos,
                    totalInstalled: totalInstalled,
                    onSync: () => _runAnalysis(context),
                  ),
                  const SizedBox(height: 16),

                  // Section List
                  for (final section in _Section.values)
                    if (section != _Section.adult ||
                        SettingsService.instance.showAdultRepositories) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _SectionCard(
                          section: section,
                          count: repos.where(section.includes).length,
                          installedCount: repos
                              .where(section.includes)
                              .expand((r) => r.providers)
                              .where((prov) => prov.isInstalled)
                              .length,
                        ),
                      ),
                    ],
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Header banner displaying live ecosystem summary metrics.
class _HubHeaderCard extends StatelessWidget {
  const _HubHeaderCard({
    required this.totalRepos,
    required this.totalInstalled,
    required this.onSync,
  });

  final int totalRepos;
  final int totalInstalled;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isDark = p.isDark;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161924) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? const Color(0x1FFFFFFF) : Colors.black.withValues(alpha: 0.06),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.04),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [p.primary, p.secondary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(13),
              boxShadow: [
                BoxShadow(
                  color: p.primary.withValues(alpha: 0.28),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Icon(Icons.hub_rounded, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Modular Media Engines',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: p.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$totalRepos Repositories · $totalInstalled Active Scrapers',
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: onSync,
            tooltip: 'Sync Repositories',
            style: IconButton.styleFrom(
              backgroundColor: p.primary.withValues(alpha: isDark ? 0.15 : 0.10),
              foregroundColor: p.primary,
            ),
            icon: const Icon(Icons.sync_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.section,
    required this.count,
    required this.installedCount,
  });

  final _Section section;
  final int count;
  final int installedCount;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final accent = section.accentColor;

    return _HubCard(
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => _RepositoryList(section: section)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // Vibrant Squircle Icon
              _HubIcon(icon: section.icon, color: accent),
              const SizedBox(width: 14),

              // Title and Description
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.label,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: p.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      section.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: p.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),

              // Trailing Count Badge & Active Tag
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: p.isDark ? 0.14 : 0.09),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: accent.withValues(alpha: p.isDark ? 0.28 : 0.18),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '$count ${count == 1 ? 'Repo' : 'Repos'}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: accent,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  if (installedCount > 0) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: p.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '$installedCount active',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: p.primary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: p.textSecondary.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HubCard extends StatelessWidget {
  const _HubCard({required this.child, this.isHighlighted = false});

  final Widget child;
  final bool isHighlighted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isDark = p.isDark;
    final radius = BorderRadius.circular(16);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161924) : Colors.white,
        borderRadius: radius,
        border: Border.all(
          color: isHighlighted
              ? p.primary
              : (isDark ? const Color(0x1FFFFFFF) : Colors.black.withValues(alpha: 0.06)),
          width: isHighlighted ? 1.6 : 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

class _HubIcon extends StatelessWidget {
  const _HubIcon({required this.icon, this.color});
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final effectiveColor = color ?? p.primary;

    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: p.isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: effectiveColor.withValues(alpha: p.isDark ? 0.28 : 0.20),
          width: 1,
        ),
      ),
      child: Icon(icon, color: effectiveColor, size: 23),
    );
  }
}

/// Distinct visual avatar or monogram for individual repositories.
class _RepoAvatar extends StatelessWidget {
  const _RepoAvatar({
    required this.repo,
    required this.accentColor,
  });

  final MovieRepository repo;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isOfficial = repo.id.toLowerCase().contains('official') ||
        repo.tags.any((t) => t.toLowerCase() == 'official');

    if (isOfficial) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [accentColor, accentColor.withValues(alpha: 0.75)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Center(
          child: Icon(Icons.verified_rounded, color: Colors.white, size: 22),
        ),
      );
    }

    final initials = _getInitials(repo.name);
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: p.isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: accentColor.withValues(alpha: p.isDark ? 0.28 : 0.18),
          width: 1,
        ),
      ),
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
            color: accentColor,
            fontWeight: FontWeight.w800,
            fontSize: 13.5,
            letterSpacing: -0.4,
          ),
        ),
      ),
    );
  }

  static String _getInitials(String name) {
    final words = name
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return 'RP';
    if (words.length == 1) {
      return words[0].substring(0, words[0].length.clamp(1, 2)).toUpperCase();
    }
    return (words[0][0] + words[1][0]).toUpperCase();
  }
}

class _RepositoryList extends StatefulWidget {
  const _RepositoryList({required this.section});
  final _Section section;

  @override
  State<_RepositoryList> createState() => _RepositoryListState();
}

class _RepositoryListState extends State<_RepositoryList> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openRepository(MovieRepository repo, {String? providerId}) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _Extensions(
          repoId: repo.id,
          adult: widget.section == _Section.adult,
          highlightedProviderId: providerId,
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    var input = '';
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add repository'),
        content: TextField(
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Manifest URL or shortcode',
          ),
          onChanged: (value) => input = value.trim(),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !context.mounted) return;
    final added = await MovieRepositoryService.instance.addCustomRepository(
      '',
      url,
      ecosystem: widget.section.name,
    );
    if (context.mounted && !added) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not add the repository.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final service = MovieRepositoryService.instance;
    final p = context.palette;
    final isDark = p.isDark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          section.label,
          style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
        actions: [
          IconButton(
            onPressed: () => _add(context),
            tooltip: 'Add repository',
            icon: const Icon(Icons.add_rounded),
          ),
          IconButton(
            tooltip: 'Analyze & update this section',
            icon: const Icon(Icons.analytics_outlined),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final result = await MovieRepositoryService.instance.analyzeAndUpdateAll(
                repoIds: MovieRepositoryService.instance.repositories
                    .where(section.includes)
                    .map((repo) => repo.id)
                    .toList(),
              );
              messenger.showSnackBar(
                SnackBar(
                  behavior: SnackBarBehavior.floating,
                  content: Text(
                    '${section.label}: ${result.updated} updated · '
                    '${result.failed} offline',
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Modern Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search repositories & scrapers…',
                hintStyle: TextStyle(
                  color: p.textSecondary.withValues(alpha: 0.7),
                  fontSize: 13.5,
                ),
                filled: true,
                fillColor: isDark ? const Color(0xFF161924) : const Color(0xFFF0F3F6),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: isDark ? const Color(0x1FFFFFFF) : Colors.black.withValues(alpha: 0.06),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: isDark ? const Color(0x1FFFFFFF) : Colors.black.withValues(alpha: 0.06),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: section.accentColor,
                    width: 1.5,
                  ),
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: p.textSecondary,
                  size: 20,
                ),
                suffixIcon: ValueListenableBuilder(
                  valueListenable: _search,
                  builder: (context, value, _) => value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: _search.clear,
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([service, SettingsService.instance]),
              builder: (context, _) => ValueListenableBuilder(
                valueListenable: _search,
                builder: (context, value, _) {
                  final repos = service.repositories
                      .where(section.includes)
                      .toList();
                  final query = value.text.trim().toLowerCase();
                  if (query.isNotEmpty) return _searchResults(repos, query);
                  if (repos.isEmpty) {
                    return Center(
                      child: Text(
                        'No repositories in this section.',
                        style: TextStyle(color: p.textSecondary),
                      ),
                    );
                  }
                  return _repositoryList(repos);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchResults(List<MovieRepository> repos, String query) {
    final adult = widget.section == _Section.adult;
    final results = [
      for (final repo in repos)
        for (final provider in repo.providers)
          if ((repo.isAdult || provider.isAdult) == adult &&
              provider.name.toLowerCase().contains(query))
            (repo: repo, provider: provider),
    ];
    if (results.isEmpty) {
      return Center(
        child: Text(
          'No extensions found.',
          style: TextStyle(color: context.palette.textSecondary),
        ),
      );
    }
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final result = results[index];
        return _HubCard(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            leading: ProviderLogo(provider: result.provider),
            title: Text(
              result.provider.name,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            subtitle: Text(
              result.repo.name,
              style: TextStyle(color: context.palette.textSecondary, fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => _openRepository(result.repo, providerId: result.provider.id),
          ),
        );
      },
    );
  }

  Widget _repositoryList(List<MovieRepository> repos) {
    final section = widget.section;
    final p = context.palette;
    final accent = section.accentColor;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      itemCount: repos.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final repo = repos[index];
        final installedInRepo = repo.providers.where((p) => p.isInstalled).length;

        return _HubCard(
          child: InkWell(
            onTap: () => _openRepository(repo),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  _RepoAvatar(repo: repo, accentColor: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                repo.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14.5,
                                  color: p.textPrimary,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ),
                            if (repo.shortcode.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: p.isDark ? 0.15 : 0.10),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: accent.withValues(alpha: p.isDark ? 0.28 : 0.18),
                                    width: 0.8,
                                  ),
                                ),
                                child: Text(
                                  repo.shortcode,
                                  style: TextStyle(
                                    color: accent,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 9.5,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (repo.author.isNotEmpty) ...[
                              Text(
                                '@${repo.author}',
                                style: TextStyle(
                                  color: p.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(' · ', style: TextStyle(color: p.textSecondary, fontSize: 11)),
                            ],
                            if (repo.tags.isNotEmpty) ...[
                              Text(
                                repo.tags.first,
                                style: TextStyle(
                                  color: p.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(' · ', style: TextStyle(color: p.textSecondary, fontSize: 11)),
                            ],
                            Text(
                              '${repo.actualProviderCount} ext',
                              style: TextStyle(
                                color: p.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (installedInRepo > 0) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: p.primary.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 5,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        color: p.primary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '$installedInRepo installed',
                                      style: TextStyle(
                                        color: p.primary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: p.textSecondary.withValues(alpha: 0.5),
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Extensions extends StatefulWidget {
  const _Extensions({
    required this.repoId,
    required this.adult,
    this.highlightedProviderId,
  });
  final String? highlightedProviderId;
  final String repoId;
  final bool adult;

  @override
  State<_Extensions> createState() => _ExtensionsState();
}

class _ExtensionsState extends State<_Extensions> {
  final _service = MovieRepositoryService.instance;
  final _pending = <String>{};
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    var ok = false;
    try {
      ok = await _service.refreshRepository(widget.repoId);
    } catch (_) {
      // Keep cached extensions available
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _failed = !ok;
      });
    }
  }

  Future<void> _deleteRepository(MovieRepository repo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete repository?'),
        content: Text(
          'Remove ${repo.name} and its extensions from Provider Hub?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.deleteRepository(repo.id);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete the repository.')),
        );
      }
    }
  }

  Future<void> _changeInstallation(MovieProvider provider) async {
    setState(() => _pending.add(provider.id));
    try {
      if (provider.isInstalled) {
        await _service.uninstallExtension(widget.repoId, provider.id);
      } else {
        await ProviderEngineService.instance.installExtension(
          widget.repoId,
          provider.id,
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Could not complete the extension change. $error'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pending.remove(provider.id));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) {
      final pal = context.palette;
      final repo = _service.repositories
          .where((r) => r.id == widget.repoId)
          .firstOrNull;
      if (repo == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('Repository unavailable.')),
        );
      }
      final providers = repo.providers
          .where((p) => (repo.isAdult || p.isAdult) == widget.adult)
          .toList();
      final highlightedIndex = providers.indexWhere(
        (p) => p.id == widget.highlightedProviderId,
      );
      if (highlightedIndex > 0) {
        providers.insert(0, providers.removeAt(highlightedIndex));
      }

      final installedCount = providers.where((p) => p.isInstalled).length;

      return Scaffold(
        appBar: AppBar(
          title: Text(
            repo.name,
            style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.3),
          ),
          actions: [
            IconButton(
              onPressed: _loading ? null : _refresh,
              tooltip: 'Refresh extensions',
              icon: const Icon(Icons.refresh_rounded),
            ),
            PopupMenuButton<String>(
              tooltip: 'Manage repository',
              onSelected: (action) async {
                if (action == 'delete') {
                  await _deleteRepository(repo);
                } else {
                  await _service.toggleRepository(repo.id, !repo.isEnabled);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(
                    repo.isEnabled ? 'Disable repository' : 'Enable repository',
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete repository'),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_failed)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: pal.critical.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off_outlined, color: pal.critical, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Could not refresh extensions manifest',
                        style: TextStyle(color: pal.critical, fontSize: 12.5),
                      ),
                    ),
                    TextButton(
                      onPressed: _refresh,
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),

            // Overview Header
            if (providers.isNotEmpty)
              _buildRepoHeader(repo, providers.length, installedCount),

            Expanded(
              child: providers.isEmpty
                  ? Center(
                      child: Text(
                        _loading || _failed ? '' : 'No extensions listed.',
                        style: TextStyle(color: pal.textSecondary),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: providers.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final p = providers[index];
                        final supported = CloudStreamRuntime.canRun(p);
                        final pending = _pending.contains(p.id);
                        return _buildProviderTile(
                          context,
                          repo,
                          p,
                          supported,
                          pending,
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );

  Widget _buildRepoHeader(MovieRepository repo, int total, int installed) {
    final pal = context.palette;
    final isDark = pal.isDark;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161924) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0x1FFFFFFF) : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.widgets_rounded, color: pal.primary, size: 18),
          const SizedBox(width: 8),
          Text(
            '$total Available',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: pal.textPrimary,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: pal.textSecondary.withValues(alpha: 0.4),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Icon(
            Icons.check_circle_outline_rounded,
            color: installed > 0 ? pal.primary : pal.textSecondary,
            size: 16,
          ),
          const SizedBox(width: 6),
          Text(
            '$installed Installed',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: installed > 0 ? pal.primary : pal.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderTile(
    BuildContext context,
    MovieRepository repo,
    MovieProvider p,
    bool supported,
    bool pending,
  ) {
    final pal = context.palette;
    final isDark = pal.isDark;
    final accent = pal.primary;

    return _HubCard(
      isHighlighted: p.id == widget.highlightedProviderId,
      child: InkWell(
        onTap: p.isInstalled && p.isEnabled && repo.isEnabled && supported
            ? () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MovieScreen(
                      initialRepoId: repo.id,
                      initialProviderId: p.id,
                    ),
                  ),
                )
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              ProviderLogo(provider: p),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: pal.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (p.language.trim().isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : Colors.black.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              p.language.toUpperCase(),
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: pal.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        if (p.version.trim().isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : Colors.black.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              'v${p.version}',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: pal.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        if (!supported)
                          Text(
                            'Unsupported',
                            style: TextStyle(
                              fontSize: 11,
                              color: pal.critical,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),

              // Action Area
              if (pending)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Working…',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                    ],
                  ),
                )
              else if (p.isInstalled)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                      decoration: BoxDecoration(
                        color: pal.primary.withValues(alpha: isDark ? 0.16 : 0.10),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: pal.primary.withValues(alpha: isDark ? 0.35 : 0.25),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_rounded, size: 14, color: pal.primary),
                          const SizedBox(width: 4),
                          Text(
                            'Installed',
                            style: TextStyle(
                              color: pal.primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        color: pal.critical,
                        size: 19,
                      ),
                      tooltip: 'Delete',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _changeInstallation(p),
                    ),
                  ],
                )
              else
                Tooltip(
                  message: supported
                      ? 'Install ${p.name}'
                      : 'Extension runtime unavailable',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: supported ? () => _changeInstallation(p) : null,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6.5),
                        decoration: BoxDecoration(
                          color: supported
                              ? accent.withValues(alpha: isDark ? 0.15 : 0.10)
                              : (isDark
                                  ? Colors.white.withValues(alpha: 0.05)
                                  : Colors.black.withValues(alpha: 0.04)),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: supported
                                ? accent.withValues(alpha: isDark ? 0.35 : 0.25)
                                : Colors.transparent,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.download_rounded,
                              size: 15,
                              color: supported ? accent : pal.disabledText,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Install',
                              style: TextStyle(
                                color: supported ? accent : pal.disabledText,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
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

class ProviderLogo extends StatelessWidget {
  const ProviderLogo({super.key, required this.provider});
  final MovieProvider provider;

  @override
  Widget build(BuildContext context) {
    final pal = context.palette;
    final isDark = pal.isDark;
    final color = pal.primary;
    final url = provider.iconUrl.trim();

    if (url.isEmpty || url.toLowerCase().endsWith('.ico')) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.14 : 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color.withValues(alpha: isDark ? 0.28 : 0.18),
            width: 1,
          ),
        ),
        child: Center(
          child: Text(
            SmartNetworkImage.initialsFor(provider.name),
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
    }

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E2B) : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0x22FFFFFF) : Colors.black.withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SmartNetworkImage(
            url: url,
            width: 36,
            height: 36,
            fit: BoxFit.contain,
            borderRadius: BorderRadius.circular(8),
            fallbackInitials: SmartNetworkImage.initialsFor(provider.name),
            placeholderColor: color.withValues(alpha: .12),
            accentColor: color,
          ),
        ),
      ),
    );
  }
}
