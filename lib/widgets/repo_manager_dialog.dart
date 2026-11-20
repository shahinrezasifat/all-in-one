import 'package:flutter/material.dart';
import '../models/movie_model.dart';
import '../services/movie_repository_service.dart';
import '../theme/app_colors.dart';

class RepoManagerDialog extends StatefulWidget {
  const RepoManagerDialog({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const RepoManagerDialog(),
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
          backgroundColor: success ? AppColors.accentGreen : Colors.redAccent,
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
        title: const Row(
          children: [
            Icon(Icons.add_box_rounded, color: AppColors.primary),
            SizedBox(width: 8),
            Text('Add Repository or Shortcode', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter SpotiFlac, Cloudstream, or Dantotsu registry URL or shortcode.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 14),

              // Quick Presets
              const Text(
                'Top Verified Repositories:',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.primary),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _popularRepoPresets.map((preset) {
                  return ActionChip(
                    avatar: Text(preset['icon']!, style: const TextStyle(fontSize: 12)),
                    label: Text(preset['name']!),
                    labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onPressed: () {
                      _nameCtrl.text = preset['name']!;
                      _urlCtrl.text = preset['url']!;
                    },
                  );
                }).toList(),
              ),

              const SizedBox(height: 14),

              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: 'Repository Name (Optional)',
                  hintText: 'e.g. SpotiFlac Flac Audio Repo',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.label_outline_rounded),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _urlCtrl,
                decoration: InputDecoration(
                  labelText: 'Repo URL / Registry Link *',
                  hintText: 'https://raw.githubusercontent.com/.../registry.json',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.link_rounded),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => _processAddRepository(_nameCtrl.text, _urlCtrl.text, ctx),
            child: const Text('Add Repository', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
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
        title: const Row(
          children: [
            Icon(Icons.edit_note_rounded, color: AppColors.accentGold),
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
              const SizedBox(height: 10),
              TextField(
                controller: _urlCtrl,
                decoration: InputDecoration(
                  labelText: 'Repository URL',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 10),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () {
              MovieRepositoryService.instance.editRepository(
                repo.id,
                name: _nameCtrl.text.trim(),
                url: _urlCtrl.text.trim(),
                description: _descCtrl.text.trim(),
              );
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Repository updated successfully!'), behavior: SnackBarBehavior.floating),
              );
            },
            child: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black)),
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
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${currentRepo.activeProviderCount} of ${currentRepo.actualProviderCount} Extensions Installed (মোট ${currentRepo.actualProviderCount}টি এক্সটেনশন)',
                              style: const TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(),
                  const SizedBox(height: 6),
                  Expanded(
                    child: currentRepo.providers.isEmpty
                        ? const Center(
                            child: Text('No extensions indexed for this repository yet.'),
                          )
                        : ListView.separated(
                            itemCount: currentRepo.providers.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 8),
                            itemBuilder: (context, idx) {
                              final provider = currentRepo.providers[idx];
                              final isInstalled = provider.isInstalled && provider.isEnabled;
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isDark ? const Color(0xFF0F172A) : Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                                      decoration: BoxDecoration(
                                        color: isInstalled
                                            ? AppColors.primary.withValues(alpha: 0.15)
                                            : Colors.grey.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        provider.language.toUpperCase(),
                                        style: TextStyle(
                                          color: isInstalled ? AppColors.primary : Colors.grey,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  provider.name,
                                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                decoration: BoxDecoration(
                                                  color: isInstalled
                                                      ? Colors.green.withValues(alpha: 0.15)
                                                      : Colors.grey.withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  isInstalled ? 'Installed' : 'Uninstalled',
                                                  style: TextStyle(
                                                    color: isInstalled ? Colors.green : Colors.grey,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (provider.description.isNotEmpty) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              provider.description,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.black54),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Uninstall / Install Action Button
                                    ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isInstalled
                                            ? (isDark ? Colors.grey.shade800 : Colors.grey.shade300)
                                            : AppColors.primary,
                                        foregroundColor: isInstalled
                                            ? (isDark ? Colors.redAccent.shade100 : Colors.red.shade700)
                                            : Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                                              ? (isDark ? Colors.redAccent.shade100 : Colors.red.shade700)
                                              : Colors.white,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(),
                  // Delete entire repository button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentRed,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('Delete Repository (সম্পূর্ণ রেপোজিটরি ডিলিট)', style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (delCtx) => AlertDialog(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            title: const Text('Delete Repository?', style: TextStyle(fontWeight: FontWeight.bold)),
                            content: Text('Are you sure you want to remove "${currentRepo.name}" and all its extensions?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(delCtx), child: const Text('Cancel')),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentRed),
                                onPressed: () {
                                  Navigator.pop(delCtx);
                                  Navigator.pop(ctx);
                                  MovieRepositoryService.instance.deleteRepository(currentRepo.id);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Removed ${currentRepo.name}'), behavior: SnackBarBehavior.floating),
                                  );
                                },
                                child: const Text('Delete', style: TextStyle(color: Colors.white)),
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
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder, width: 1.5),
            ),
          ),
          child: Column(
            children: [
              // Drag handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.hub_rounded, color: AppColors.primary, size: 22),
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
                            style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.black54),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _showAddCustomDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      icon: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                      label: const Text('Add Repo', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white)),
                    ),
                  ],
                ),
              ),

              // Search Filter Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkCard : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: TextField(
                    controller: _searchRepoCtrl,
                    decoration: InputDecoration(
                      hintText: 'Filter repos (e.g. SpotiFlac, Redowan, NetMirror)...',
                      hintStyle: const TextStyle(fontSize: 12),
                      border: InputBorder.none,
                      prefixIcon: const Icon(Icons.filter_list_rounded, size: 20),
                      suffixIcon: _filterQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 16),
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
                const LinearProgressIndicator(color: AppColors.primary),

              // Repositories List or Clean Empty State
              Expanded(
                child: repos.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.extension_off_rounded, size: 64, color: AppColors.primary.withValues(alpha: 0.5)),
                              const SizedBox(height: 16),
                              const Text(
                                'No Repositories Currently Added',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Tap "Add Repo" above or choose a preset shortcode (e.g. spotiflac, 688321, zangetsu) to add your favorite repositories.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.4),
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton.icon(
                                onPressed: _showAddCustomDialog,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                icon: const Icon(Icons.add_rounded, color: Colors.white),
                                label: const Text('Add Repository / Shortcode', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: repos.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final repo = repos[index];
                          return _buildRepoCard(repo, isDark, service);
                        },
                      ),
              ),

