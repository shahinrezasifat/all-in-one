import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/site_model.dart';
import 'screens/browser_screen.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/movie_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/vault_screen.dart';
import 'services/download_manager.dart';
import 'services/player_service.dart';
import 'services/movie_repository_service.dart';
import 'services/settings_service.dart';
import 'services/preference_service.dart';
import 'services/trending_engine_service.dart';
import 'services/system_ui_service.dart';
import 'services/yt_dlp_service.dart';
import 'services/vault_service.dart';
import 'services/virtual_folder_service.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'widgets/storage_permission_gate.dart';
import 'widgets/youtube_popup_player.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webview_win_floating/webview_plugin.dart';
import 'package:fvp/fvp.dart' as fvp;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && Platform.isAndroid) {
    // Keep the status bar, hide the bottom system navigation/gesture bar. The
    // app draws its own floating navigation pill, so the extra system "shape"
    // underneath it is unwanted.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top],
    );
  }
  if (!kIsWeb && (Platform.isLinux || Platform.isWindows)) {
    WindowsWebViewPlatform.registerWith();
  }
  // fvp (libmpv/MDK) backs `video_player` on desktop only. Mobile keeps the
  // native ExoPlayer/AVPlayer. On Linux the default hardware decoder chain
  // (VAAPI/CUDA/VDPAU) maps GPU surfaces into the GL renderer, which segfaults
  // the whole process on many NVIDIA/desktop-GL setups the moment the first
  // frame is presented. Forcing pure software decoding avoids that crash and
  // keeps in-app movie/video playback stable.
  try {
    fvp.registerWith(
      options: {
        'platforms': ['windows', 'linux', 'macos'],
        if (Platform.isLinux) 'video.decoders': ['FFmpeg', 'dav1d'],
      },
    );
  } catch (e) {
    debugPrint('fvp registration notice: $e');
  }
  // Warm up EVERY persisted, lazily-initialized service at startup. Touching
  // `.ready` triggers each one-time init: repositories load from disk, seeding
  // & migrations run, background manifest syncs start, and download/vault/
  // settings indexes are restored. Doing this here (instead of only when a
  // screen opens) guarantees persisted user configuration is live before any
  // UI reads it, and eliminates the empty-list lazy-init races.
  MovieRepositoryService.instance.ready.then((_) {});
  DownloadManager.instance.ready.then((_) {});
  // Once BOTH the download index and the folder lists are restored, drop
  // folder ids whose task is gone — a folder tile must never count files
  // that no longer exist (stale leftovers from older deletions).
  Future.wait([
    DownloadManager.instance.ready,
    VirtualFolderService.instance.ready,
  ]).then((_) => VirtualFolderService.instance.syncWithStoredTasks());
  SettingsService.instance.ready.then((_) {});
  VaultService.instance.ready.then((_) {});
  PreferenceService.instance.ready.then((_) {});
  // Always-on personalized trending engine: remembers searched channels, keeps
  // a non-repeating candidate pool warm and refreshes it on a timer/lifecycle.
  TrendingEngineService.instance.startBackground();
  // Warm the on-device yt-dlp engine early. Idempotent + non-blocking; the
  // first call may extract/download binaries, so never await it on the UI path.
  YtDlpService.instance.ensureInit();
  runApp(const TubPureApp());
}

class TubPureApp extends StatelessWidget {
  const TubPureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SettingsService.instance,
      builder: (context, _) {
        final settings = SettingsService.instance;
        return MaterialApp(
          title: 'All in One',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: settings.themeMode,
          scrollBehavior: const MaterialScrollBehavior().copyWith(
            dragDevices: {
              PointerDeviceKind.mouse,
              PointerDeviceKind.touch,
              PointerDeviceKind.stylus,
              PointerDeviceKind.trackpad,
            },
          ),
          home: const StoragePermissionGate(child: MainNavigationScreen()),
        );
      },
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  @override
  void initState() {
    super.initState();
    // Hide the OS bottom gesture pill; only our floating nav pill remains.
    SystemUiService.instance.start();
  }

  int _currentIndex = 0;
  String? _searchQuery;
  SiteModel? _activeBrowserSite;

  void _navigateToSearch(String query) {
    setState(() {
      _searchQuery = query;
      _activeBrowserSite = null;
      _currentIndex = 0; // Merged Home & Explore
    });
  }

  void _openBrowser(SiteModel site) {
    setState(() {
      _activeBrowserSite = site;
      _currentIndex = 0;
    });
  }

  void _closeBrowser() {
    setState(() {
      _activeBrowserSite = null;
    });
  }

  void _selectTab(int index) {
    HapticFeedback.selectionClick();
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        MediaQuery.of(context).size.width >= 800 &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final Widget mainTabContent = _activeBrowserSite != null
        ? BrowserScreen(
            key: ValueKey(_activeBrowserSite!.url),
            initialSite: _activeBrowserSite!,
            onCloseBrowser: _closeBrowser,
          )
        : HomeScreen(
            key: ValueKey(_searchQuery),
            onSearchQuery: _navigateToSearch,
            onOpenBrowser: _openBrowser,
            initialQuery: _searchQuery,
          );

    final screens = [
      mainTabContent,
      const VaultScreen(),
      const MovieScreen(),
      const DownloadsScreen(),
      const SettingsScreen(),
    ];

    final content = IndexedStack(
      index: _currentIndex,
      children: [
        for (var index = 0; index < screens.length; index++)
          TickerMode(enabled: index == _currentIndex, child: screens[index]),
      ],
    );

    if (isDesktop) {
      // Minimal vertical side rail — quiet surface, one soft active pill.
      return Scaffold(
        body: Row(
          children: [
            _buildSideRail(isDark),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              child: Stack(children: [content, const YouTubePopupPlayer()]),
            ),
          ],
        ),
      );
    }

