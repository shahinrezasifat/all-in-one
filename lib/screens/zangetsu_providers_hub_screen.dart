import 'package:flutter/material.dart';
import '../theme/app_palette.dart';

import '../models/movie_model.dart';
import '../services/movie_repository_service.dart';
import '../services/provider_engine/cloudstream_runtime.dart';
import '../services/provider_engine/provider_engine_service.dart';
import '../services/settings_service.dart';
import '../widgets/remote_image.dart';
import 'movie_screen.dart';

enum _Section {
  cloudstream(
    'CloudStream Extensions',
    'Movies, Series, BDIX, Live TV, OTT',
    Icons.movie_filter_rounded,
    0,
  ),
  zangetsu(
    'Native JS Streaming Engines',
    'QuickJS Scrapers (Zangetsu & Mewtwo)',
    Icons.flash_on_rounded,
    1,
  ),
  aniyomi(
    'Aniyomi Anime Extensions',
    'Anime Scrapers & Video Sources',
    Icons.animation_rounded,
    2,
  ),
  mihon(
    'Mihon Extensions',
    'Manga, Manhwa & Comics (Keiyoushi)',
    Icons.menu_book_rounded,
    3,
  ),
  lnreader(
    'LNReader Plugins',
    'Light & Web Novel Chapter Readers',
    Icons.auto_stories_rounded,
    4,
  ),
  adult(
    '18+ Extensions (Privacy Gated)',
    'Privacy-Gated 18+ Streaming Scrapers',
    Icons.lock_rounded,
    5,
  );

  _Section(this.label, this.description, this.icon, this.accentRole);
  final String label;
  final String description;
  final IconData icon;
  final int accentRole;

  /// Role-based accent — resolved through the mode-aware palette, never a
  /// hardcoded ecosystem hex.
  Color get accentColor {
    final p = contextlessPalette;
    return switch (accentRole) {
      0 => p.primary,
      1 => p.secondary,
      2 => p.success,
      3 => p.textPrimary,
      4 => p.textSecondary,
      _ => p.border,
    };
  }

  static AppPalette get contextlessPalette => AppPalette.current;

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

class ZangetsuProvidersHubScreen extends StatelessWidget {
  ZangetsuProvidersHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = MovieRepositoryService.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Provider Hub',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: FutureBuilder(
        future: service.ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Could not load repositories.'));
          }
          if (snapshot.connectionState != ConnectionState.done &&
              service.repositories.isEmpty) {
            return Center(child: CircularProgressIndicator());
          }
          return ListenableBuilder(
            listenable: Listenable.merge([service, SettingsService.instance]),
            builder: (context, _) => ListView(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                for (final section in _Section.values)
                  if (section != _Section.adult ||
                      SettingsService.instance.showAdultRepositories)
                    Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: _SectionCard(
                        section: section,
                        count: service.repositories
                            .where(section.includes)
                            .length,
                      ),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  _SectionCard({required this.section, required this.count});

  final _Section section;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _HubCard(
      child: ListTile(
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        leading: _HubIcon(icon: section.icon, color: section.accentColor),
        title: Text(
          section.label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          '${section.description}\n$count ${count == 1 ? 'repository' : 'repositories'}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        trailing: Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => _RepositoryList(section: section)),
        ),
      ),
    );
  }
}

class _HubCard extends StatelessWidget {
  _HubCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(18);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: context.palette.shadowAt(isDark ? .16 : .05),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colors.surfaceContainerHighest.withValues(alpha: .58),
                colors.surface.withValues(alpha: .90),
              ],
            ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _HubIcon extends StatelessWidget {
  _HubIcon({required this.icon, this.color});
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: effectiveColor, size: 24),
    );
  }
}