              // Bottom bar
              if (repos.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${service.enabledRepositories.length} Active (${service.repositories.length} Total)',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (confirmCtx) => AlertDialog(
                              title: const Text('Delete All Repositories?'),
                              content: const Text('Are you sure you want to remove all repositories?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(confirmCtx), child: const Text('Cancel')),
                                ElevatedButton(
                                  onPressed: () {
                                    Navigator.pop(confirmCtx);
                                    service.clearAllRepositories();
                                  },
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                  child: const Text('Delete All', style: TextStyle(color: Colors.white)),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: const Icon(Icons.delete_sweep_rounded, size: 16, color: Colors.redAccent),
                        label: const Text('Delete All Repos', style: TextStyle(fontSize: 12, color: Colors.redAccent)),
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
    Color badgeColor = AppColors.primary;
    IconData repoIcon = Icons.extension_rounded;

    if (repo.iconType == 'spotiflac' || repo.id.contains('spotiflac')) {
      badgeColor = const Color(0xFF1DB954);
      repoIcon = Icons.music_note_rounded;
    } else if (repo.iconType == 'cloudstream') {
      badgeColor = const Color(0xFF00ADB5);
      repoIcon = Icons.cloud_download_rounded;
    } else if (repo.iconType == 'dantotsu') {
      badgeColor = const Color(0xFFFF5722);
      repoIcon = Icons.auto_awesome_motion_rounded;
    } else if (repo.iconType == 'stremio') {
      badgeColor = const Color(0xFF673AB7);
      repoIcon = Icons.tv_rounded;
    } else if (repo.iconType == 'bollywood') {
      badgeColor = const Color(0xFFFF9800);
      repoIcon = Icons.movie_filter_rounded;
    }

    return InkWell(
      onTap: () => _showProvidersDialog(repo),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard : AppColors.lightCard,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(repoIcon, color: badgeColor, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              repo.name,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
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
                      const SizedBox(height: 2),
                      Text(
                        'By ${repo.author} • ${repo.activeProviderCount}/${repo.actualProviderCount} Extensions Installed',
                        style: TextStyle(fontSize: 10, color: isDark ? Colors.white60 : Colors.black54),
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
            const SizedBox(height: 6),
            Text(
              repo.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Wrap(
                  spacing: 4,
                  children: repo.tags.take(3).map((tag) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(tag, style: const TextStyle(fontSize: 9)),
                    );
                  }).toList(),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Edit Repo Button
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      tooltip: 'Edit Repository details',
                      onPressed: () => _showEditRepoDialog(repo),
                    ),
                    // Delete Repo Button for 100% of repositories as requested by user
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 16),
                      tooltip: 'Delete repository',
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (confirmCtx) => AlertDialog(
                            title: const Text('Delete Repository?'),
                            content: Text('Are you sure you want to remove "${repo.name}"?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(confirmCtx), child: const Text('Cancel')),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(confirmCtx);
                                  service.deleteRepository(repo.id);
                                },
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                child: const Text('Delete', style: TextStyle(color: Colors.white)),
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
