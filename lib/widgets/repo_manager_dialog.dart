import 'package:flutter/material.dart';
import '../models/movie_model.dart';
import '../services/movie_repository_service.dart';
import '../theme/app_palette.dart';

class RepoManagerDialog extends StatefulWidget {
  RepoManagerDialog({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => RepoManagerDialog(),
    );
  }

  @override
  State<RepoManagerDialog> createState() => _RepoManagerDialogState();
}

class _RepoManagerDialogState extends State<RepoManagerDialog> {
  final TextEditingController _searchRepoCtrl = TextEditingController();
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();
  String _filterQuery = '';
  bool _isAdding = false;

  final List<Map<String, String>> _popularRepoPresets = [
    {
      'name': "Redowan's BDIX Repository",
      'url': 'cloudstreamrepo://raw.githubusercontent.com/redowan99/Redowan-CloudStream/master/repo.json',
      'icon': '🇧🇩',
    },
    {
      'name': 'Phisher Repo',
      'url': 'cloudstreamrepo://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
      'icon': '⚡',
    },
    {
      'name': 'Megix Repo / CSX',
      'url': 'cloudstreamrepo://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json',
      'icon': '🇮🇳',
    },
    {
      'name': 'IndoStream Repo',
      'url': 'cloudstreamrepo://raw.githubusercontent.com/TeKuma25/IndoStream/builds/repo.json',
      'icon': '🇮🇩',
    },
    {
      'name': 'CloudStream Providers Repository',
      'url': 'cloudstreamrepo://raw.githubusercontent.com/recloudstream/extensions/master/repo.json',
      'icon': '☁️',
    },
    {
      'name': 'Mega Repository',
      'url': 'cloudstreamrepo://raw.githubusercontent.com/self-similarity/MegaRepo/builds/repo.json',
      'icon': '🚀',
    },
    {
      'name': 'Netmirror Repo',
      'url': 'cloudstreamrepo://raw.githubusercontent.com/Sushan64/NetMirror-Extension/refs/heads/builds/Netflix.json',
      'icon': '🍿',
    },
    {
      'name': 'Spotiflac Official Extension',
      'url': 'https://raw.githubusercontent.com/spotiflacapp/spotiflac-extension/main/registry.json',
      'icon': '🎵',
    },
    {
      'name': 'Zarzet Spotiflac Extension',
      'url': 'https://raw.githubusercontent.com/zarzet/spotiflac-extension/main/registry.json',
      'icon': '🎧',
    },
    {
      'name': 'Soundbound Experimental Sources',
      'url': 'https://gitlab.com/shabinder/soundbound/-/raw/main/Experimental-Sources/sources.json',
      'icon': '🧪',
    },
    {
      'name': 'Soundbound Private Extensions',
      'url': 'https://soundbound.app/sources/private-extensions.json',
      'icon': '🔒',
    },
  ];

  @override
  void dispose() {
    _searchRepoCtrl.dispose();
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _processAddRepository(String nameInput, String urlInput, BuildContext dialogCtx) async {
    final input = urlInput.trim();
    if (input.isEmpty) return;

    final name = nameInput.trim();
    Navigator.pop(dialogCtx);
    setState(() => _isAdding = true);

    final success = await MovieRepositoryService.instance.addCustomRepository(name, input);

    if (mounted) {
      setState(() => _isAdding = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Repository "$input" added successfully!' : 'Failed to parse repository URL or JSON.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: success ? context.palette.success : context.palette.error,
        ),
      );
    }
  }

  void _showAddCustomDialog() {
    _nameCtrl.clear();
    _urlCtrl.clear();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.add_box_rounded, color: context.palette.primary),
            SizedBox(width: 8),
            Text('Add Repository or Shortcode', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter SpotiFlac, Cloudstream, or Dantotsu registry URL or shortcode.',
                style: TextStyle(fontSize: 12, color: context.palette.onPrimary),
              ),
              SizedBox(height: 14),

