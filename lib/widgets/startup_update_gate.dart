import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_update_service.dart';
import '../theme/app_palette.dart';

class StartupUpdateGate extends StatefulWidget {
  const StartupUpdateGate({
    super.key,
    required this.child,
    this.checkForUpdate = requestAutomaticAppUpdate,
    this.downloadUpdate = downloadAppUpdate,
  });

  final Widget child;
  final Future<AppUpdate?> Function() checkForUpdate;
  final UpdateDownload downloadUpdate;

  @override
  State<StartupUpdateGate> createState() => _StartupUpdateGateState();
}

class _StartupUpdateGateState extends State<StartupUpdateGate>
    with WidgetsBindingObserver {
  Timer? _poll;
  DateTime? _lastCheck;
  AppUpdate? _required;
  bool _starting = true;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    requiredAppUpdate.addListener(_applyManualUpdate);
    unawaited(_check());
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _poll = Timer.periodic(Duration(minutes: 5), (_) {
        if (WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed) {
          unawaited(_check());
        }
      });
    }
  }

  void _applyManualUpdate() {
    final update = requiredAppUpdate.value;
    if (update != null) setState(() => _required = update);
  }

  Future<void> _check() async {
    if (_checking || _required != null) return;
    _checking = true;
    _lastCheck = DateTime.now();
    AppUpdate? update;
    try {
      update = await widget.checkForUpdate();
    } on Exception {
      // An unavailable release check should leave the current app usable.
    }
    _checking = false;
    if (!mounted) return;
    setState(() {
      _starting = false;
      _required ??= update;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        DateTime.now().difference(_lastCheck ?? DateTime(1970)) >=
            Duration(minutes: 1)) {
      unawaited(_check());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    requiredAppUpdate.removeListener(_applyManualUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_starting) {
      final p = context.palette;
      return Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [p.background, p.card],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: context.palette.tint(
                          context.palette.primary,
                          .28,
                        ),
                        blurRadius: 22,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.asset('assets/images/app_logo.png'),
                  ),
                ),
                SizedBox(height: 24),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: context.palette.primary,
                    semanticsLabel: 'Checking for updates',
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Checking for updates…',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.palette.onPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final update = _required;
    return update == null
        ? widget.child
        : _RequiredUpdateDialog(update, widget.downloadUpdate);
  }
}

class _RequiredUpdateDialog extends StatefulWidget {
  _RequiredUpdateDialog(this.update, this.downloadUpdate);

  final AppUpdate update;
  final UpdateDownload downloadUpdate;

  @override
  State<_RequiredUpdateDialog> createState() => _RequiredUpdateDialogState();
}

