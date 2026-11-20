import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../models/video_item.dart';
import '../services/bookmark_service.dart';
import '../services/download_manager.dart';
import '../services/system_ui_service.dart';
import '../services/player_service.dart';
import '../services/playback_controls.dart';
import '../services/search_service.dart';
import '../theme/app_colors.dart';
import 'analyze_download_flow.dart';
import 'remote_image.dart';

class _PlayerCaptions implements ClosedCaptionFile {
  const _PlayerCaptions(this.captions);

  @override
  final List<Caption> captions;
}

class YouTubePopupPlayer extends StatefulWidget {
  const YouTubePopupPlayer({super.key, this.miniPlayerBottom = 112});

  final double miniPlayerBottom;

  @override
  State<YouTubePopupPlayer> createState() => _YouTubePopupPlayerState();
}

class _YouTubePopupPlayerState extends State<YouTubePopupPlayer>
    with SingleTickerProviderStateMixin {
  bool _showControls = true;
  bool _fullscreen = false;
  final _zoom = ValueNotifier<double>(1);
  final _touches = <int, Offset>{};
  bool _pinching = false;
  double _pinchDistance = 0;
  double _pinchZoom = 1;

  double get _fingerDistance =>
      (_touches.values.first - _touches.values.elementAt(1)).distance;

  void _touchStart(PointerDownEvent event, PlayerService player) {
    if (_touches.isEmpty) _pinching = false;
    _touches[event.pointer] = event.position;
    if (_touches.length != 2 || player.isLocked) return;
    _pinching = true;
    _pinchDistance = _fingerDistance;
    _pinchZoom = _zoom.value;
    if (_previewFor(player) != null) _finishSeek(player, commit: false);
  }

  void _touchMove(PointerMoveEvent event, PlayerService player) {
    if (!_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.position;
    if (!_pinching ||
        player.isLocked ||
        _touches.length != 2 ||
        _pinchDistance <= 0)
      return;
    _zoom.value = (_pinchZoom * _fingerDistance / _pinchDistance).clamp(
      _fullscreen ? .6 : 1.0,
      3.0,
    );
  }

  void _touchEnd(PointerEvent event) {
    _touches.remove(event.pointer);
    if (_touches.length == 2) {
      _pinchDistance = _fingerDistance;
      _pinchZoom = _zoom.value;
    }
  }

  bool _settingsExpanded = false;
  bool _showCaptions = false;
  bool _loadingCaptions = false;
  String? _upNextUrl;
  Future<List<VideoItem>>? _upNext;

  Future<List<VideoItem>>? _recommendationsFor(VideoItem? current) {
    if (_upNextUrl != current?.videoUrl) {
      _upNextUrl = current?.videoUrl;
      _upNext = current == null
          ? null
          : SearchService.instance.getUpNext(current);
    }
    return _upNext;
  }

  /// Re-fetch the Up next list for the current video (used by the retry button
  /// when the first attempt came back empty).
  void _retryUpNext() {
    final current = PlayerService.instance.currentItem;
    if (current == null) return;
    setState(() {
      // Clear the cache key so _recommendationsFor starts a fresh future.
      _upNextUrl = null;
      _upNext = null;
    });
    // Force a rebuild on the next frame so the FutureBuilder re-subscribes.
    _recommendationsFor(current);
    setState(() {});
  }

  Future<void> _requestOrientation(bool fullscreen) async {
    if (!const [
      TargetPlatform.android,
      TargetPlatform.iOS,
    ].contains(defaultTargetPlatform))
      return;
    await SystemChrome.setEnabledSystemUIMode(
      fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    await SystemChrome.setPreferredOrientations(
      fullscreen
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
    if (!fullscreen) await SystemUiService.instance.hideBottomBar();
  }

  void _setFullscreen(bool fullscreen) {
    _zoom.value = 1;
    setState(() => _fullscreen = fullscreen);
    unawaited(_requestOrientation(fullscreen));
  }

  void _restoreOrientationIfHidden() {
    if (!PlayerService.instance.isExpanded) {
      unawaited(_playbackControls.restoreBrightness());
    }
    if (_fullscreen && !PlayerService.instance.isExpanded)
      _setFullscreen(false);
  }

  double? _seekPreview;
  double? _dragOrigin;
  double _dragDistance = 0;
  String? _seekMedia;

  double? _previewFor(PlayerService player) =>
      _seekMedia == (player.currentItem?.videoUrl ?? player.filePath)
      ? _seekPreview
      : null;

  void _previewSeek(PlayerService player, double seconds) {
    setState(() {
      _seekMedia = player.currentItem?.videoUrl ?? player.filePath;
      _seekPreview = seconds.clamp(0.0, player.totalSeconds);
    });
  }

  void _finishSeek(PlayerService player, {bool commit = true}) {
    final seconds = _previewFor(player);
    setState(() {
      _seekPreview = null;
      _seekMedia = null;
      _dragOrigin = null;
    });
    if (commit && !player.isLocked && seconds != null) player.seek(seconds);
  }

  String _seekTime(double seconds) {
    final value = seconds.toInt();
    final minutes = (value ~/ 60) % 60;
    final remainder = (value % 60).toString().padLeft(2, '0');
    if (value < 3600) return '$minutes:$remainder';
    return '${value ~/ 3600}:${minutes.toString().padLeft(2, '0')}:$remainder';
  }

  bool _isSubscribed = false;
  bool _isLiked = false;
  bool _isDisliked = false;

  // On-screen HUD state for MX-player style swipe gestures
  final _playbackControls = PlaybackControls();
  bool _brightnessGesture = false;
  bool _firstVerticalUpdate = true;
  double _volumeHud = 0.8;
  bool _showBrightnessHUD = false;
  bool _showVolumeHUD = false;
  Timer? _hudTimer;

  // Fast forward long press state (YouTube 2x style)
  bool _isFastForwarding = false;
  double _savedSpeedBeforeFastForward = 1.0;

  // Double tap skip indicator
  String? _doubleTapSide; // 'left' or 'right'
  Timer? _doubleTapTimer;

  // Audio wave visualizer animation
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    PlayerService.instance.addListener(_restoreOrientationIfHidden);
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    PlayerService.instance.removeListener(_restoreOrientationIfHidden);
    unawaited(_playbackControls.restoreBrightness());
    if (_fullscreen) unawaited(_requestOrientation(false));
    _hudTimer?.cancel();
    _doubleTapTimer?.cancel();
    _zoom.dispose();
    _waveController.dispose();
    super.dispose();
  }

  void _handleDownload(BuildContext context, String videoUrl) async {
    await analyzeAndPickFormat(context, url: videoUrl);
  }

  // ---------------------------------------------------------------------------
  // Advanced Settings Bottom Sheet (Comprehensive Options)
  // ---------------------------------------------------------------------------
  void _showQualityPicker(BuildContext context, PlayerService player) {
    final qualities = [
      'Auto (Adaptive)',
      '4K Ultra HD (2160p)',
      '1080p Full HD (60fps)',
      '720p HD',
      '480p SD',
      '360p Data Saver',
    ];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.tune_rounded,
                      color: AppColors.primary,
                      size: 20,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Select Video Quality',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              ...qualities.map((q) {
                final token = q.split(' ').first;
                final isSelected =
                    player.selectedQuality == token ||
                    (token == 'Auto' && player.selectedQuality.isEmpty);
                return ListTile(
                  title: Text(
                    q,
                    style: TextStyle(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.primary,
                        )
                      : null,
                  onTap: () {
                    player.setQuality(token);
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Switched quality to $q'),
                        duration: const Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  void _showSleepTimerPicker(BuildContext context, PlayerService player) {
    final options = [
      {'min': null, 'label': 'Turn Off Timer'},
      {'min': 15, 'label': '15 Minutes'},
      {'min': 30, 'label': '30 Minutes'},
      {'min': 45, 'label': '45 Minutes'},
      {'min': 60, 'label': '60 Minutes (1 Hour)'},
      {
        'min': (player.totalSeconds - player.currentSeconds) ~/ 60,
        'label': 'End of Current Video',
      },
    ];

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.timer_rounded,
                      color: AppColors.accentGold,
                      size: 20,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Set Sleep Timer',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              ...options.map((opt) {
                final min = opt['min'] as int?;
                final isSelected = player.sleepTimerMinutes == min;
                return ListTile(
                  title: Text(
                    opt['label'] as String,
                    style: TextStyle(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.accentGold,
                        )
                      : null,
                  onTap: () {
                    player.setSleepTimer(min != null && min > 0 ? min : null);
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          min != null && min > 0
                              ? 'Sleep timer set for $min minutes'
                              : 'Sleep timer turned off',
                        ),
                        duration: const Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Stats for Nerds Dialog
  // ---------------------------------------------------------------------------
  void _showStatsForNerds(BuildContext context, PlayerService player) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final resolution = player.engine?.value.size != null
        ? '${player.engine!.value.size.width.toInt()} x ${player.engine!.value.size.height.toInt()}'
        : player.selectedQuality;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF181B26) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.analytics_rounded, color: Colors.cyanAccent),
            SizedBox(width: 8),
            Text(
              'Stats for Nerds',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statRow('Video Title', player.title),
            _statRow('Resolution', resolution),

            _statRow('Playback Speed', '${player.playbackSpeed}x'),
            _statRow(
              'Audio Mode',
              player.isAudioOnly ? 'Audio Only (Stream)' : 'Full Video AV',
            ),
            _statRow(
              'Repeat / Loop',
              player.isLooping ? 'Enabled (Single Repeat)' : 'Off',
            ),
            _statRow(
              'Sleep Timer',
              player.sleepTimerMinutes != null
                  ? '${player.sleepTimerMinutes}m remaining'
                  : 'Inactive',
            ),
            _statRow(
              'Hardware Engine',
              player.isEngineActive
                  ? 'ExoPlayer / Native Decoder'
                  : 'Simulation Engine',
            ),
            _statRow('Ad Blocker', 'Active (100% VIP Protection)'),
            _statRow(
              'Current Position',
              '${player.positionFormatted} / ${player.durationFormatted}',
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Close',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Main Build Method
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PlayerService.instance,
      builder: (context, _) {
        final player = PlayerService.instance;
        if (player.isHidden || !player.hasMedia) {
          return const SizedBox.shrink();
        }

        final isDark = Theme.of(context).brightness == Brightness.dark;

        if (player.isMinimized) {
          return _buildMiniPlayer(context, player, isDark);
        }

        if (_fullscreen) {
          return Positioned.fill(
            child: PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _setFullscreen(false);
              },
              child: Material(
                color: Colors.black,
                child: _buildVideoSurface(context, player),
              ),
            ),
          );
        }

        // Expanded YouTube Player View (Portrait)
        final upNext = _recommendationsFor(player.currentItem);

        return Positioned.fill(
          child: GestureDetector(
            onVerticalDragEnd: (details) {
              if (details.primaryVelocity != null &&
                  details.primaryVelocity! > 300) {
                player.minimize();
              }
            },
            child: Material(
              color: isDark ? AppColors.darkBg : AppColors.lightBg,
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                            tooltip: 'Minimize video',
                            onPressed: player.minimize,
                          ),
                          const Expanded(
                            child: Text(
                              'Now playing',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 16:9 Video Player Surface with Gestures & HUD
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * .52,
                      ),
                      child: _buildVideoSurface(context, player),
                    ),

                    // Scrollable Video Details & Related Videos
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        children: [
                          // Title
                          Text(
                            player.title,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 6),

                          // Views & Upload Date
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  player.currentItem?.views ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isDark
                                        ? AppColors.darkTextSecondary
                                        : AppColors.lightTextSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),

                          // Channel Row
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: AppColors.primary.withValues(
                                  alpha: 0.2,
                                ),
                                child: Text(
                                  player.author.isNotEmpty
                                      ? player.author[0].toUpperCase()
                                      : 'Y',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            player.author,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              ElevatedButton(
                                onPressed: () {
                                  setState(() {
                                    _isSubscribed = !_isSubscribed;
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        _isSubscribed
                                            ? 'Subscribed to ${player.author}'
                                            : 'Unsubscribed',
                                      ),
                                      duration: const Duration(seconds: 1),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _isSubscribed
                                      ? Colors.grey.shade700
                                      : AppColors.primary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                ),
                                child: Text(
                                  _isSubscribed ? 'Subscribed' : 'Subscribe',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Advanced Action Buttons Row (Download, Audio Mode, Speed, Loop, Sleep Timer, Like, Share, Save)
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                // 1. Download
                                _buildActionButton(
                                  icon: Icons.download_rounded,
                                  label: 'Download',
                                  isHighlight: true,
                                  onTap: () =>
                                      _handleDownload(context, player.filePath),
                                ),
                                const SizedBox(width: 8),

                                // 6. Like Button
                                _buildActionButton(
                                  icon: _isLiked
                                      ? Icons.thumb_up_alt_rounded
                                      : Icons.thumb_up_alt_outlined,
                                  label: _isLiked ? '49K' : '48K',
                                  isActive: _isLiked,
                                  onTap: () {
                                    setState(() {
                                      _isLiked = !_isLiked;
                                      if (_isLiked) _isDisliked = false;
                                    });
                                    HapticFeedback.lightImpact();
                                  },
                                ),
                                const SizedBox(width: 8),

                                // 7. Dislike Button
                                _buildActionButton(
                                  icon: _isDisliked
                                      ? Icons.thumb_down_alt_rounded
                                      : Icons.thumb_down_alt_outlined,
                                  label: 'Dislike',
                                  isActive: _isDisliked,
                                  onTap: () {
                                    setState(() {
                                      _isDisliked = !_isDisliked;
                                      if (_isDisliked) _isLiked = false;
                                    });
                                  },
                                ),
                                const SizedBox(width: 8),

                                // 8. Share Button
                                _buildActionButton(
                                  icon: Icons.share_rounded,
                                  label: 'Share',
                                  onTap: () {
                                    Clipboard.setData(
                                      ClipboardData(text: player.filePath),
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: const Row(
                                          children: [
                                            Icon(
                                              Icons.link_rounded,
                                              color: Colors.white,
                                            ),
                                            SizedBox(width: 8),
                                            Text(
                                              'Stream link copied to clipboard!',
                                            ),
                                          ],
                                        ),
                                        duration: const Duration(seconds: 2),
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 8),

                                // 9. Save / Bookmark Button
                                _buildActionButton(
                                  icon: Icons.bookmark_add_rounded,
                                  label: 'Save Bookmark',
                                  onTap: () async {
                                    await BookmarkService.instance.addBookmark(
                                      title: player.title,
                                      url: player.filePath,
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Row(
                                            children: [
                                              const Icon(
                                                Icons.bookmark_added_rounded,
                                                color: AppColors.primary,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Saved "${player.title}" to Bookmarks!',
                                                ),
                                              ),
                                            ],
                                          ),
                                          duration: const Duration(seconds: 2),
                                          behavior: SnackBarBehavior.floating,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          if (player.currentItem == null)
                            ListenableBuilder(
                              listenable: DownloadManager.instance,
                              builder: (context, _) {
                                final downloads = DownloadManager
                                    .instance
                                    .completedTasks
                                    .where(
                                      (task) =>
                                          task.isVideoTask &&
                                          task.savePath?.isNotEmpty == true &&
                                          task.savePath != player.filePath,
                                    );
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Offline videos',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    for (final task in downloads)
                                      ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading: const Icon(
                                          Icons.video_file_outlined,
                                        ),
                                        title: Text(
                                          task.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: task.author.isEmpty
                                            ? null
                                            : Text(task.author),
                                        onTap: () =>
                                            player.playDownloadTask(task),
                                      ),
                                  ],
                                );
                              },
                            ),
                          if (upNext != null)
                            FutureBuilder<List<VideoItem>>(
                              key: ValueKey(_upNextUrl),
                              future: upNext,
                              builder: (context, snapshot) {
                                final videos =
                                    snapshot.data ?? const <VideoItem>[];
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Up next',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    const SizedBox(height: 12),
                                    if (snapshot.connectionState !=
                                        ConnectionState.done)
                                      const LinearProgressIndicator()
                                    else if (videos.isEmpty)
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              snapshot.hasError
                                                  ? 'Could not load related videos.'
                                                  : 'Related videos unavailable right now.',
                                              style: TextStyle(
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .bodyMedium
                                                    ?.color,
                                              ),
                                            ),
                                          ),
                                          TextButton.icon(
                                            onPressed: _retryUpNext,
                                            icon: const Icon(
                                              Icons.refresh_rounded,
                                              size: 16,
                                            ),
                                            label: const Text('Retry'),
                                          ),
                                        ],
                                      ),
                                    ...videos.map((video) {
                                      return InkWell(
                                        onTap: () {
                                          player.playVideoItem(video);
                                        },
                                        borderRadius: BorderRadius.circular(12),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 6,
                                          ),
                                          child: Row(
                                            children: [
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: Stack(
                                                  children: [
                                                    SmartNetworkImage(
                                                      url: video.thumbnailUrl,
                                                      width: 132,
                                                      height: 74,
                                                      fit: BoxFit.cover,
                                                      placeholderColor:
                                                          Colors.grey.shade900,
                                                      placeholderIcon:
                                                          Icons.movie,
                                                      accentColor: Colors.white,
                                                    ),
                                                    Positioned(
                                                      bottom: 4,
                                                      right: 4,
                                                      child: Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 4,
                                                              vertical: 1,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: Colors.black87,
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                4,
                                                              ),
                                                        ),
                                                        child: Text(
                                                          video.duration,
                                                          style:
                                                              const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 10,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      video.title,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: 13,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      '${video.author} • ${video.views}',
                                                      style: const TextStyle(
                                                        color: Colors.grey,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    }),
                                  ],
                                );
                              },
                            ),
                          const SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Action Pill Button Helper
  // ---------------------------------------------------------------------------
  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isHighlight = false,
    bool isActive = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Color bgColor;
    Color fgColor;

    if (isHighlight) {
      bgColor = AppColors.primary;
      fgColor = Colors.white;
    } else if (isActive) {
      bgColor = AppColors.primary.withValues(alpha: 0.20);
      fgColor = AppColors.primary;
    } else {
      bgColor = isDark ? AppColors.darkCard : Colors.grey.shade200;
      fgColor = isDark ? Colors.white : Colors.black87;
    }

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fgColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fgColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 16:9 Video Surface with MX Player Gestures, Double-Tap, HUD, Lock & HUD Controls
  // ---------------------------------------------------------------------------
  Widget _buildVideoSurface(BuildContext context, PlayerService player) {
    final insets = _fullscreen
        ? MediaQuery.viewPaddingOf(context)
        : EdgeInsets.zero;
    final surface = LayoutBuilder(
      key: const ValueKey("video-player-surface"),
      builder: (context, constraints) {
        final surfaceWidth = constraints.maxWidth;
        final surfaceHeight = constraints.maxHeight;

        final preview = _previewFor(player);
        final canSeek =
            !player.isLocked &&
            !player.isResolving &&
            !player.resolveError &&
            player.totalSeconds > 0;
        final buffered = player.engine?.value.buffered;
        final bufferedUntil = buffered?.isNotEmpty == true
            ? buffered!.last.end.inMilliseconds / 1000
            : null;
        return Listener(
          onPointerDown: (event) => _touchStart(event, player),
          onPointerMove: (event) => _touchMove(event, player),
          onPointerUp: _touchEnd,
          onPointerCancel: _touchEnd,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_pinching) return;
              setState(() {
                _showControls = !_showControls;
              });
            },
            onHorizontalDragStart: !canSeek
                ? null
                : (_) {
                    if (_pinching) return;
                    _dragOrigin = player.currentSeconds;
                    _dragDistance = 0;
                    _previewSeek(player, _dragOrigin!);
                  },
            onHorizontalDragUpdate: !canSeek
                ? null
                : (details) {
                    final origin = _dragOrigin;
                    if (_pinching ||
                        origin == null ||
                        _previewFor(player) == null)
                      return;
                    _dragDistance += details.delta.dx;
                    final window = player.totalSeconds.clamp(30.0, 180.0);
                    _previewSeek(
                      player,
                      origin + _dragDistance / surfaceWidth * window,
                    );
                  },
            onHorizontalDragEnd: !canSeek
                ? null
                : (_) => _finishSeek(player, commit: !_pinching),
            onHorizontalDragCancel: !canSeek
                ? null
                : () => _finishSeek(player, commit: false),
            onVerticalDragStart: player.isLocked
                ? null
                : (details) {
                    _brightnessGesture =
                        details.localPosition.dx >= surfaceWidth / 2;
                    _firstVerticalUpdate = true;
                  },
            onVerticalDragUpdate: player.isLocked
                ? null
                : (details) async {
                    if (_pinching) return;
                    final brightness = _brightnessGesture;
                    final first = _firstVerticalUpdate;
                    _firstVerticalUpdate = false;
                    final delta =
                        -(details.primaryDelta ?? 0) / (surfaceHeight * 0.7);
                    final level = await _playbackControls.adjust(
                      brightness: brightness,
                      delta: delta,
                      first: first,
                    );
                    if (!mounted || !player.isExpanded || player.isLocked) {
                      return;
                    }
                    if (brightness) {
                      player.setBrightness(
                        level ?? (player.brightness + delta).clamp(0.0, 1.0),
                      );
                    } else {
                      if (level == null)
                        player.setVolume(player.volume + delta);
                      _volumeHud = level ?? player.volume;
                    }
                    setState(() {
                      _showBrightnessHUD = brightness;
                      _showVolumeHUD = !brightness;
                    });
                    _hudTimer?.cancel();
                    _hudTimer = Timer(const Duration(milliseconds: 1400), () {
                      if (mounted) {
                        setState(() {
                          _showBrightnessHUD = false;
                          _showVolumeHUD = false;
                        });
                      }
                    });
                  },
            onLongPressStart: player.isLocked
                ? null
                : (_) {
                    if (_pinching) return;
                    _savedSpeedBeforeFastForward = player.playbackSpeed;
                    player.setSpeed(2.0);
                    setState(() => _isFastForwarding = true);
                    HapticFeedback.lightImpact();
                  },
            onLongPressEnd: player.isLocked
                ? null
                : (_) {
                    if (!_isFastForwarding) return;
                    player.setSpeed(_savedSpeedBeforeFastForward);
                    setState(() => _isFastForwarding = false);
                  },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. VIDEO SURFACE OR AUDIO ONLY CANVAS
                if (player.isAudioOnly)
                  _buildAudioOnlyCanvas(player)
                else if (player.isEngineActive &&
                    !player.isAudio &&
                    player.engine != null)
                  _buildVideoPlayerWithAspect(player)
                else if (player.isAudio)
                  _buildAudioOnlyCanvas(player)
                else
                  SmartNetworkImage(
                    url: player.thumbnailUrl,
                    fit: BoxFit.cover,
                    placeholderColor: Colors.black,
                    placeholderIcon: Icons.movie,
                    accentColor: AppColors.primary,
                  ),

                // 2. DOUBLE TAP AREAS (Left 35% skip -10s, Right 35% skip +10s)
                if (!player.isLocked)
                  Row(
                    children: [
                      // Left 35% for double tap rewind
                      Expanded(
                        flex: 35,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTap: () {
                            player.skip(-10);
                            HapticFeedback.lightImpact();
                            setState(() => _doubleTapSide = 'left');
                            _doubleTapTimer?.cancel();
                            _doubleTapTimer = Timer(
                              const Duration(milliseconds: 650),
                              () {
                                if (mounted)
                                  setState(() => _doubleTapSide = null);
                              },
                            );
                          },
                        ),
                      ),
                      const Expanded(flex: 30, child: SizedBox.shrink()),
                      // Right 35% for double tap forward
                      Expanded(
                        flex: 35,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTap: () {
                            player.skip(10);
                            HapticFeedback.lightImpact();
                            setState(() => _doubleTapSide = 'right');
                            _doubleTapTimer?.cancel();
                            _doubleTapTimer = Timer(
                              const Duration(milliseconds: 650),
                              () {
                                if (mounted)
                                  setState(() => _doubleTapSide = null);
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),

                // 3. DOUBLE TAP ANIMATED INDICATORS (<< 10s / >> 10s)
                if (_doubleTapSide == 'left')
                  Positioned(
                    left: 24,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.replay_10_rounded,
                              color: AppColors.primary,
                              size: 24,
                            ),
                            SizedBox(width: 4),
                            Text(
                              '10s',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                if (_doubleTapSide == 'right')
                  Positioned(
                    right: 24,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '10s',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            SizedBox(width: 4),
                            Icon(
                              Icons.forward_10_rounded,
                              color: AppColors.primary,
                              size: 24,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // 4. ON-SCREEN GESTURE HUD
                if (_showBrightnessHUD)
                  Positioned(
                    right: 20,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.brightness_6_rounded,
                              color: Colors.amber,
                              size: 20,
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 80,
                              width: 8,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: RotatedBox(
                                  quarterTurns: 3,
                                  child: LinearProgressIndicator(
                                    value: player.brightness,
                                    backgroundColor: Colors.white24,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                          Colors.amber,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${(player.brightness * 100).toInt()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                if (_showVolumeHUD)
                  Positioned(
                    left: 20,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _volumeHud > 0.5
                                  ? Icons.volume_up_rounded
                                  : (_volumeHud > 0
                                        ? Icons.volume_down_rounded
                                        : Icons.volume_off_rounded),
                              color: AppColors.primary,
                              size: 20,
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 80,
                              width: 8,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: RotatedBox(
                                  quarterTurns: 3,
                                  child: LinearProgressIndicator(
                                    value: _volumeHud,
                                    backgroundColor: Colors.white24,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                          AppColors.primary,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${(_volumeHud * 100).toInt()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // 5. 2X FAST FORWARD FLOATING PILL (YouTube Style Long-Press)
                if (_isFastForwarding)
                  Positioned(
                    top: 16,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.accentGold.withValues(
                                alpha: 0.4,
                              ),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.fast_forward_rounded,
                              color: AppColors.accentGold,
                              size: 16,
                            ),
                            SizedBox(width: 6),
                            Text(
                              '2X Fast Forward',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                if (_showCaptions && player.engine?.closedCaptionFile != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: _showControls && !player.isLocked ? 74 : 12,
                    child: IgnorePointer(
                      child: ClosedCaption(
                        text: player.engine!.value.caption.text,
                      ),
                    ),
                  ),
                if (player.isLocked)
                  Positioned(
                    right: 6 + insets.right,
                    top: 2 + insets.top,
                    child: _controlIcon(
                      'Unlock player',
                      Icons.lock_rounded,
                      player.toggleLock,
                      active: true,
                    ),
                  ),

                if ((_showControls || preview != null) && !player.isLocked) ...[
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black54,
                            Colors.transparent,
                            Colors.black87,
                          ],
                          stops: [0, .44, 1],
                        ),
                      ),
                    ),
                  ),
                  if (preview == null)
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Back 10 seconds',
                            icon: const Icon(Icons.replay_10_rounded),
                            color: Colors.white,
                            onPressed: () => player.skip(-10),
                          ),
                          const SizedBox(width: 16),
                          IconButton.filled(
                            tooltip: player.isPlaying ? 'Pause' : 'Play',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withValues(
                                alpha: .62,
                              ),
                              foregroundColor: Colors.white,
                              minimumSize: const Size.square(56),
                            ),
                            iconSize: 31,
                            icon: Icon(
                              player.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                            onPressed: player.togglePlay,
                          ),
                          const SizedBox(width: 16),
                          IconButton(
                            tooltip: 'Forward 10 seconds',
                            icon: const Icon(Icons.forward_10_rounded),
                            color: Colors.white,
                            onPressed: () => player.skip(10),
                          ),
                        ],
                      ),
                    )
                  else
                    Center(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Text(
                              _seekTime(preview),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 6,
                    top: 2,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRect(
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.centerRight,
                            child: _settingsExpanded
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _controlIcon(
                                        'Playback details',
                                        Icons.info_outline_rounded,
                                        () =>
                                            _showStatsForNerds(context, player),
                                      ),
                                      _controlIcon(
                                        'Sleep timer',
                                        Icons.timer_outlined,
                                        () => _showSleepTimerPicker(
                                          context,
                                          player,
                                        ),
                                        active:
                                            player.sleepTimerMinutes != null,
                                      ),
                                      _controlIcon(
                                        'Repeat video',
                                        player.isLooping
                                            ? Icons.repeat_one_rounded
                                            : Icons.repeat_rounded,
                                        player.toggleLoop,
                                        active: player.isLooping,
                                      ),
                                    ],
                                  )
                                : const SizedBox(width: 0, height: 44),
                          ),
                        ),
                        _controlIcon(
                          _settingsExpanded
                              ? 'Close playback settings'
                              : 'Playback settings',
                          Icons.settings_rounded,
                          () => setState(
                            () => _settingsExpanded = !_settingsExpanded,
                          ),
                          active: _settingsExpanded,
                        ),
                        _controlIcon(
                          'Lock player',
                          Icons.lock_open_rounded,
                          () {
                            setState(() => _settingsExpanded = false);
                            player.toggleLock();
                          },
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 8 + insets.left,
                    right: 8 + insets.right,
                    bottom: insets.bottom,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 26,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5.5,
                              ),
                              trackHeight: 4,
                              activeTrackColor: AppColors.primary,
                              inactiveTrackColor: Colors.white24,
                              secondaryActiveTrackColor: Colors.white54,
                              thumbColor: AppColors.primary,
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 10,
                              ),
                            ),
                            child: Slider(
                              secondaryTrackValue: bufferedUntil?.clamp(
                                0.0,
                                player.totalSeconds,
                              ),
                              value: (preview ?? player.currentSeconds).clamp(
                                0.0,
                                player.totalSeconds,
                              ),
                              max: player.totalSeconds,
                              onChanged: !canSeek
                                  ? null
                                  : (value) => _previewSeek(player, value),
                              onChangeEnd: !canSeek
                                  ? null
                                  : (_) => _finishSeek(player),
                              semanticFormatterCallback: _seekTime,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${preview == null ? player.positionFormatted : _seekTime(preview)} / ${player.durationFormatted}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 64,
                                child: TextButton(
                                  onPressed: () =>
                                      _showQualityPicker(context, player),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    padding: EdgeInsets.zero,
                                  ),
                                  child: Text(
                                    player.selectedQuality,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              _controlIcon(
                                'Playback speed',
                                Icons.speed_rounded,
                                () => _showSpeedPicker(context, player),
                              ),
                              _controlIcon(
                                'Audio only',
                                Icons.headphones_rounded,
                                player.toggleAudioOnly,
                                active: player.isAudioOnly,
                              ),
                              _controlIcon(
                                _loadingCaptions
                                    ? 'Loading subtitles'
                                    : 'Subtitles',
                                Icons.closed_caption_outlined,
                                () => _toggleCaptions(player),
                                active:
                                    _showCaptions &&
                                    player.engine?.closedCaptionFile != null,
                              ),
                              _controlIcon(
                                _fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                                _fullscreen
                                    ? Icons.fullscreen_exit_rounded
                                    : Icons.fullscreen_rounded,
                                () => _setFullscreen(!_fullscreen),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
    return _fullscreen
        ? surface
        : AspectRatio(aspectRatio: 16 / 9, child: surface);
  }

  Widget _buildVideoPlayerWithAspect(PlayerService player) {
    final engine = player.engine!;
    final size = engine.value.size;
    return ClipRect(
      child: ValueListenableBuilder<double>(
        valueListenable: _zoom,
        child: FittedBox(
          fit: _fullscreen ? BoxFit.cover : BoxFit.contain,
          child: SizedBox(
            width: size.width > 0 ? size.width : 16,
            height: size.height > 0 ? size.height : 9,
            child: VideoPlayer(engine),
          ),
        ),
        builder: (_, scale, video) =>
            Transform.scale(scale: scale, child: video),
      ),
    );
  }

  Widget _controlIcon(
    String tooltip,
    IconData icon,
    VoidCallback onPressed, {
    bool active = false,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 44),
      color: active ? AppColors.primary : Colors.white,
      icon: Icon(icon, size: 20),
    );
  }

  Future<void> _toggleCaptions(PlayerService player) async {
    if (_loadingCaptions) return;
    final engine = player.engine;
    if (engine?.closedCaptionFile != null) {
      setState(() => _showCaptions = !_showCaptions);
      return;
    }
    final id = yt.VideoId.parseVideoId(player.currentItem?.videoUrl ?? '');
    if (engine == null || id == null) {
      _captionUnavailable();
      return;
    }
    final language = Localizations.localeOf(context).languageCode;
    setState(() => _loadingCaptions = true);
    final youtube = yt.YoutubeExplode();
    try {
      final client = youtube.videos.closedCaptions;
      final manifest = await client
          .getManifest(id)
          .timeout(const Duration(seconds: 8));
      final trackInfo =
          manifest.getByLanguage(language, autoGenerated: true).firstOrNull ??
          manifest.getByLanguage('en', autoGenerated: true).firstOrNull ??
          manifest.tracks.firstOrNull;
      if (!mounted || !identical(player.engine, engine)) return;
      if (trackInfo == null) {
        _captionUnavailable();
        return;
      }
      final track = await client
          .get(trackInfo)
          .timeout(const Duration(seconds: 8));
      if (!mounted || !identical(player.engine, engine)) return;
      if (track.captions.isEmpty) {
        _captionUnavailable();
        return;
      }
      final captions = [
        for (final (index, caption) in track.captions.indexed)
          Caption(
            number: index + 1,
            start: caption.offset,
            end: caption.end,
            text: caption.text,
          ),
      ];
      await engine.setClosedCaptionFile(
        Future.value(_PlayerCaptions(captions)),
      );
      if (mounted && identical(player.engine, engine))
        setState(() => _showCaptions = true);
    } catch (_) {
      if (mounted && identical(player.engine, engine)) _captionUnavailable();
    } finally {
      youtube.close();
      if (mounted) setState(() => _loadingCaptions = false);
    }
  }

  void _captionUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Subtitles unavailable for this video')),
    );
  }

  void _showSpeedPicker(BuildContext context, PlayerService player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Playback speed',
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final speed in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                    ChoiceChip(
                      label: Text('${speed}×'),
                      selected: player.playbackSpeed == speed,
                      side: BorderSide.none,
                      onSelected: (_) {
                        player.setSpeed(speed);
                        Navigator.pop(sheet);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dedicated Audio-Only Canvas with Visualizer & Background Playback
  // ---------------------------------------------------------------------------
  Widget _buildAudioOnlyCanvas(PlayerService player) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0F172A), Color(0xFF020617)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Glowing Turntable / Album Art
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1DB954).withValues(alpha: 0.35),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(40),
                  child: SmartNetworkImage(
                    url: player.thumbnailUrl,
                    width: 74,
                    height: 74,
                    fit: BoxFit.cover,
                    placeholderColor: Colors.black,
                    placeholderIcon: Icons.music_note_rounded,
                    accentColor: const Color(0xFF1DB954),
                  ),
                ),
                Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                    color: Colors.black87,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.headphones_rounded,
                    color: Color(0xFF1DB954),
                    size: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Animated Audio Frequency Bars
            AnimatedBuilder(
              animation: _waveController,
              builder: (context, _) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(12, (index) {
                    final factor = math
                        .sin((_waveController.value * math.pi) + (index * 0.4))
                        .abs();
                    final barHeight = player.isPlaying
                        ? (6 + (factor * 16))
                        : 4.0;
                    return Container(
                      width: 3.5,
                      height: barHeight,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1DB954)
                            .withValues(alpha: 0.7 + (factor * 0.3)),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  }),
                );
              },
            ),
            const SizedBox(height: 8),

            // Title & Author
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                player.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${player.author} • Pure Audio Stream (Background)',
              style: const TextStyle(
                color: Color(0xFF1DB954),
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),

            const SizedBox(height: 8),

            // Switch to Video Mode Button
            OutlinedButton.icon(
              icon: const Icon(
                Icons.videocam_rounded,
                size: 14,
                color: Colors.white70,
              ),
              label: const Text(
                'Switch to Video Mode',
                style: TextStyle(fontSize: 10.5, color: Colors.white70),
              ),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => player.toggleAudioOnly(),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Docked MiniPlayer
  // ---------------------------------------------------------------------------
  Widget _buildMiniPlayer(
    BuildContext context,
    PlayerService player,
    bool isDark,
  ) {
    final progress = (player.currentSeconds / player.totalSeconds).clamp(
      0.0,
      1.0,
    );

    return Positioned(
      left: 12,
      right: 12,
      bottom: widget.miniPlayerBottom,
      child: Dismissible(
        key: ValueKey(player.title),
        direction: DismissDirection.horizontal,
        onDismissed: (_) => player.close(),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkCard : AppColors.lightCard,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: player.expand,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        // Small 16:9 Video Thumbnail
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              SmartNetworkImage(
                                url: player.thumbnailUrl,
                                width: 56,
                                height: 42,
                                fit: BoxFit.cover,
                                placeholderColor: Colors.black,
                                placeholderIcon: Icons.play_arrow,
                                accentColor: Colors.white,
                              ),
                              if (player.isPlaying)
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: AppColors.accentRed,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),

                        // Title & Author
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                player.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${player.positionFormatted} / ${player.durationFormatted} • ${player.author}',
                                style: TextStyle(
                                  color: isDark
                                      ? AppColors.darkTextSecondary
                                      : AppColors.lightTextSecondary,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Play/Pause
                        IconButton(
                          icon: Icon(
                            player.isPlaying
                                ? Icons.pause_circle_filled_rounded
                                : Icons.play_circle_fill_rounded,
                            color: AppColors.primary,
                            size: 32,
                          ),
                          onPressed: player.togglePlay,
                        ),

                        // Close (X)
                        IconButton(
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 20,
                            color: Colors.grey,
                          ),
                          onPressed: player.close,
                        ),
                      ],
                    ),
                  ),

                  // Progress line
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(16),
                    ),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 2.5,
                      backgroundColor: Colors.transparent,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AppColors.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
