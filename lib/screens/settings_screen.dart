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
import '../services/player_service.dart';
import '../services/settings_service.dart';
import '../services/vault_service.dart';
import '../theme/app_colors.dart';
import '../widgets/permission_dialog.dart';
import 'developer_screen.dart';
import 'vault_screen.dart';
import 'zangetsu_providers_hub_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const String _githubUsername = 'shahinrezasifat1999';
  static const String _githubProfile = 'https://github.com/$_githubUsername';

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
        .showSnackBar(const SnackBar(content: Text('Could not open GitHub.')));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.primaryLight : AppColors.primary;
    final secondaryText = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    return AnimatedBuilder(
      animation: Listenable.merge([
        SettingsService.instance,
        DownloadManager.instance,
        MovieRepositoryService.instance,
        VaultService.instance,
      ]),
      builder: (context, _) {
        final settings = SettingsService.instance;
        final downloadMgr = DownloadManager.instance;
        final vaultService = VaultService.instance;

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            title: const Text(
              'Settings & Pro Config',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            flexibleSpace: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  color: isDark
                      ? Colors.black.withValues(alpha: .28)
                      : Colors.white.withValues(alpha: .52),
                ),
              ),
            ),
          ),
          body: Stack(
            children: [
              Positioned.fill(child: _ambientBackground(accent, isDark)),
              SafeArea(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    24 + MediaQuery.paddingOf(context).bottom,
                  ),
                  children: [
                    _developerCard(context, accent, isDark),
                    const SizedBox(height: 24),

                    _sectionTitle(
                      'Storage & Permissions',
                      Icons.storage_rounded,
                      accent,
                    ),
                    const SizedBox(height: 10),
                    _permissionCard(isDark, accent, secondaryText, downloadMgr),
                    const SizedBox(height: 10),

                    _buildSettingCard(
                      isDark: isDark,
                      accent: accent,
                      secondaryText: secondaryText,
                      icon: Icons.folder_rounded,
                      iconColor: accent,
                      title: 'Download Location',
                      subtitle: downloadMgr.downloadDirectory,
                      trailing: TextButton(
                        onPressed: () {
                          PlayerService.instance.launchSystemPlayer(
                            downloadMgr.downloadDirectory,
                          );
                        },
                        child: Text(
                          'Open Folder',
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    _buildCacheCard(isDark, accent, secondaryText),
                    const SizedBox(height: 10),

                    _buildSettingCard(
                      isDark: isDark,
                      accent: accent,
                      secondaryText: secondaryText,
                      icon: Icons.speed_rounded,
                      iconColor: AppColors.accentGreen,
                      title: 'Max Concurrent Downloads',
                      subtitle: '${settings.maxConcurrent} parallel downloads',
                      trailing: DropdownButton<int>(
                        value: settings.maxConcurrent,
                        underline: const SizedBox.shrink(),
                        items: [1, 2, 3, 4, 5].map((val) {
                          return DropdownMenuItem<int>(
                            value: val,
                            child: Text('$val'),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) settings.setMaxConcurrent(val);
                        },
                      ),
                    ),
                    const SizedBox(height: 10),

                    _buildSettingCard(
                      isDark: isDark,
                      accent: accent,
                      secondaryText: secondaryText,
                      icon: Icons.high_quality_rounded,
                      iconColor: AppColors.accentGold,
                      title: 'Default Video Quality',
                      subtitle: settings.defaultVideoQuality,
                      trailing: DropdownButton<String>(
                        value: settings.defaultVideoQuality,
                        underline: const SizedBox.shrink(),
                        items:
                            [
                              'Ask Every Time',
                              '4K Ultra HD',
                              '1080p Full HD',
                              '720p HD',
                              '480p SD',
                            ].map((val) {
                              return DropdownMenuItem<String>(
                                value: val,
                                child: Text(
                                  val,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              );
                            }).toList(),
                        onChanged: (val) {
                          if (val != null) settings.setDefaultVideoQuality(val);
                        },
                      ),
                    ),
                    const SizedBox(height: 10),

                    _buildSettingCard(
                      isDark: isDark,
                      accent: accent,
                      secondaryText: secondaryText,
                      icon: Icons.audiotrack_rounded,
                      iconColor: AppColors.accentPurple,
                      title: 'Default Audio Format',
                      subtitle: settings.defaultAudioFormat,
                      trailing: DropdownButton<String>(
                        value: settings.defaultAudioFormat,
                        underline: const SizedBox.shrink(),
                        items:
                            [
                              '320 kbps MP3',
                              '256 kbps MP3',
                              '128 kbps MP3',
                              'M4A (AAC)',
                            ].map((val) {
                              return DropdownMenuItem<String>(
                                value: val,
                                child: Text(
                                  val,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              );
                            }).toList(),
                        onChanged: (val) {
                          if (val != null) settings.setDefaultAudioFormat(val);
                        },
                      ),
                    ),
                    const SizedBox(height: 24),

                    _sectionTitle(
                      'Content Repositories & Scrapers',
                      Icons.extension_rounded,
                      accent,
                    ),
                    const SizedBox(height: 10),

                    _buildSettingCard(
                      isDark: isDark,
                      accent: accent,
                      secondaryText: secondaryText,
                      icon: Icons.movie_filter_rounded,
                      iconColor: const Color(0xFFFF4D57),
                      title: 'Provider Hub',
                      subtitle: 'Repositories and extensions',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ZangetsuProvidersHubScreen(),
                          ),
                        );
                      },
                      trailing: _pillButton(
                        label: 'Manage',
                        icon: Icons.tune_rounded,
                        accent: accent,
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const ZangetsuProvidersHubScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 24),

                    _sectionTitle(
                      'Privacy & Security',
                      Icons.shield_rounded,
                      accent,
                    ),
                    const SizedBox(height: 10),

                    _buildSettingCard(
                      isDark: isDark,
                      accent: accent,
                      secondaryText: secondaryText,
                      icon: Icons.visibility_outlined,
                      iconColor: AppColors.accentRed,
                      title: '18+ repositories',
                      subtitle: 'Show the 18+ category in Provider Hub',
                      trailing: Switch(
                        value: settings.showAdultRepositories,
                        onChanged: settings.setShowAdultRepositories,
                        activeThumbColor: accent,
                      ),
                    ),
                    const SizedBox(height: 10),

                    _buildSettingCard(
                      isDark: isDark,
                      accent: accent,
                      secondaryText: secondaryText,
                      icon: Icons.lock_rounded,
                      iconColor: AppColors.accentGold,
                      title: 'Secret Vault (Private Media Locker)',
                      subtitle: vaultService.hasPin
                          ? 'Protected with 4-Digit PIN • ${vaultService.items.length} files saved'
                          : 'PIN not configured • Tap to setup and protect private media',
                      trailing: _pillButton(
                        label: 'Open Vault',
                        icon: Icons.lock_open_rounded,
                        accent: accent,
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const VaultScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 24),

                    _sectionTitle(
                      'Appearance & Theme',
                      Icons.palette_rounded,
                      accent,
                    ),
                    const SizedBox(height: 10),

                    _glass(
                      isDark: isDark,
                      accent: accent,
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _iconTile(
                                Icons.palette_rounded,
                                AppColors.accentBlue,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Theme Mode',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      settings.themeMode == ThemeMode.dark
                                          ? 'Dark OLED (Optimized)'
                                          : (settings.themeMode ==
                                                    ThemeMode.light
                                                ? 'Light Mode'
                                                : 'System Default'),
                                      style: TextStyle(
                                        color: secondaryText,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<ThemeMode>(
                              segments: const [
                                ButtonSegment(
                                  value: ThemeMode.dark,
                                  tooltip: 'Dark mode',
                                  icon: Icon(Icons.dark_mode, size: 16),
                                  label: Text('Dark'),
                                ),
                                ButtonSegment(
                                  value: ThemeMode.light,
                                  tooltip: 'Light mode',
                                  icon: Icon(Icons.light_mode, size: 16),
                                  label: Text('Light'),
                                ),
                              ],
                              selected: {
                                settings.themeMode == ThemeMode.light
                                    ? ThemeMode.light
                                    : ThemeMode.dark,
                              },
                              onSelectionChanged: (val) {
                                settings.setThemeMode(val.first);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    _sectionTitle(
                      'About All in One',
                      Icons.info_outline_rounded,
                      accent,
                    ),
                    const SizedBox(height: 10),

                    _aboutCard(context, accent, isDark, secondaryText),
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
  // Glass primitives
  // ---------------------------------------------------------------------------
  Widget _ambientBackground(Color accent, bool isDark) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF10101B), Color(0xFF141120), Color(0xFF0C1119)]
              : const [Color(0xFFF7F4FF), Color(0xFFF3F7F5), Color(0xFFFDF4F7)],
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
            child: _orb(AppColors.accentPurple.withValues(alpha: .16), 360),
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
            color: Colors.black.withValues(alpha: isDark ? .28 : .07),
            blurRadius: 20,
            spreadRadius: -8,
            offset: const Offset(0, 8),
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
              color: isDark ? const Color(0x16FFFFFF) : const Color(0xA8FFFFFF),
              borderRadius: borderRadius,
              border: Border.all(
                color: isDark
                    ? const Color(0x22FFFFFF)
                    : const Color(0x99FFFFFF),
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

  Widget _pillButton({
    required String label,
    required IconData icon,
    required Color accent,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [accent, accent.withValues(alpha: .72)],
            ),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: .28),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // About card — modern, tidy, with a clear developer entry
  // ---------------------------------------------------------------------------
  Widget _aboutCard(
    BuildContext context,
    Color accent,
    bool isDark,
    Color secondaryText,
  ) {
    return _glass(
      isDark: isDark,
      accent: accent,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: .28),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  color: Colors.white,
                  size: 25,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'All in One',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        color: isDark
                            ? Colors.white
                            : AppColors.lightTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Media Browser & Downloader',
                      style: TextStyle(
                        color: secondaryText,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              FutureBuilder<String?>(
                future: installedAndroidVersion,
                builder: (context, snapshot) {
                  final version = snapshot.data;
                  if (version == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      'v$version',
                      style: const TextStyle(
                        color: AppColors.accentGold,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Download videos from the web, stream movies from integrated '
            'sources, and protect personal media in a private vault with '
            'biometric unlock.',
            style: TextStyle(color: secondaryText, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _aboutFeature(
                  Icons.layers_rounded,
                  'Cross-Platform',
                  'Android · PC · Web',
                  accent,
                  secondaryText,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _aboutFeature(
                  Icons.verified_rounded,
                  '100% Unlocked',
                  'No ads · No tracking',
                  AppColors.accentGreen,
                  secondaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DeveloperScreen(),
                ),
              ),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: accent.withValues(alpha: .22)),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 17,
                      backgroundColor: accent.withValues(alpha: .16),
                      child: Icon(
                        Icons.person_outline_rounded,
                        size: 17,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Developer',
                            style: TextStyle(
                              color: isDark
                                  ? Colors.white
                                  : AppColors.lightTextPrimary,
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            'Profile, GitHub & contact',
                            style: TextStyle(
                              color: secondaryText,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: accent),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aboutFeature(
    IconData icon,
    String title,
    String subtitle,
    Color color,
    Color secondaryText,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .18)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondaryText, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Modern developer profile card
  // ---------------------------------------------------------------------------
  Widget _developerCard(BuildContext context, Color accent, bool isDark) {
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final nameColor = isDark ? Colors.white : AppColors.lightTextPrimary;

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
        final description = profile?.bio?.trim().isNotEmpty == true
            ? profile!.bio!.trim()
            : 'Full-Stack Software Developer, Creative Director & Founder of Motion Work';

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openGithub(context),
            borderRadius: BorderRadius.circular(26),
            child: _developerCardBody(
              accent,
              isDark,
              secondary,
              nameColor,
              avatarUrl,
              name,
              description,
            ),
          ),
        );
      },
    );
  }

  Widget _developerCardBody(
    Color accent,
    bool isDark,
    Color secondary,
    Color nameColor,
    Uri avatarUrl,
    String name,
    String description,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [const Color(0xFF1C7957), const Color(0xFF141420)]
                    : [const Color(0xFFECF0FF), const Color(0xFFFDF4F7)],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: accent.withValues(alpha: .24)),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: .12),
                  blurRadius: 22,
                  spreadRadius: -8,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(2.5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppColors.primaryGradient,
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: .32),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: CircleAvatar(
                        radius: 30,
                        backgroundColor: isDark
                            ? const Color(0xFF1E293B)
                            : Colors.white,
                        child: ClipOval(
                          child: Image.network(
                            avatarUrl.toString(),
                            width: 60,
                            height: 60,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) => Text(
                              'SR',
                              style: TextStyle(
                                color: accent,
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: nameColor,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: .14),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: accent.withValues(alpha: .28),
                              ),
                            ),
                            child: Text(
                              'DEVELOPER',
                              style: TextStyle(
                                color: accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .8,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: secondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 14),
                // GitHub link — forced LTR so the URL never renders reversed
                // under a Bengali/RTL locale.
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: accent.withValues(alpha: .20)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.code_rounded, size: 15, color: accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'github.com/$_githubUsername',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.open_in_new_rounded,
                          size: 14,
                          color: accent,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: -50,
            top: -70,
            child: _orb(accent.withValues(alpha: .20), 190),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section title
  // ---------------------------------------------------------------------------
  Widget _sectionTitle(String title, IconData icon, Color accent) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accent.withValues(alpha: .20)),
          ),
          child: Icon(icon, size: 16, color: accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: accent,
              letterSpacing: .3,
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Permission card
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
            ? AppColors.accentGreen
            : AppColors.accentGold;

        return _glass(
          isDark: isDark,
          accent: accent,
          padding: const EdgeInsets.all(16),
          borderRadius: BorderRadius.circular(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      storageOk
                          ? Icons.verified_user_rounded
                          : Icons.gpp_maybe_rounded,
                      color: statusColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Storage & Device Permissions',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          storageOk
                              ? 'Downloads accessible in Gallery/VLC'
                              : 'Storage permission required to save downloads',
                          style: TextStyle(color: secondaryText, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      storageOk ? 'Active' : 'Action Needed',
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _permBadge(
                    'Storage',
                    storageOk,
                    Icons.folder_rounded,
                    isDark,
                  ),
                  const SizedBox(width: 8),
                  _permBadge(
                    'Notifications',
                    notifOk,
                    Icons.notifications_rounded,
                    isDark,
                  ),
                  const SizedBox(width: 8),
                  _permBadge(
                    isPublic ? 'Public /Download' : 'App Storage',
                    isPublic,
                    Icons.sd_card_rounded,
                    isDark,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () async {
                          await PermissionDialog.show(context);
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [accent, accent.withValues(alpha: .72)],
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(
                                Icons.security_update_good_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Grant All Permissions',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        PermissionService.instance.openSettings();
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 14,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: accent.withValues(alpha: .24),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.settings_rounded,
                              size: 16,
                              color: accent,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Settings',
                              style: TextStyle(
                                color: accent,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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
    final color = isOk ? AppColors.accentGreen : AppColors.accentGold;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: .05)
              : Colors.white.withValues(alpha: .7),
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
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white70 : Colors.black87,
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

  // ---------------------------------------------------------------------------
  // Cache card with a live usage bar
  // ---------------------------------------------------------------------------
  Widget _buildCacheCard(bool isDark, Color accent, Color secondaryText) {
    return FutureBuilder<int>(
      future: () async {
        await ImageCacheService.instance.init();
        return ImageCacheService.instance.diskBytesUsed;
      }(),
      builder: (context, snap) {
        final used = snap.data ?? ImageCacheService.instance.diskBytesUsed;
        final mb = used / 1048576;
        final pct = (used / ImageCacheService.maxDiskBytes * 100).clamp(0, 100);

        return _glass(
          isDark: isDark,
          accent: accent,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.accentGreen.withValues(alpha: .20),
                      ),
                    ),
                    child: const Icon(
                      Icons.bolt_rounded,
                      color: AppColors.accentGreen,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Instant-Load Cache',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${mb < 1 ? "${(used / 1024).toStringAsFixed(0)} KB" : "${mb.toStringAsFixed(1)} MB"} of 50 MB used • posters preloaded',
                          style: TextStyle(color: secondaryText, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await ImageCacheService.instance.clear();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Cache cleared — art will re-download as you browse.',
                            ),
                          ),
                        );
                      }
                    },
                    child: const Text(
                      'Clear',
                      style: TextStyle(
                        color: Color(0xFFFF4D57),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct / 100,
                  minHeight: 6,
                  color: AppColors.accentGreen,
                  backgroundColor: AppColors.accentGreen.withValues(alpha: .14),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${pct.toStringAsFixed(0)}%',
                  style: TextStyle(
                    color: secondaryText,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Generic setting card
  // ---------------------------------------------------------------------------
  Widget _buildSettingCard({
    required bool isDark,
    required Color accent,
    required Color secondaryText,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final card = _glass(
      isDark: isDark,
      accent: accent,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: iconColor.withValues(alpha: .20)),
            ),
            child: Icon(icon, color: iconColor, size: 21),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondaryText, fontSize: 12),
                ),
              ],
            ),
          ),
          trailing ?? const SizedBox.shrink(),
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