class _RepositoryList extends StatefulWidget {
  _RepositoryList({required this.section});
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
        title: Text('Add repository'),
        content: TextField(
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: 'Manifest URL or shortcode',
          ),
          onChanged: (value) => input = value.trim(),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input),
            child: Text('Add'),
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
        SnackBar(content: Text('Could not add the repository.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final service = MovieRepositoryService.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(section.label),
        actions: [
          IconButton(
            onPressed: () => _add(context),
            tooltip: 'Add repository',
            icon: Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search extensions',
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                  borderSide: BorderSide.none,
                ),
                prefixIcon: Icon(Icons.search_rounded),
                suffixIcon: ValueListenableBuilder(
                  valueListenable: _search,
                  builder: (context, value, _) => value.text.isEmpty
                      ? SizedBox.shrink()
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: _search.clear,
                          icon: Icon(Icons.close_rounded),
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
                      child: Text('No repositories in this section.'),
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
      return Center(child: Text('No extensions found.'));
    }
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: results.length,
      separatorBuilder: (_, _) => SizedBox(height: 8),
      itemBuilder: (context, index) {
        final result = results[index];
        return _HubCard(
          child: ListTile(
            leading: ProviderLogo(provider: result.provider),
            title: Text(result.provider.name),
            subtitle: Text(result.repo.name),
            trailing: Icon(Icons.chevron_right_rounded),
            onTap: () =>
                _openRepository(result.repo, providerId: result.provider.id),
          ),
        );
      },
    );
  }

  Widget _repositoryList(List<MovieRepository> repos) {
    final section = widget.section;
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: repos.length,
      separatorBuilder: (_, _) => SizedBox(height: 8),
      itemBuilder: (context, index) {
        final repo = repos[index];
        return _HubCard(
          child: ListTile(
            contentPadding: EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 4,
            ),
            leading: _HubIcon(icon: section.icon, color: section.accentColor),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    repo.name,
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (repo.shortcode.isNotEmpty)
                  Container(
                    margin: EdgeInsets.only(left: 6),
                    padding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: section.accentColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      repo.shortcode,
                      style: TextStyle(
                        color: section.accentColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '${repo.author}${repo.tags.isNotEmpty ? " • " + repo.tags.first : ""} • ${repo.actualProviderCount} extensions',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12),
              ),
            ),
            trailing: Icon(Icons.chevron_right_rounded),
            onTap: () => _openRepository(repo),
          ),
        );
      },
    );
  }
}

class _Extensions extends StatefulWidget {
  _Extensions({
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
      // Keep any cached extensions available.
    }
    if (mounted)
      setState(() {
        _loading = false;
        _failed = !ok;
      });
  }

  Future<void> _deleteRepository(MovieRepository repo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete repository?'),
        content: Text(
          'Remove ${repo.name} and its extensions from Provider Hub?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Delete'),
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
          SnackBar(content: Text('Could not delete the repository.')),
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
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not complete the extension change. $error'),
          ),
        );
    } finally {
      if (mounted) setState(() => _pending.remove(provider.id));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) {
      final repo = _service.repositories
          .where((r) => r.id == widget.repoId)
          .firstOrNull;
      if (repo == null) {
        return Scaffold(
          appBar: AppBar(),
          body: Center(child: Text('Repository unavailable.')),
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
      return Scaffold(
        appBar: AppBar(
          title: Text(repo.name),
          actions: [
            IconButton(
              onPressed: _loading ? null : _refresh,
              tooltip: 'Refresh extensions',
              icon: Icon(Icons.refresh_rounded),
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
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete repository'),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loading) LinearProgressIndicator(),
            if (_failed)
              ListTile(
                leading: Icon(Icons.cloud_off_outlined),
                title: Text('Could not refresh extensions'),
                trailing: TextButton(
                  onPressed: _refresh,
                  child: Text('Retry'),
                ),
              ),
            Expanded(
              child: providers.isEmpty
                  ? Center(
                      child: Text(
                        _loading || _failed ? '' : 'No extensions listed.',
                      ),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: providers.length,
                      separatorBuilder: (_, _) => SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final p = providers[index];
                        final supported = CloudStreamRuntime.canRun(p);
                        final pending = _pending.contains(p.id);
                        final metadata = [
                          if (p.language.trim().isNotEmpty)
                            p.language.toUpperCase(),
                          if (p.version.trim().isNotEmpty) 'v${p.version}',
                        ].join(' · ');
                        final status = !supported
                            ? 'In-app runtime required'
                            : p.isInstalled
                            ? 'Installed'
                            : metadata;
                        return _HubCard(
                          child: ListTile(
                            selected: p.id == widget.highlightedProviderId,
                            onTap: p.isInstalled && p.isEnabled && repo.isEnabled && supported
                                ? () => Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => MovieScreen(
                                      initialRepoId: repo.id,
                                      initialProviderId: p.id,
                                    ),
                                  ))
                                : null,
                            leading: ProviderLogo(provider: p),
                            title: Text(
                              p.name,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: status.isEmpty
                                ? null
                                : Text(
                                    status,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                            trailing: pending
                                ? SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : p.isInstalled
                                ? TextButton(
                                    onPressed: () => _changeInstallation(p),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                    child: Text('Delete'),
                                  )
                                : Tooltip(
                                    message: supported
                                        ? 'Install ${p.name}'
                                        : 'Extension runtime unavailable',
                                    child: FilledButton.tonal(
                                      onPressed: supported
                                          ? () => _changeInstallation(p)
                                          : null,
                                      child: Text('Install'),
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}

class ProviderLogo extends StatelessWidget {
  ProviderLogo({super.key, required this.provider});
  final MovieProvider provider;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SmartNetworkImage(
      url: provider.iconUrl,
      width: 40,
      height: 40,
      fit: BoxFit.contain,
      borderRadius: BorderRadius.circular(10),
      fallbackInitials: SmartNetworkImage.initialsFor(provider.name),
      placeholderColor: color.withValues(alpha: .12),
      accentColor: color,
    );
  }
}
