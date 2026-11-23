import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../services/download_manager.dart';
import '../services/github_profile_service.dart';
import '../services/image_cache_service.dart';
import '../services/live_score_service.dart';
import '../services/movie_repository_service.dart';
import '../services/permission_service.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_palette.dart';
import '../widgets/folder_picker_sheet.dart';
import '../widgets/permission_dialog.dart';
import 'developer_screen.dart';
import 'zangetsu_providers_hub_screen.dart';

/// Minimal, clean, modern Settings UI.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _checkForUpdates(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Checking GitHub for updates…')),
      );
    final installed = await installedAndroidVersion;
    final update = await requestAppUpdate();
    if (!context.mounted || !messenger.mounted) return;
    messenger.hideCurrentSnackBar();
    if (update == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            installed == null
                ? 'APK updates are available on Android.'
                : 'No newer release found. Check your connection if you expected an update.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = context.palette.primary;
    final secondaryText = context.palette.textSecondary;

    return AnimatedBuilder(
      animation: Listenable.merge([
        SettingsService.instance,
        DownloadManager.instance,
        MovieRepositoryService.instance,
        StorageService.instance,
      ]),
      builder: (context, _) {
        final settings = SettingsService.instance;
        final downloadMgr = DownloadManager.instance;
        final storage = StorageService.instance;
        if (!storage.isLoaded) unawaited(storage.ensureLoaded());

        return Scaffold(
          body: SafeArea(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                18,
                16,
                18,
                28 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                // Minimal Header
                _buildHeader(context, isDark, accent),
                const SizedBox(height: 20),

                // 1. Storage & Files Group
                _sectionHeader(context, 'Storage & Files', Icons.folder_special_rounded, accent),
                const SizedBox(height: 8),
                _groupCard(
                  isDark: isDark,
                  accent: accent,
                  children: [
                    _permissionRow(context, isDark, accent, secondaryText, downloadMgr),
                    _divider(isDark),
                    _storageRow(context, isDark, accent, secondaryText, storage, downloadMgr),
                    _divider(isDark),
                    _locationRow(context, isDark, accent, secondaryText, downloadMgr, storage),
                    _divider(isDark),
                    _cacheRow(context, isDark, accent, secondaryText),
                  ],
                ),
                const SizedBox(height: 22),

                // 2. Downloads Preference Group
                _sectionHeader(context, 'Download Preferences', Icons.download_rounded, accent),
                const SizedBox(height: 8),
                _groupCard(
                  isDark: isDark,
                  accent: accent,
                  children: [
                    _parallelRow(context, settings, isDark, accent, secondaryText),
                    _divider(isDark),
                    _qualityRow(context, settings, isDark, accent, secondaryText),
                    _divider(isDark),
                    _audioRow(context, settings, isDark, accent, secondaryText),
                  ],
                ),
                const SizedBox(height: 22),

                // 3. Streaming & Content Group
                _sectionHeader(context, 'Streaming & Content', Icons.movie_filter_rounded, accent),
                const SizedBox(height: 8),
                _groupCard(
                  isDark: isDark,
                  accent: accent,
                  children: [
                    _providerHubRow(context, isDark, accent, secondaryText),
                    _divider(isDark),
                    _adultRow(settings, isDark, accent, secondaryText),
                  ],
                ),
                const SizedBox(height: 22),

                // 4. Appearance Group
                _sectionHeader(context, 'Appearance', Icons.palette_rounded, accent),
                const SizedBox(height: 8),
                _groupCard(
                  isDark: isDark,
                  accent: accent,
                  children: [
                    _themeRow(isDark, accent, settings),
                  ],
                ),
                const SizedBox(height: 22),

                // 5. About & Developer Group
                _sectionHeader(context, 'About & Updates', Icons.info_outline_rounded, accent),
                const SizedBox(height: 8),
                _groupCard(
                  isDark: isDark,
                  accent: accent,
                  children: [
                    _aboutRow(context, isDark, accent, secondaryText),
                    _divider(isDark),
                    _liveApiRow(context, isDark, accent, secondaryText),
                    _divider(isDark),
                    _developerTile(context, accent, isDark, secondaryText),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Header & Section Wrappers
  // ---------------------------------------------------------------------------
  Widget _buildHeader(BuildContext context, bool isDark, Color accent) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Settings',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 24,
            letterSpacing: -0.6,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'Customize your downloads, sources, and theme',
          style: TextStyle(
            color: p.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title, IconData icon, Color accent) {
    return Row(
      children: [
        Icon(icon, size: 16, color: accent),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: context.palette.textPrimary,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }

  Widget _groupCard({
    required bool isDark,
    required Color accent,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E2B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0x22FFFFFF) : Colors.black12,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.04),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _divider(bool isDark) {
    return Divider(
      height: 1,
      thickness: 1,
      color: isDark ? const Color(0x1AFFFFFF) : Colors.grey.shade200,
    );
  }

  // ---------------------------------------------------------------------------
  // Storage & Permissions Rows
  // ---------------------------------------------------------------------------
  Widget _permissionRow(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
    DownloadManager downloadMgr,
  ) {
    return FutureBuilder<Map<String, dynamic>>(
      future: Future.wait([
        PermissionService.instance.hasStoragePermission(),
        PermissionService.instance.hasNotificationPermission(),
      ]).then((results) => {'storage': results[0], 'notification': results[1]}),
      builder: (context, snapshot) {
        final storageOk = snapshot.data?['storage'] ?? false;
        final statusColor = storageOk
            ? context.palette.success
            : context.palette.info;

        return Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _iconTile(
                    storageOk
                        ? Icons.verified_user_rounded
                        : Icons.gpp_maybe_rounded,
                    statusColor,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'App Permissions',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          storageOk ? 'All storage & alert permissions granted' : 'Action needed for downloads',
                          style: TextStyle(
                            color: secondaryText,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _textPillButton(
                    label: 'Grant',
                    color: accent,
                    onTap: () => PermissionDialog.show(context),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _storageRow(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
    StorageService storage,
    DownloadManager downloads,
  ) {
    final currentId = storage.locations.isNotEmpty ? storage.current.id : '';

    Future<void> choose(StorageLocation location) async {
      if (location.id == currentId) return;
      final previous = downloads.downloadDirectory;
      final selected = await storage.select(location);
      await downloads.setDownloadDirectory(selected.appFolder);
      final moved = await storage.migrateLegacyFolder(
        newRoot: selected.downloadRoot,
        relocateTasks: downloads.relocateTasks,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            moved > 0
                ? 'Storage changed · $moved old files linked'
                : 'Downloads now save to ${selected.appFolder}',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      debugPrint('Download root changed: $previous → ${selected.appFolder}');
    }

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.sd_storage_rounded, accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Storage Device',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
              if (storage.isMigrating)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (!storage.isLoaded || storage.locations.isEmpty)
            Text(
              'Detecting storage devices…',
              style: TextStyle(color: secondaryText, fontSize: 12),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final location in storage.locations)
                  _driveChip(
                    location: location,
                    selected: location.id == currentId,
                    isDark: isDark,
                    accent: accent,
                    secondaryText: secondaryText,
                    onTap: () => choose(location),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _driveChip({
    required StorageLocation location,
    required bool selected,
    required bool isDark,
    required Color accent,
    required Color secondaryText,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.14)
                : (isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.grey.shade100),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? accent
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06)),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                location.kind == StorageKind.internal
                    ? Icons.smartphone_rounded
                    : location.kind == StorageKind.external
                        ? Icons.sd_card_rounded
                        : Icons.folder_open_rounded,
                size: 15,
                color: selected ? accent : secondaryText,
              ),
              const SizedBox(width: 6),
              Text(
                location.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected
                      ? accent
                      : (isDark ? Colors.white : Colors.black87),
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 5),
                Icon(Icons.check_circle_rounded, size: 14, color: accent),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDownloadFolder(
    BuildContext context,
    DownloadManager downloadMgr,
    StorageService storage,
  ) async {
    String? picked;
    if (Platform.isAndroid) {
      try {
        picked = await storage.pickFolder();
      } catch (_) {
        picked = null;
      }
    }
    if (picked == null && context.mounted) {
      picked = await FolderPickerSheet.show(
        context,
        initialPath: downloadMgr.downloadDirectory,
      );
    }
    if (picked == null || picked.isEmpty || !context.mounted) return;
    final root = picked.endsWith('/${StorageService.appFolderName}')
        ? picked
        : StorageService.joinAppFolder(picked);
    await downloadMgr.setDownloadDirectory(root);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Downloads now save to $root'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _locationRow(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
    DownloadManager downloadMgr,
    StorageService storage,
  ) {
    void chooseFolder() => _pickDownloadFolder(context, downloadMgr, storage);

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          _iconTile(Icons.folder_open_rounded, accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Download Location',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  downloadMgr.downloadDirectory,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondaryText, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _textPillButton(
            label: 'Choose folder',
            color: accent,
            onTap: chooseFolder,
          ),
        ],
      ),
    );
  }

  Widget _cacheRow(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return FutureBuilder<int>(
      future: () async {
        await ImageCacheService.instance.init();
        return ImageCacheService.instance.diskBytesUsed;
      }(),
      builder: (context, snap) {
        final used = snap.data ?? ImageCacheService.instance.diskBytesUsed;
        final mb = used / 1048576;
        final usedLabel = mb < 1
            ? '${(used / 1024).toStringAsFixed(0)} KB'
            : '${mb.toStringAsFixed(1)} MB';

        return Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _iconTile(Icons.bolt_rounded, context.palette.success),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cached Artwork',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Temporary cache · $usedLabel / 50 MB',
                      style: TextStyle(color: secondaryText, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _textPillButton(
                label: 'Clear',
                color: context.palette.error,
                onTap: () async {
                  await ImageCacheService.instance.clear();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Cache cleared')),
                    );
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Download Preference Dropdowns
  // ---------------------------------------------------------------------------
  Widget _parallelRow(
    BuildContext context,
    SettingsService settings,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.speed_rounded, context.palette.success),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Simultaneous Downloads',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Files downloading at once',
                      style: TextStyle(color: secondaryText, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _dropdownTile(
            context: context,
            isDark: isDark,
            accent: accent,
            valueText: '⚡ ${settings.maxConcurrent} File${settings.maxConcurrent == 1 ? '' : 's'} downloading at once',
            onTap: () {
              _showDropdownPickerSheet<int>(
                context: context,
                title: 'Simultaneous Downloads',
                subtitle: 'Choose how many files can download at the same time',
                icon: Icons.speed_rounded,
                currentValue: settings.maxConcurrent,
                items: const [
                  ('1 File at once', 'Conserves network bandwidth and memory', 1),
                  ('2 Files at once', 'Balanced download speed', 2),
                  ('3 Files at once', 'Recommended for high-speed connections', 3),
                  ('4 Files at once', 'Fast multi-file downloads', 4),
                  ('5 Files at once', 'Maximum parallel download capacity', 5),
                ],
                onSelect: (val) => settings.setMaxConcurrent(val),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _qualityRow(
    BuildContext context,
    SettingsService settings,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.high_quality_rounded, context.palette.info),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Default Video Quality',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Used when selected quality is available',
                      style: TextStyle(color: secondaryText, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _dropdownTile(
            context: context,
            isDark: isDark,
            accent: accent,
            valueText: '🎬 ${settings.defaultVideoQuality}',
            onTap: () {
              _showDropdownPickerSheet<String>(
                context: context,
                title: 'Default Video Quality',
                subtitle: 'Preferred resolution for video downloads',
                icon: Icons.high_quality_rounded,
                currentValue: settings.defaultVideoQuality,
                items: const [
                  ('Ask Every Time', 'Prompt quality selection before downloading', 'Ask Every Time'),
                  ('4K Ultra HD', 'Highest resolution (2160p / 4K)', '4K Ultra HD'),
                  ('1080p Full HD', 'Best balance of clarity and size (1080p)', '1080p Full HD'),
                  ('720p HD', 'Standard HD video quality (720p)', '720p HD'),
                ],
                onSelect: (val) => settings.setDefaultVideoQuality(val),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _audioRow(
    BuildContext context,
    SettingsService settings,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.audiotrack_rounded, context.palette.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Default Audio Format',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Used for audio downloads',
                      style: TextStyle(color: secondaryText, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _dropdownTile(
            context: context,
            isDark: isDark,
            accent: accent,
            valueText: '🎵 ${settings.defaultAudioFormat}',
            onTap: () {
              _showDropdownPickerSheet<String>(
                context: context,
                title: 'Default Audio Format',
                subtitle: 'Preferred bitrate and encoding for music downloads',
                icon: Icons.audiotrack_rounded,
                currentValue: settings.defaultAudioFormat,
                items: const [
                  ('320 kbps MP3', 'Highest audio quality (320 kbps MP3)', '320 kbps MP3'),
                  ('256 kbps MP3', 'High quality audio (256 kbps MP3)', '256 kbps MP3'),
                  ('128 kbps MP3', 'Standard audio quality (128 kbps MP3)', '128 kbps MP3'),
                  ('M4A (AAC)', 'Native AAC container (M4A)', 'M4A (AAC)'),
                ],
                onSelect: (val) => settings.setDefaultAudioFormat(val),
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Streaming & Privacy Rows
  // ---------------------------------------------------------------------------
  Widget _providerHubRow(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ZangetsuProvidersHubScreen()),
          );
        },
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _iconTile(Icons.movie_filter_rounded, accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Manage Streaming Sources',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Provider Hub for movies, series, and live TV',
                      style: TextStyle(color: secondaryText, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: secondaryText, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _adultRow(
    SettingsService settings,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          _iconTile(Icons.visibility_outlined, Colors.redAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Show 18+ Sources',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  'Show adult catalog sources in source lists',
                  style: TextStyle(color: secondaryText, fontSize: 11.5),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: settings.showAdultRepositories,
            onChanged: settings.setShowAdultRepositories,
            activeColor: accent,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Theme Choice Row
  // ---------------------------------------------------------------------------
  Widget _themeRow(bool isDark, Color accent, SettingsService settings) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.palette_rounded, accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'App Theme',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Light, dark, or match device theme',
                      style: TextStyle(
                        color: AppPalette.current.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _themeOption(
                label: 'Dark',
                icon: Icons.dark_mode_rounded,
                mode: ThemeMode.dark,
                current: settings.themeMode,
                isDark: isDark,
                accent: accent,
                onTap: () => settings.setThemeMode(ThemeMode.dark),
              ),
              const SizedBox(width: 8),
              _themeOption(
                label: 'Light',
                icon: Icons.light_mode_rounded,
                mode: ThemeMode.light,
                current: settings.themeMode,
                isDark: isDark,
                accent: accent,
                onTap: () => settings.setThemeMode(ThemeMode.light),
              ),
              const SizedBox(width: 8),
              _themeOption(
                label: 'Auto',
                icon: Icons.brightness_auto_rounded,
                mode: ThemeMode.system,
                current: settings.themeMode,
                isDark: isDark,
                accent: accent,
                onTap: () => settings.setThemeMode(ThemeMode.system),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _themeOption({
    required String label,
    required IconData icon,
    required ThemeMode mode,
    required ThemeMode current,
    required bool isDark,
    required Color accent,
    required VoidCallback onTap,
  }) {
    final selected = current == mode;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: 0.14)
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.grey.shade100),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? accent
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06)),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: selected ? accent : AppPalette.current.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? accent : AppPalette.current.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // About & Developer Rows
  // ---------------------------------------------------------------------------
  Widget _aboutRow(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.20),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/images/app_logo.png'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'All in One',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
                const SizedBox(height: 2),
                FutureBuilder<String?>(
                  future: installedAndroidVersion,
                  builder: (context, snapshot) {
                    final version = snapshot.data;
                    return Text(
                      version == null ? 'Media Downloader' : 'v$version',
                      style: TextStyle(
                        color: accent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          _textPillButton(
            label: 'Check for updates',
            color: accent,
            onTap: () => _checkForUpdates(context),
          ),
        ],
      ),
    );
  }

  Widget _liveApiRow(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return FutureBuilder<String>(
      future: LiveScoreService.instance.endpoint,
      builder: (context, snapshot) {
        return Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _iconTile(Icons.sports_cricket_rounded, accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Live Score API',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      snapshot.data ?? 'Free keyless endpoint',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: secondaryText, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _textPillButton(
                label: 'Edit',
                color: accent,
                onTap: () async {
                  final ctrl = TextEditingController(
                    text: await LiveScoreService.instance.endpoint,
                  );
                  final saved = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Live Score API URL'),
                      content: TextField(
                        controller: ctrl,
                        autofocus: true,
                        decoration: const InputDecoration(hintText: 'https://…'),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  );
                  if (saved != null && saved.isNotEmpty) {
                    await LiveScoreService.instance.setEndpoint(saved);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _developerTile(
    BuildContext context,
    Color accent,
    bool isDark,
    Color secondaryText,
  ) {
    return FutureBuilder<GithubProfile?>(
      future: GithubProfileService.fetch(),
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final avatarUrl = profile?.avatarUrl ??
            Uri.parse('https://github.com/${GithubProfileService.username}.png');
        final name = profile?.displayName ?? 'S. M. Shahin Reza Sifat';

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => DeveloperScreen()),
            ),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: ClipOval(
                      child: Image.network(
                        avatarUrl.toString(),
                        width: 38,
                        height: 38,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: accent.withValues(alpha: 0.16),
                          alignment: Alignment.center,
                          child: Text(
                            'SR',
                            style: TextStyle(
                              color: accent,
                              fontWeight: FontWeight.w900,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                            color: context.palette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Developer',
                          style: TextStyle(
                            color: accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: secondaryText, size: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Helper Widgets
  // ---------------------------------------------------------------------------
  Widget _dropdownTile({
    required BuildContext context,
    required bool isDark,
    required Color accent,
    required String valueText,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  valueText,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: accent,
                  ),
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: accent,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDropdownPickerSheet<T>({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required List<(String label, String note, T value)> items,
    required T currentValue,
    required ValueChanged<T> onSelect,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = context.palette.primary;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: context.palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: accent, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: context.palette.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (label, note, val) in items) ...[
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(ctx);
                            onSelect(val);
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: val == currentValue
                                  ? accent.withValues(alpha: isDark ? 0.16 : 0.10)
                                  : (isDark
                                      ? Colors.white.withValues(alpha: 0.05)
                                      : Colors.grey.shade100),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: val == currentValue
                                    ? accent
                                    : (isDark
                                        ? Colors.white.withValues(alpha: 0.08)
                                        : Colors.black.withValues(alpha: 0.06)),
                                width: val == currentValue ? 1.8 : 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        label,
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w800,
                                          color: val == currentValue
                                              ? accent
                                              : (isDark
                                                  ? Colors.white
                                                  : Colors.black87),
                                        ),
                                      ),
                                      if (note.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          note,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: context.palette.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                if (val == currentValue)
                                  Icon(
                                    Icons.check_circle_rounded,
                                    color: accent,
                                    size: 20,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _iconTile(IconData icon, Color color) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, color: color, size: 19),
    );
  }

  Widget _textPillButton({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 11.5,
            ),
          ),
        ),
      ),
    );
  }
}