              // Quick Presets
              Text(
                'Top Verified Repositories:',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.palette.primary),
              ),
              SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _popularRepoPresets.map((preset) {
                  return ActionChip(
                    avatar: Text(preset['icon']!, style: TextStyle(fontSize: 12)),
                    label: Text(preset['name']!),
                    labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    backgroundColor: context.palette.tint(context.palette.primary, 0.12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onPressed: () {
                      _nameCtrl.text = preset['name']!;
                      _urlCtrl.text = preset['url']!;
                    },
                  );
                }).toList(),
              ),

              SizedBox(height: 14),

              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: 'Repository Name (Optional)',
                  hintText: 'e.g. SpotiFlac Flac Audio Repo',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: Icon(Icons.label_outline_rounded),
                ),
              ),
              SizedBox(height: 10),
              TextField(
                controller: _urlCtrl,
                decoration: InputDecoration(
                  labelText: 'Repo URL / Registry Link *',
                  hintText: 'https://raw.githubusercontent.com/.../registry.json',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: Icon(Icons.link_rounded),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.palette.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => _processAddRepository(_nameCtrl.text, _urlCtrl.text, ctx),
            child: Text('Add Repository', style: TextStyle(fontWeight: FontWeight.bold, color: context.palette.onPrimary)),
          ),
        ],
      ),
    );
  }

  void _showEditRepoDialog(MovieRepository repo) {
    _nameCtrl.text = repo.name;
    _urlCtrl.text = repo.url;
    _descCtrl.text = repo.description;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.edit_note_rounded, color: context.palette.info),
            SizedBox(width: 8),
            Text('Edit Repository', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: 'Repository Name',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              SizedBox(height: 10),
              TextField(
                controller: _urlCtrl,
                decoration: InputDecoration(
                  labelText: 'Repository URL',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              SizedBox(height: 10),
              TextField(
                controller: _descCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: context.palette.primary),
            onPressed: () {
              MovieRepositoryService.instance.editRepository(
                repo.id,
                name: _nameCtrl.text.trim(),
                url: _urlCtrl.text.trim(),
                description: _descCtrl.text.trim(),
              );
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Repository updated successfully!'), behavior: SnackBarBehavior.floating),
              );
            },
            child: Text('Save Changes', style: TextStyle(fontWeight: FontWeight.bold, color: context.palette.background)),
          ),
        ],
      ),
    );
  }

  void _showProvidersDialog(MovieRepository repo) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final currentRepo = MovieRepositoryService.instance.repositories.firstWhere(
              (r) => r.id == repo.id,
              orElse: () => repo,
            );

            return Container(
              height: MediaQuery.of(context).size.height * 0.78,
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: context.palette.card,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              currentRepo.name,
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: 2),
                            Text(
                              '${currentRepo.activeProviderCount} of ${currentRepo.actualProviderCount} Extensions Installed (মোট ${currentRepo.actualProviderCount}টি এক্সটেনশন)',
                              style: TextStyle(fontSize: 12, color: context.palette.primary, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  Divider(),
                  SizedBox(height: 6),
                  Expanded(
                    child: currentRepo.providers.isEmpty
                        ? Center(
                            child: Text('No extensions indexed for this repository yet.'),
                          )
                        : ListView.separated(
                            itemCount: currentRepo.providers.length,
                            separatorBuilder: (_, _) => SizedBox(height: 8),
                            itemBuilder: (context, idx) {
                              final provider = currentRepo.providers[idx];
                              final isInstalled = provider.isInstalled && provider.isEnabled;
                              return Container(
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isDark ? context.palette.background : context.palette.textSecondary,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                                      decoration: BoxDecoration(
                                        color: isInstalled
                                            ? context.palette.tint(context.palette.primary, 0.15)
                                            : context.palette.tint(context.palette.textSecondary, 0.2),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        provider.language.toUpperCase(),
                                        style: TextStyle(
                                          color: isInstalled ? context.palette.primary : context.palette.textSecondary,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  provider.name,
                                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              SizedBox(width: 6),
                                              Container(
                                                padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                decoration: BoxDecoration(
                                                  color: isInstalled
                                                      ? context.palette.tint(context.palette.success, 0.15)
                                                      : context.palette.tint(context.palette.textSecondary, 0.15),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  isInstalled ? 'Installed' : 'Uninstalled',
                                                  style: TextStyle(
                                                    color: isInstalled ? context.palette.success : context.palette.textSecondary,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (provider.description.isNotEmpty) ...[
                                            SizedBox(height: 2),
                                            Text(
                                              provider.description,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(fontSize: 11, color: context.palette.textSecondary),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    // Uninstall / Install Action Button
                                    ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isInstalled
                                            ? (context.palette.textSecondary)
                                            : context.palette.primary,
                                        foregroundColor: isInstalled
                                            ? (context.palette.error)
                                            : context.palette.card,
                                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        elevation: 0,
                                      ),
                                      onPressed: () {
                                        MovieRepositoryService.instance.toggleProvider(currentRepo.id, provider.id, !isInstalled);
                                        setSheetState(() {});
                                      },
                                      child: Text(
                                        isInstalled ? 'Uninstall' : 'Install',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isInstalled
                                              ? (context.palette.error)
                                              : context.palette.card,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  SizedBox(height: 12),
                  Divider(),
                  // Delete entire repository button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.palette.error,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: Icon(Icons.delete_outline_rounded, size: 18),
                      label: Text('Delete Repository (সম্পূর্ণ রেপোজিটরি ডিলিট)', style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (delCtx) => AlertDialog(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            title: Text('Delete Repository?', style: TextStyle(fontWeight: FontWeight.bold)),
                            content: Text('Are you sure you want to remove "${currentRepo.name}" and all its extensions?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(delCtx), child: Text('Cancel')),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: context.palette.error),
                                onPressed: () {
                                  Navigator.pop(delCtx);
                                  Navigator.pop(ctx);
                                  MovieRepositoryService.instance.deleteRepository(currentRepo.id);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Removed ${currentRepo.name}'), behavior: SnackBarBehavior.floating),
                                  );
                                },
                                child: Text('Delete', style: TextStyle(color: context.palette.onPrimary)),
                              ),
                            ],
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
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: MovieRepositoryService.instance,
      builder: (context, _) {
        final service = MovieRepositoryService.instance;
        var repos = service.repositories;

        if (_filterQuery.isNotEmpty) {
          final q = _filterQuery.toLowerCase();
          repos = repos.where((r) {
            return r.name.toLowerCase().contains(q) ||
                r.url.toLowerCase().contains(q) ||
                r.description.toLowerCase().contains(q) ||
                r.tags.any((t) => t.toLowerCase().contains(q));
          }).toList();
        }

        return Container(
          height: MediaQuery.of(context).size.height * 0.88,
          decoration: BoxDecoration(
            color: context.palette.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: context.palette.border, width: 1.5),
            ),
          ),
          child: Column(
            children: [
              // Drag handle
              Center(
                child: Container(
                  margin: EdgeInsets.only(top: 10, bottom: 6),
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isDark ? context.palette.tint(context.palette.onScrim, 0.24) : context.palette.textSecondary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),

              // Header
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.hub_rounded, color: context.palette.primary, size: 22),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Movie & Audio Repositories',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${service.enabledRepositories.length} of ${service.repositories.length} Active Repositories',
                            style: TextStyle(fontSize: 11, color: context.palette.onPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _showAddCustomDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.palette.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      icon: Icon(Icons.add_rounded, size: 18, color: context.palette.onPrimary),
                      label: Text('Add Repo', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: context.palette.onPrimary)),
                    ),
                  ],
                ),
              ),

              // Search Filter Bar
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDark ? context.palette.card : context.palette.textSecondary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: TextField(
                    controller: _searchRepoCtrl,
                    decoration: InputDecoration(
                      hintText: 'Filter repos (e.g. SpotiFlac, Redowan, NetMirror)...',
                      hintStyle: TextStyle(fontSize: 12),
                      border: InputBorder.none,
                      prefixIcon: Icon(Icons.filter_list_rounded, size: 20),
                      suffixIcon: _filterQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.clear_rounded, size: 16),
                              onPressed: () {
                                _searchRepoCtrl.clear();
                                setState(() => _filterQuery = '');
                              },
                            )
                          : null,
                    ),
                    onChanged: (val) {
                      setState(() => _filterQuery = val.trim());
                    },
                  ),
                ),
              ),

              if (_isAdding || service.isLoading)
                LinearProgressIndicator(color: context.palette.primary),

              // Repositories List or Clean Empty State
              Expanded(
                child: repos.isEmpty
                    ? Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.extension_off_rounded, size: 64, color: context.palette.tint(context.palette.primary, 0.5)),
                              SizedBox(height: 16),
                              Text(
                                'No Repositories Currently Added',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Tap "Add Repo" above or choose a preset shortcode (e.g. spotiflac, 688321, zangetsu) to add your favorite repositories.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: context.palette.textSecondary, fontSize: 12, height: 1.4),
                              ),
                              SizedBox(height: 20),
                              ElevatedButton.icon(
                                onPressed: _showAddCustomDialog,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: context.palette.primary,
                                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                icon: Icon(Icons.add_rounded, color: context.palette.onPrimary),
                                label: Text('Add Repository / Shortcode', style: TextStyle(fontWeight: FontWeight.bold, color: context.palette.onPrimary)),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.all(16),
                        itemCount: repos.length,
                        separatorBuilder: (_, _) => SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final repo = repos[index];
                          return _buildRepoCard(repo, isDark, service);
                        },
                      ),
              ),

              // Bottom bar
              if (repos.isNotEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${service.enabledRepositories.length} Active (${service.repositories.length} Total)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (confirmCtx) => AlertDialog(
                              title: Text('Delete All Repositories?'),
                              content: Text('Are you sure you want to remove all repositories?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(confirmCtx), child: Text('Cancel')),
                                ElevatedButton(
                                  onPressed: () {
                                    Navigator.pop(confirmCtx);
                                    service.clearAllRepositories();
                                  },
                                  style: ElevatedButton.styleFrom(backgroundColor: context.palette.error),
                                  child: Text('Delete All', style: TextStyle(color: context.palette.onPrimary)),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: Icon(Icons.delete_sweep_rounded, size: 16, color: context.palette.error),
                        label: Text('Delete All Repos', style: TextStyle(fontSize: 12, color: context.palette.error)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRepoCard(MovieRepository repo, bool isDark, MovieRepositoryService service) {
    Color badgeColor = context.palette.primary;
    IconData repoIcon = Icons.extension_rounded;

    if (repo.iconType == 'spotiflac' || repo.id.contains('spotiflac')) {
      badgeColor = context.palette.success;
      repoIcon = Icons.music_note_rounded;
    } else if (repo.iconType == 'cloudstream') {
      badgeColor = context.palette.secondary;
      repoIcon = Icons.cloud_download_rounded;
    } else if (repo.iconType == 'dantotsu') {
      badgeColor = context.palette.textSecondary;
      repoIcon = Icons.auto_awesome_motion_rounded;
    } else if (repo.iconType == 'stremio') {
      badgeColor = context.palette.primary;
      repoIcon = Icons.tv_rounded;
    } else if (repo.iconType == 'bollywood') {
      badgeColor = context.palette.info;
      repoIcon = Icons.movie_filter_rounded;
    }

    return InkWell(
      onTap: () => _showProvidersDialog(repo),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.palette.card,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(repoIcon, color: badgeColor, size: 20),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              repo.name,
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          SizedBox(width: 6),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: badgeColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              'v${repo.version}',
                              style: TextStyle(
                                color: badgeColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 9,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 2),
                      Text(
                        'By ${repo.author} • ${repo.activeProviderCount}/${repo.actualProviderCount} Extensions Installed',
                        style: TextStyle(fontSize: 10, color: context.palette.textSecondary),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: repo.isEnabled,
                  activeThumbColor: badgeColor,
                  onChanged: (val) {
                    service.toggleRepository(repo.id, val);
                  },
                ),
              ],
            ),
            SizedBox(height: 6),
            Text(
              repo.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: context.palette.textSecondary),
            ),
            SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Wrap(
                  spacing: 4,
                  children: repo.tags.take(3).map((tag) {
                    return Container(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark ? context.palette.tint(context.palette.onScrim, 0.10) : context.palette.textSecondary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(tag, style: TextStyle(fontSize: 9)),
                    );
                  }).toList(),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Edit Repo Button
                    IconButton(
                      icon: Icon(Icons.edit_outlined, size: 16),
                      tooltip: 'Edit Repository details',
                      onPressed: () => _showEditRepoDialog(repo),
                    ),
                    // Delete Repo Button for 100% of repositories as requested by user
                    IconButton(
                      icon: Icon(Icons.delete_outline_rounded, color: context.palette.error, size: 16),
                      tooltip: 'Delete repository',
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (confirmCtx) => AlertDialog(
                            title: Text('Delete Repository?'),
                            content: Text('Are you sure you want to remove "${repo.name}"?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(confirmCtx), child: Text('Cancel')),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(confirmCtx);
                                  service.deleteRepository(repo.id);
                                },
                                style: ElevatedButton.styleFrom(backgroundColor: context.palette.error),
                                child: Text('Delete', style: TextStyle(color: context.palette.onPrimary)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