class _RequiredUpdateDialogState extends State<_RequiredUpdateDialog>
    with SingleTickerProviderStateMixin {
  late final _progressSheen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void dispose() {
    _progressSheen.dispose();
    super.dispose();
  }

  bool _downloading = false;
  bool _installing = false;
  bool _installed = false;
  bool _showInstallPermission = false;
  bool _showFullNotes = false;
  bool _ready = false;
  int _received = 0;
  int? _total;
  String? _error;

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
      _received = 0;
      _total = null;
    });
    if (!MediaQuery.disableAnimationsOf(context)) _progressSheen.repeat();
    try {
      var update = widget.update;
      if (update.apkUrl == null) {
        update = await checkForAppUpdate() ?? update;
      }
      if (update.apkUrl == null) {
        if (mounted)
          setState(
            () => _error =
                'The Android package is not available yet. Try again later.',
          );
        return;
      }
      await widget.downloadUpdate(update, (received, total) {
        if (!mounted) return;
        if (_total == total &&
            received != total &&
            received - _received < 256 * 1024)
          return;
        setState(() {
          _received = received;
          _total = total;
        });
      });
      if (mounted) setState(() => _ready = true);
    } on Exception {
      if (mounted)
        setState(
          () => _error = 'Download failed. Check your connection and available storage, then try again.',
        );
    } finally {
      if (mounted) {
        _progressSheen.stop();
        setState(() => _downloading = false);
      }
    }
  }

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      final opened = await installAppUpdate();
      if (!mounted) return;
      if (opened) {
        setState(() => _installed = true);
      } else {
        setState(() => _showInstallPermission = true);
      }
    } on PlatformException catch (error) {
      if (mounted)
        setState(() {
          _error = error.message ?? 'Android could not open the installer.';
          if (error.code == 'INVALID_UPDATE') _ready = false;
        });
    } on Exception {
      if (mounted)
        setState(() => _error = 'Android could not open the installer.');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = context.palette.primary;
    final bodyText = context.palette.textSecondary;
    final total = _total;
    final progress = total == null ? null : (_received / total).clamp(0.0, 1.0);
    final sections = _releaseSections(widget.update.notes);
    final summary =
        sections.expand((section) => section.lines).firstOrNull ?? '';
    // The main app is unmounted while the mandatory update is visible.
    return PopScope(
      canPop: false,
      child: Shortcuts(
        shortcuts: {
          SingleActivator(LogicalKeyboardKey.escape):
              DoNothingAndStopPropagationIntent(),
        },
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              ModalBarrier(
                color: context.palette.textSecondary,
                dismissible: false,
              ),
              SafeArea(
                child: Center(
                  child: AlertDialog(
                    scrollable: true,
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    shadowColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    insetPadding: EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 24,
                    ),
                    titlePadding: EdgeInsets.zero,
                    contentPadding: EdgeInsets.zero,
                    actionsPadding: EdgeInsets.zero,
                    content: Container(
                      width: double.maxFinite,
                      constraints: BoxConstraints(maxWidth: 380),
                      decoration: BoxDecoration(
                        color: context.palette.card,
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: [
                          BoxShadow(
                            color: context.palette.shadowAt(isDark ? .50 : .18),
                            blurRadius: 34,
                            spreadRadius: -12,
                            offset: Offset(0, 16),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(26),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Branded hero header.
                            Container(
                              padding: EdgeInsets.fromLTRB(22, 26, 22, 22),
                              decoration: BoxDecoration(
                                gradient: context.palette.primaryGradient,
                              ),
                              child: Column(
                                children: [
                                  Container(
                                    width: 62,
                                    height: 62,
                                    decoration: BoxDecoration(
                                      color: context.palette.tint(
                                        context.palette.card,
                                        .16,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: context.palette.tint(
                                          context.palette.card,
                                          .28,
                                        ),
                                      ),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(20),
                                      child: Image.asset(
                                        'assets/images/app_logo.png',
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: 12),
                                  Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: context.palette.card,
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: context.palette.tint(
                                          context.palette.onScrim,
                                          0.28,
                                        ),
                                      ),
                                    ),
                                    child: Text(
                                      'UPDATE REQUIRED',
                                      style: TextStyle(
                                        color: context.palette.critical,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 9.5,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'Version ${widget.update.version} is ready',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: context.palette.onPrimary,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 17,
                                      letterSpacing: -.3,
                                    ),
                                  ),
                                  SizedBox(height: 6),
                                  Text(
                                    'Download and install in All in One',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: context.palette.onPrimary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Message, release notes and actions.
                            Padding(
                              padding: EdgeInsets.fromLTRB(22, 20, 22, 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'Install the latest version of All in One to continue.',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      height: 1.45,
                                      color: bodyText,
                                    ),
                                  ),
                                  if (widget.update.notes.isNotEmpty) ...[
                                    SizedBox(height: 14),
                                    Container(
                                      padding: EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: isDark
                                            ? context.palette.tint(
                                                context.palette.card,
                                                .05,
                                              )
                                            : context.palette.background,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: context.palette.border,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.article_outlined,
                                                size: 16,
                                                color: accent,
                                              ),
                                              SizedBox(width: 8),
                                              Text(
                                                "WHAT'S NEW",
                                                style: TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: 1,
                                                  color: accent,
                                                ),
                                              ),
                                            ],
                                          ),
                                          SizedBox(height: 8),
                                          if (sections.any(
                                                (section) =>
                                                    section.title.isNotEmpty,
                                              ) ||
                                              _showFullNotes)
                                            ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxHeight: 205,
                                              ),
                                              child: SingleChildScrollView(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  children: [
                                                    for (final section
                                                        in sections) ...[
                                                      if (section
                                                          .title
                                                          .isNotEmpty)
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                top: 8,
                                                                bottom: 5,
                                                              ),
                                                          child: Text(
                                                            section.title,
                                                            style: TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                              color: context
                                                                  .palette
                                                                  .textPrimary,
                                                            ),
                                                          ),
                                                        ),
                                                      for (final line
                                                          in section.lines)
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                bottom: 5,
                                                              ),
                                                          child: Text(
                                                            section
                                                                    .title
                                                                    .isEmpty
                                                                ? line
                                                                : '•  $line',
                                                            style: TextStyle(
                                                              fontSize: 12.5,
                                                              height: 1.4,
                                                              color: bodyText,
                                                            ),
                                                          ),
                                                        ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            )
                                          else
                                            Text(
                                              summary,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                height: 1.45,
                                                color: bodyText,
                                              ),
                                            ),
                                          if (!sections.any(
                                                (section) =>
                                                    section.title.isNotEmpty,
                                              ) &&
                                              (summary != widget.update.notes ||
                                                  summary.length > 45))
                                            TextButton(
                                              onPressed: () => setState(
                                                () => _showFullNotes =
                                                    !_showFullNotes,
                                              ),
                                              child: Text(
                                                _showFullNotes
                                                    ? 'Show less'
                                                    : 'Read release notes',
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  if (_downloading || _ready) ...[
                                    const SizedBox(height: 16),
                                    Text(
                                      _installed
                                          ? 'Update installed'
                                          : _installing
                                          ? 'Installing update…'
                                          : _ready
                                          ? 'Download complete'
                                          : progress == null
                                          ? 'Downloading update…'
                                          : 'Downloading update · ${(progress * 100).floor()}%',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: context.palette.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    TweenAnimationBuilder<double>(
                                      tween: Tween<double>(
                                        end: (_ready ? 1 : progress) ?? 0,
                                      ),
                                      duration: Duration(milliseconds: 420),
                                      curve: Curves.easeOutCubic,
                                      builder: (context, value, _) => Stack(
                                        alignment: Alignment.centerLeft,
                                        children: [
                                          LinearProgressIndicator(
                                            value:
                                                _installing ||
                                                    (!_ready &&
                                                        progress == null)
                                                ? null
                                                : value,
                                            color: accent,
                                            backgroundColor:
                                                context.palette.trackBg,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            semanticsLabel: _installing
                                                ? 'Installing update'
                                                : 'Update download progress',
                                          ),
                                          if (_downloading &&
                                              progress != null &&
                                              value > 0 &&
                                              !MediaQuery.disableAnimationsOf(
                                                context,
                                              ))
                                            FractionallySizedBox(
                                              widthFactor: value,
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: AnimatedBuilder(
                                                  animation: _progressSheen,
                                                  builder: (context, _) {
                                                    final offset =
                                                        _progressSheen.value *
                                                            4 -
                                                        2;
                                                    final highlight = context
                                                        .palette
                                                        .onPrimary;
                                                    return Container(
                                                      height: 4,
                                                      decoration: BoxDecoration(
                                                        gradient:
                                                            LinearGradient(
                                                              begin: Alignment(
                                                                offset - .45,
                                                                0,
                                                              ),
                                                              end: Alignment(
                                                                offset + .45,
                                                                0,
                                                              ),
                                                              colors: [
                                                                highlight
                                                                    .withValues(
                                                                      alpha: 0,
                                                                    ),
                                                                highlight
                                                                    .withValues(
                                                                      alpha:
                                                                          .55,
                                                                    ),
                                                                highlight
                                                                    .withValues(
                                                                      alpha: 0,
                                                                    ),
                                                              ],
                                                            ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    if (total != null) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        '${(_received / (1024 * 1024)).toStringAsFixed(1)} / '
                                        '${(total / (1024 * 1024)).toStringAsFixed(1)} MiB',
                                        style: TextStyle(
                                          color: bodyText,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ],
                                  if (_showInstallPermission) ...[
                                    const SizedBox(height: 12),
                                    const Text(
                                      'Allow installs from All in One',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const Text(
                                      'Enable this permission in Android Settings, then return and tap Update & Install again.',
                                    ),
                                    Wrap(
                                      children: [
                                        TextButton(
                                          onPressed: () => setState(
                                            () =>
                                                _showInstallPermission = false,
                                          ),
                                          child: const Text('Not now'),
                                        ),
                                        TextButton(
                                          onPressed: () async {
                                            try {
                                              await openAppInstallSettings();
                                              if (mounted)
                                                setState(
                                                  () => _showInstallPermission =
                                                      false,
                                                );
                                            } on Exception {
                                              if (mounted)
                                                setState(
                                                  () => _error = 'Could not open Android Settings.',
                                                );
                                            }
                                          },
                                          child: const Text(
                                            'Open Android Settings',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  if (_error case final error?) ...[
                                    const SizedBox(height: 12),
                                    Text(
                                      error,
                                      style: TextStyle(
                                        color: context.palette.textPrimary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 18),
                                  FilledButton.icon(
                                    onPressed:
                                        _downloading ||
                                            _installing ||
                                            _showInstallPermission
                                        ? null
                                        : (_installed
                                              ? restartAfterAppUpdate
                                              : _ready
                                              ? _install
                                              : _download),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: accent,
                                      foregroundColor:
                                          context.palette.onPrimary,
                                      minimumSize: const Size.fromHeight(48),
                                    ),
                                    icon: Icon(
                                      _ready
                                          ? Icons.install_mobile_rounded
                                          : Icons.download_rounded,
                                    ),
                                    label: Text(
                                      _installed
                                          ? 'Restart'
                                          : _installing
                                          ? 'Installing…'
                                          : _ready
                                          ? 'Update & Install'
                                          : _downloading
                                          ? 'Downloading…'
                                          : _error != null
                                          ? 'Retry Download'
                                          : 'Download Update',
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => SystemNavigator.pop(),
                                    child: Text(
                                      'Exit App',
                                      style: TextStyle(
                                        color: bodyText,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
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

List<({String title, List<String> lines})> _releaseSections(String notes) {
  final sections = <({String title, List<String> lines})>[];
  var title = '';
  var lines = <String>[];
  final heading = RegExp(r'^#{1,6}\s+');
  final bullet = RegExp(r'^(?:[-*+]\s+|\d+[.)]\s+)');
  for (final raw in notes.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (heading.hasMatch(line)) {
      if (lines.isNotEmpty) sections.add((title: title, lines: lines));
      title = line.replaceFirst(heading, '');
      lines = [];
    } else {
      lines.add(line.replaceFirst(bullet, ''));
    }
  }
  if (lines.isNotEmpty) sections.add((title: title, lines: lines));
  return sections;
}
