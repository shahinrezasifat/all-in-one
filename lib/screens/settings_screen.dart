import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';
import '../services/download_manager.dart';
import '../services/github_profile_service.dart';
import '../services/image_cache_service.dart';
import '../services/movie_repository_service.dart';
import '../services/permission_service.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import '../theme/app_palette.dart';
import '../widgets/folder_picker_sheet.dart';
import '../widgets/permission_dialog.dart';
import 'developer_screen.dart';
import 'zangetsu_providers_hub_screen.dart';

/// Settings is deliberately visual: every preference is shown as an icon tile
/// plus a control the user can *see* (chips, bars, mini theme previews) so the
/// screen stays scannable without paragraphs of explanation.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static String _githubProfile = GithubProfileService.profileUrl;

  Future<void> _openGithub(BuildContext context) async {
    try {
      if (await launchUrl(
        Uri.parse(_githubProfile),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on PlatformException {
      // no handler installed
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Could not open GitHub.')));
  }

  Future<void> _checkForUpdates(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('Checking GitHub for updates…')),
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
                : 'No newer release found. Check your connection if you '
                      'expected an update.',
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
          body: Stack(
            children: [
              Positioned.fill(child: _ambientBackground(accent, isDark)),
              SafeArea(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    28 + MediaQuery.paddingOf(context).bottom,
                  ),
                  children: [
                    _buildHeader(isDark, accent),
                    SizedBox(height: 14),

                    _sectionTitle(
                      'Storage',
                      Icons.folder_special_rounded,
                      accent,
                    ),
                    SizedBox(height: 10),
                    _permissionCard(isDark, accent, secondaryText, downloadMgr),
                    SizedBox(height: 10),
                    _storageCard(context, isDark, accent, secondaryText),
                    SizedBox(height: 10),
                    _locationCard(
                      context,
                      isDark,
                      accent,
                      secondaryText,
                      downloadMgr,
                      storage,
                    ),
                    SizedBox(height: 10),
                    _cacheCard(context, isDark, accent, secondaryText),
                    SizedBox(height: 22),

                    _sectionTitle(
                      'Downloads',
                      Icons.download_rounded,
                      accent,
                    ),
                    SizedBox(height: 10),
                    _parallelCard(settings, isDark, accent, secondaryText),
                    SizedBox(height: 10),
                    _qualityCard(settings, isDark, accent),
                    SizedBox(height: 10),
                    _audioCard(settings, isDark, accent),
                    SizedBox(height: 22),

                    _sectionTitle(
                      'Movie & TV Sources',
                      Icons.extension_rounded,
                      accent,
                    ),
                    SizedBox(height: 10),
                    _providerHubCard(context, isDark, accent, secondaryText),
                    SizedBox(height: 22),

                    _sectionTitle('Privacy & Content', Icons.shield_rounded, accent),
                    SizedBox(height: 10),
                    _adultCard(settings, isDark, accent, secondaryText),
                    SizedBox(height: 22),

                    _sectionTitle(
                      'Appearance',
                      Icons.palette_rounded,
                      accent,
                    ),
                    SizedBox(height: 10),
                    _themeCard(isDark, accent, settings),
                    SizedBox(height: 22),

                    _sectionTitle(
                      'About & Updates',
                      Icons.info_outline_rounded,
                      accent,
                    ),
                    SizedBox(height: 10),
                    _aboutCard(context, isDark, accent, secondaryText),
                    const SizedBox(height: 10),
                    _developerRow(context, accent, isDark),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------
  Widget _buildHeader(bool isDark, Color accent) {
    final p = AppPalette.current;
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            gradient: p.primaryGradient,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: p.tint(p.primary, .28),
                blurRadius: 16,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Icon(
            Icons.settings_suggest_rounded,
            color: p.onPrimary,
            size: 26,
          ),
        ),
        SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Settings',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 23,
                  letterSpacing: -.6,
                  color: p.textPrimary,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Manage downloads, privacy, and appearance',
                style: TextStyle(color: p.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Developer (single slim row → GitHub)
  // ---------------------------------------------------------------------------
  Widget _developerRow(BuildContext context, Color accent, bool isDark) {
    final secondary = context.palette.textSecondary;

    return FutureBuilder<GithubProfile?>(
      future: GithubProfileService.fetch(),
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final avatarUrl =
            profile?.avatarUrl ??
            Uri.parse(
              'https://github.com/${GithubProfileService.username}.png',
            );
        final name = profile?.displayName ?? 'S. M. Shahin Reza Sifat';

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openGithub(context),
            borderRadius: BorderRadius.circular(20),
            child: _glass(
              isDark: isDark,
              accent: accent,
              padding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: ClipOval(
                      child: Image.network(
                        avatarUrl.toString(),
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) => Container(
                          color: accent.withValues(alpha: .16),
                          alignment: Alignment.center,
                          child: Text(
                            'SR',
                            style: TextStyle(
                              color: accent,
                              fontWeight: FontWeight.w900,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 12),
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
                            fontSize: 14,
                            color: context.palette.textPrimary,
                          ),
                        ),
                        SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(Icons.code_rounded, size: 12, color: accent),
                            SizedBox(width: 4),
                            Text(
                              'GitHub profile',
                              style: TextStyle(
                                color: accent,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .8,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: secondary),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Storage & permissions
  // ---------------------------------------------------------------------------
  Widget _permissionCard(
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
        final notifOk = snapshot.data?['notification'] ?? false;
        final isPublic = downloadMgr.isPublicStorage;
        final statusColor = storageOk
            ? context.palette.success
            : context.palette.info;

        return _glass(
          isDark: isDark,
          accent: accent,
          padding: const EdgeInsets.all(12),
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
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'App Permissions',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(height: 3),
                        Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            SizedBox(width: 6),
                            Text(
                              storageOk ? 'All granted' : 'Action needed',
                              style: TextStyle(
                                color: secondaryText,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12),
              Row(
                children: [
                  _permBadge(
                    'Storage',
                    storageOk,
                    Icons.folder_rounded,
                    isDark,
                  ),
                  SizedBox(width: 8),
                  _permBadge(
                    'Alerts',
                    notifOk,
                    Icons.notifications_rounded,
                    isDark,
                  ),
                  SizedBox(width: 8),
                  _permBadge(
                    isPublic ? 'Public' : 'App only',
                    isPublic,
                    Icons.sd_card_rounded,
                    isDark,
                  ),
                ],
              ),
              SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _gradientButton(
                      icon: Icons.security_update_good_rounded,
                      label: 'Grant',
                      accent: accent,
                      onTap: () => PermissionDialog.show(context),
                    ),
                  ),
                  SizedBox(width: 8),
                  _squareButton(
                    icon: Icons.settings_rounded,
                    accent: accent,
                    tooltip: 'System settings',
                    onTap: () => PermissionService.instance.openSettings(),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _permBadge(String label, bool isOk, IconData icon, bool isDark) {
    final color = isOk ? AppPalette.current.success : AppPalette.current.info;
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: isDark
              ? AppPalette.current.tint(AppPalette.current.card, .05)
              : AppPalette.current.tint(AppPalette.current.card, .7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: .18)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isOk ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
              color: color,
              size: 14,
            ),
            SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppPalette.current.textSecondary : AppPalette.current.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _storageCard(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    final storage = StorageService.instance;
    final downloads = DownloadManager.instance;
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

    return _glass(
      isDark: isDark,
      accent: accent,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.sd_storage_rounded, accent),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Storage Device',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
              if (storage.isMigrating)
                SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          SizedBox(height: 12),
          if (!storage.isLoaded || storage.locations.isEmpty)
            Row(
              children: [
                Icon(
                  Icons.storage_rounded,
                  size: 15,
                  color: accent.withValues(alpha: .6),
                ),
                SizedBox(width: 8),
                Text(
                  'Detecting…',
                  style: TextStyle(color: secondaryText, fontSize: 12),
                ),
              ],
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
    final soft = isDark
        ? AppPalette.current.tint(AppPalette.current.card, .05)
        : AppPalette.current.tint(AppPalette.current.card, .75);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: Duration(milliseconds: 180),
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: .12) : soft,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: .55)
                  : (AppPalette.current.border),
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
                size: 16,
                color: selected ? accent : secondaryText,
              ),
              SizedBox(width: 7),
              Text(
                location.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected
                      ? accent
                      : (isDark ? AppPalette.current.textSecondary : AppPalette.current.textPrimary),
                ),
              ),
              if (selected) ...[
                SizedBox(width: 5),
                Icon(Icons.check_circle_rounded, size: 14, color: accent),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Native SAF picker first (Android), with an always-available in-app
  /// folder browser as fallback. Never fails silently.
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

  Widget _locationCard(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
    DownloadManager downloadMgr,
    StorageService storage,
  ) {
    void chooseFolder() => _pickDownloadFolder(context, downloadMgr, storage);

    return _buildSettingCard(
      isDark: isDark,
      accent: accent,
      secondaryText: secondaryText,
      icon: Icons.folder_open_rounded,
      iconColor: accent,
      title: 'Download Location',
      subtitle: downloadMgr.downloadDirectory,
      onTap: chooseFolder,
      trailing: TextButton(
        onPressed: chooseFolder,
        child: const Text('Choose folder'),
      ),
    );
  }

  Widget _cacheCard(
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
        final pct = (used / ImageCacheService.maxDiskBytes * 100)
            .clamp(0, 100)
            .toDouble();
        final usedLabel = mb < 1
            ? '${(used / 1024).toStringAsFixed(0)} KB'
            : '${mb.toStringAsFixed(1)} MB';

        return _glass(
          isDark: isDark,
          accent: accent,
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _iconTile(Icons.bolt_rounded, context.palette.success),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cached Images',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'Temporary artwork · $usedLabel / 50 MB',
                          style: TextStyle(
                            color: secondaryText,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _textButton(
                    label: 'Clear cache',
                    color: context.palette.error,
                    onTap: () async {
                      await ImageCacheService.instance.clear();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Cache cleared')),
                        );
                      }
                    },
                  ),
                ],
              ),
              SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct / 100,
                  minHeight: 6,
                  color: context.palette.success,
                  backgroundColor: context.palette.tint(context.palette.success, .14,),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Downloads: parallel bars + option chips (no dropdown sheets)
  // ---------------------------------------------------------------------------
  Widget _parallelCard(
    SettingsService settings,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return _glass(
      isDark: isDark,
      accent: accent,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.speed_rounded, AppPalette.current.success),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Simultaneous Downloads',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: accent.withValues(alpha: .22)),
                ),
                child: Text(
                  '${settings.maxConcurrent}×',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            "Files downloading at once.",
            style: TextStyle(color: AppPalette.current.textSecondary, fontSize: 12),
          ),
          SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(5, (index) {
              final count = index + 1;
              final selected = count <= settings.maxConcurrent;
              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => settings.setMaxConcurrent(count),
                  child: Padding(
                    padding: EdgeInsets.only(right: index == 4 ? 0 : 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedContainer(
                          duration: Duration(milliseconds: 200),
                          height: 18 + index * 8,
                          decoration: BoxDecoration(
                            gradient: selected
                                ? LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      accent,
                                      accent.withValues(alpha: .6),
                                    ],
                                  )
                                : null,
                            color: selected
                                ? null
                                : (isDark
                                    ? AppPalette.current.tint(AppPalette.current.card, .07)
                                    : AppPalette.current.shadowAt(.06)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          '$count',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: selected ? accent : secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _qualityCard(SettingsService settings, bool isDark, Color accent) {
    final options = <(String, String)>[
      ('Ask', 'Ask Every Time'),
      ('4K', '4K Ultra HD'),
      ('1080p', '1080p Full HD'),
      ('720p', '720p HD'),
    ];

    return _glass(
      isDark: isDark,
      accent: accent,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.high_quality_rounded, AppPalette.current.info),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Default Video Quality',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            "Used when the selected quality is available.",
            style: TextStyle(color: AppPalette.current.textSecondary, fontSize: 12),
          ),
          SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, value) in options)
                _choiceChip(
                  label: label,
                  selected: settings.defaultVideoQuality == value,
                  isDark: isDark,
                  accent: accent,
                  onTap: () => settings.setDefaultVideoQuality(value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _audioCard(SettingsService settings, bool isDark, Color accent) {
    final options = <(String, String)>[
      ('MP3 · 320 kbps', '320 kbps MP3'),
      ('MP3 · 256 kbps', '256 kbps MP3'),
      ('MP3 · 128 kbps', '128 kbps MP3'),
      ('M4A', 'M4A (AAC)'),
    ];

    return _glass(
      isDark: isDark,
      accent: accent,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.audiotrack_rounded, AppPalette.current.primary),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Default Audio Format',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            "Used for audio downloads.",
            style: TextStyle(color: AppPalette.current.textSecondary, fontSize: 12),
          ),
          SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, value) in options)
                _choiceChip(
                  label: label,
                  selected: settings.defaultAudioFormat == value,
                  isDark: isDark,
                  accent: accent,
                  onTap: () => settings.setDefaultAudioFormat(value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _choiceChip({
    required String label,
    required bool selected,
    required bool isDark,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: Duration(milliseconds: 180),
          padding: EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: .14)
                : (isDark
                    ? AppPalette.current.tint(AppPalette.current.card, .06)
                    : AppPalette.current.tint(AppPalette.current.card, .75)),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? accent
                  : (AppPalette.current.border),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Semantics(
            selected: selected,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? accent : AppPalette.current.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Content / privacy rows
  // ---------------------------------------------------------------------------
  Widget _providerHubCard(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return _buildSettingCard(
      isDark: isDark,
      accent: accent,
      secondaryText: secondaryText,
      icon: Icons.movie_filter_rounded,
      iconColor: accent,
      title: 'Manage Streaming Sources',
      subtitle: 'Add or enable sources for movies, series, and live TV.',
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ZangetsuProvidersHubScreen()),
        );
      },
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: secondaryText,
        size: 22,
      ),
    );
  }

  Widget _adultCard(
    SettingsService settings,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return _buildSettingCard(
      isDark: isDark,
      accent: accent,
      secondaryText: secondaryText,
      icon: Icons.visibility_outlined,
      iconColor: AppPalette.current.error,
      title: 'Show 18+ Sources',
      subtitle: 'Show adult sources in the source list.',
      trailing: Switch.adaptive(
        value: settings.showAdultRepositories,
        onChanged: settings.setShowAdultRepositories,
        activeColor: accent,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Theme: three mini previews instead of a description card
  // ---------------------------------------------------------------------------
  Widget _themeCard(bool isDark, Color accent, SettingsService settings) {
    return _glass(
      isDark: isDark,
      accent: accent,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.palette_rounded, AppPalette.current.info),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'App Theme',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            "Light, dark, or match your device.",
            style: TextStyle(color: AppPalette.current.textSecondary, fontSize: 12),
          ),
          SizedBox(height: 12),
          Row(
            children: [
              _themeTile(
                label: 'Dark',
                icon: Icons.dark_mode_rounded,
                mode: ThemeMode.dark,
                current: settings.themeMode,
                isDark: isDark,
                accent: accent,
                onTap: () => settings.setThemeMode(ThemeMode.dark),
              ),
              SizedBox(width: 10),
              _themeTile(
                label: 'Light',
                icon: Icons.light_mode_rounded,
                mode: ThemeMode.light,
                current: settings.themeMode,
                isDark: isDark,
                accent: accent,
                onTap: () => settings.setThemeMode(ThemeMode.light),
              ),
              SizedBox(width: 10),
              _themeTile(
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

  Widget _themeTile({
    required String label,
    required IconData icon,
    required ThemeMode mode,
    required ThemeMode current,
    required bool isDark,
    required Color accent,
    required VoidCallback onTap,
  }) {
    final selected = current == mode;
    final labelColor = selected
        ? accent
        : (isDark ? AppPalette.current.textSecondary : AppPalette.current.textPrimary);

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 200),
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: .12)
                  : (isDark
                      ? AppPalette.current.tint(AppPalette.current.card, .05)
                      : AppPalette.current.tint(AppPalette.current.card, .75)),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? accent
                    : (AppPalette.current.border),
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Column(
              children: [
                _themePreview(mode),
                SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 13, color: labelColor),
                    SizedBox(width: 5),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Tiny wire-frame screen so the theme choice reads at a glance.
  Widget _themePreview(ThemeMode mode) {
    Widget face({required Color bg, required Color bar, Border? border}) {
      return Container(
        height: 46,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: border,
        ),
        padding: EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              height: 6,
              decoration: BoxDecoration(
                color: bar,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            SizedBox(height: 5),
            Container(
              width: double.infinity,
              height: 5,
              decoration: BoxDecoration(
                color: bar,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            SizedBox(height: 4),
            Container(
              width: 26,
              height: 5,
              decoration: BoxDecoration(
                color: bar,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
      );
    }

    final darkFace = AppPalette.current.background;
    final dark = face(bg: darkFace, bar: AppPalette.current.tint(AppPalette.current.onScrim, 0.24));
    final light = face(
      bg: AppPalette.current.card,
      bar: AppPalette.current.tint(AppPalette.current.border, 0.12),
      border: Border.all(color: AppPalette.current.tint(AppPalette.current.border, 0.12)),
    );

    if (mode == ThemeMode.system) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [Expanded(child: dark), Expanded(child: light)],
        ),
      );
    }
    return mode == ThemeMode.dark ? dark : light;
  }

  // ---------------------------------------------------------------------------
  // About
  // ---------------------------------------------------------------------------
  Widget _aboutCard(
    BuildContext context,
    bool isDark,
    Color accent,
    Color secondaryText,
  ) {
    return _glass(
      isDark: isDark,
      accent: accent,
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: .25),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset('assets/images/app_logo.png'),
                ),
              ),
              SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'All in One',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: context.palette.textPrimary,
                      ),
                    ),
                    SizedBox(height: 3),
                    FutureBuilder<String?>(
                      future: installedAndroidVersion,
                      builder: (context, snapshot) {
                        final version = snapshot.data;
                        if (version == null) {
                          return Text(
                            'Media Browser & Downloader',
                            style: TextStyle(
                              color: secondaryText,
                              fontSize: 11,
                            ),
                          );
                        }
                        return Text(
                          'v$version',
                          style: TextStyle(
                            color: context.palette.info,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _actionTile(
                  icon: Icons.system_update_rounded,
                  label: 'Check for updates',
                  color: accent,
                  onTap: () => _checkForUpdates(context),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: _actionTile(
                  icon: Icons.person_outline_rounded,
                  label: 'Developer',
                  color: context.palette.primary,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DeveloperScreen(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: .22)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: color),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared primitives
  // ---------------------------------------------------------------------------
  Widget _ambientBackground(Color accent, bool isDark) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [AppPalette.current.background, AppPalette.current.background, AppPalette.current.background]
              : [AppPalette.current.background, AppPalette.current.tint(AppPalette.current.primary, 0.04), AppPalette.current.background],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: -120,
            top: -80,
            child: _orb(accent.withValues(alpha: .20), 320),
          ),
          Positioned(
            right: -130,
            bottom: -140,
            child: _orb(AppPalette.current.tint(AppPalette.current.primary, .16), 360),
          ),
        ],
      ),
    ),
  );

  Widget _orb(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );

  Widget _glass({
    required bool isDark,
    required Color accent,
    required Widget child,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(20)),
    double blur = 14,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: AppPalette.current.shadowAt(isDark ? .28 : .07),
            blurRadius: 20,
            spreadRadius: -8,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: isDark ? AppPalette.current.tint(AppPalette.current.card, 0.086) : AppPalette.current.tint(AppPalette.current.card, 0.659),
              borderRadius: borderRadius,
              border: Border.all(
                color: isDark
                    ? AppPalette.current.tint(AppPalette.current.card, 0.133)
                    : AppPalette.current.tint(AppPalette.current.card, 0.600),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _iconTile(IconData icon, Color color) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: color.withValues(alpha: .20)),
    ),
    child: Icon(icon, color: color, size: 21),
  );

  Widget _sectionTitle(String title, IconData icon, Color accent) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accent.withValues(alpha: .20)),
          ),
          child: Icon(icon, size: 15, color: accent),
        ),
        SizedBox(width: 10),
        Flexible(
          flex: 3,
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: AppPalette.current.textPrimary,
            ),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Container(height: 1, color: AppPalette.current.border),
        ),
      ],
    );
  }

  Widget _gradientButton({
    required IconData icon,
    required String label,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [accent, accent.withValues(alpha: .72)],
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: .25),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: AppPalette.current.textPrimary),
              SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: AppPalette.current.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _squareButton({
    required IconData icon,
    required Color accent,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final child = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: accent.withValues(alpha: .22)),
          ),
          child: Icon(icon, size: 18, color: accent),
        ),
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip, child: child);
  }

  Widget _textButton({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: .22)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingCard({
    required bool isDark,
    required Color accent,
    required Color secondaryText,
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final card = _glass(
      isDark: isDark,
      accent: accent,
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          _iconTile(icon, iconColor),
          SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...[
                  SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: secondaryText, fontSize: 12, height: 1.35),
                  ),
                ],
              ],
            ),
          ),
          trailing ?? SizedBox.shrink(),
        ],
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: card,
        ),
      );
    }
    return card;
  }
}