    // The navigation is a true floating pill layered over the content — no
    // docked bar, no separator line. Screens get a bottom inset so nothing is
    // hidden behind it, and the pill itself lifts above the system gesture area.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        extendBody: true,
        body: Stack(
          fit: StackFit.expand,
          children: [content, const YouTubePopupPlayer(miniPlayerBottom: 104)],
        ),
        bottomNavigationBar: ListenableBuilder(
          listenable: PlayerService.instance,
          builder: (context, child) => PlayerService.instance.isExpanded
              ? const SizedBox.shrink()
              : child!,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Container(
                    height: 68,
                    decoration: BoxDecoration(
                      color: (isDark ? AppColors.darkCard : Colors.white)
                          .withValues(alpha: isDark ? 0.90 : 0.93),
                      borderRadius: BorderRadius.circular(34),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.55 : 0.16,
                          ),
                          blurRadius: 14,
                          spreadRadius: -6,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(34),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                        child: Row(
                          children: [
                            _navItem(
                              0,
                              Icons.home_outlined,
                              Icons.home_rounded,
                              'Home',
                            ),
                            _navItem(
                              1,
                              Icons.lock_outline_rounded,
                              Icons.lock_rounded,
                              'Vault',
                            ),
                            _navItem(
                              2,
                              Icons.movie_outlined,
                              Icons.movie_rounded,
                              'Movies',
                            ),
                            _navItem(
                              3,
                              Icons.download_outlined,
                              Icons.download_rounded,
                              'Downloads',
                              showBadge: true,
                            ),
                            _navItem(
                              4,
                              Icons.settings_outlined,
                              Icons.settings_rounded,
                              'Settings',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Desktop side rail
  // ---------------------------------------------------------------------------
  Widget _buildSideRail(bool isDark) {
    return Container(
      width: 96,
      color: isDark ? AppColors.darkCard : AppColors.lightCard,
      child: Column(
        children: [
          const SizedBox(height: 22),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(
              Icons.bolt_rounded,
              color: AppColors.primary,
              size: 22,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Tub',
            style: TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 18),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _railItem(0, Icons.home_outlined, Icons.home_rounded, 'Home'),
                  _railItem(
                    1,
                    Icons.lock_outline_rounded,
                    Icons.lock_rounded,
                    'Vault',
                  ),
                  _railItem(
                    2,
                    Icons.movie_outlined,
                    Icons.movie_rounded,
                    'Movies',
                  ),
                  _railItem(
                    3,
                    Icons.download_outlined,
                    Icons.download_rounded,
                    'Downloads',
                    showBadge: true,
                  ),
                  _railItem(
                    4,
                    Icons.settings_outlined,
                    Icons.settings_rounded,
                    'Settings',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _railItem(
    int index,
    IconData icon,
    IconData activeIcon,
    String label, {
    bool showBadge = false,
  }) {
    final selected = _currentIndex == index;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white54 : Colors.black45;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _selectTab(index),
          borderRadius: BorderRadius.circular(14),
          splashColor: AppColors.primary.withValues(alpha: 0.10),
          highlightColor: AppColors.primary.withValues(alpha: 0.05),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.primary.withValues(alpha: isDark ? 0.16 : 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _navIcon(icon, activeIcon, selected, muted, showBadge, isDark),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    color: selected ? AppColors.primary : muted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 10,
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
  // Mobile bottom bar item
  // ---------------------------------------------------------------------------
  Widget _navItem(
    int index,
    IconData icon,
    IconData activeIcon,
    String label, {
    bool showBadge = false,
  }) {
    final selected = _currentIndex == index;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white54 : Colors.black45;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _selectTab(index),
          splashColor: AppColors.primary.withValues(alpha: 0.10),
          highlightColor: AppColors.primary.withValues(alpha: 0.05),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  width: 46,
                  height: 30,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.primary.withValues(
                            alpha: isDark ? 0.20 : 0.14,
                          )
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _navIcon(
                    icon,
                    activeIcon,
                    selected,
                    muted,
                    showBadge,
                    isDark,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? AppColors.primary : muted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 10,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Shared icon + optional live download badge for both navigation layouts.
  Widget _navIcon(
    IconData icon,
    IconData activeIcon,
    bool selected,
    Color muted,
    bool showBadge,
    bool isDark,
  ) {
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        AnimatedScale(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutBack,
          scale: selected ? 1.08 : 1.0,
          child: Icon(
            selected ? activeIcon : icon,
            size: 21,
            color: selected ? AppColors.primary : muted,
          ),
        ),
        if (showBadge)
          AnimatedBuilder(
            animation: DownloadManager.instance,
            builder: (context, _) {
              final count = DownloadManager.instance.activeTasks.length;
              if (count <= 0) return const SizedBox.shrink();
              return Positioned(
                right: -3,
                top: -4,
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accentRed,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    count > 9 ? '9+' : '$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
