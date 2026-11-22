import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';
import '../theme/app_colors.dart';

class StartupUpdateGate extends StatefulWidget {
  const StartupUpdateGate({
    super.key,
    required this.child,
    this.checkForUpdate = requestAppUpdate,
  });

  final Widget child;
  final Future<AppUpdate?> Function() checkForUpdate;

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
      _poll = Timer.periodic(const Duration(minutes: 5), (_) {
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
            const Duration(minutes: 1)) {
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
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? const [Color(0xFF1B1116), Color(0xFF120D10)]
                  : const [Color(0xFFFFF6F8), Color(0xFFFFFFFF)],
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
                        color: AppColors.primary.withValues(alpha: .28),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.asset('assets/images/app_logo.png'),
                  ),
                ),
                const SizedBox(height: 24),
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: AppColors.primary,
                    semanticsLabel: 'Checking for updates',
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Checking for updates…',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final update = _required;
    return update == null ? widget.child : _RequiredUpdateDialog(update);
  }
}

class _RequiredUpdateDialog extends StatefulWidget {
  const _RequiredUpdateDialog(this.update);

  final AppUpdate update;

  @override
  State<_RequiredUpdateDialog> createState() => _RequiredUpdateDialogState();
}

class _RequiredUpdateDialogState extends State<_RequiredUpdateDialog> {
  bool _opening = false;
  bool _launchFailed = false;

  Future<bool> _launch(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } on Exception {
      return false;
    }
  }

  Future<void> _openUpdate() async {
    setState(() {
      _opening = true;
      _launchFailed = false;
    });
    final update = widget.update;
    final apk = update.apkUrl;
    final opened =
        (apk != null && await _launch(apk)) || await _launch(update.releaseUrl);
    if (!mounted) return;
    setState(() {
      _opening = false;
      _launchFailed = !opened;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.primaryLight : AppColors.primary;
    final bodyText = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    // The main app is unmounted while the mandatory update is visible.
    return PopScope(
      canPop: false,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape):
              DoNothingAndStopPropagationIntent(),
        },
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              const ModalBarrier(color: Colors.black54, dismissible: false),
              SafeArea(
                child: Center(
                  child: AlertDialog(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    shadowColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    insetPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 24,
                    ),
                    titlePadding: EdgeInsets.zero,
                    contentPadding: EdgeInsets.zero,
                    actionsPadding: EdgeInsets.zero,
                    content: Container(
                      width: double.maxFinite,
                      constraints: const BoxConstraints(maxWidth: 380),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.darkCard : Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDark ? .50 : .18,
                            ),
                            blurRadius: 34,
                            spreadRadius: -12,
                            offset: const Offset(0, 16),
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
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                26,
                                22,
                                22,
                              ),
                              decoration: const BoxDecoration(
                                gradient: AppColors.primaryGradient,
                              ),
                              child: Column(
                                children: [
                                  Container(
                                    width: 62,
                                    height: 62,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: .16,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: .28,
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
                                  const SizedBox(height: 14),
                                  Text(
                                    'Update required · v${widget.update.version}',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 17,
                                      letterSpacing: -.3,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'A fresh new version is ready for you',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Message, release notes and actions.
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                20,
                                22,
                                14,
                              ),
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
                                    const SizedBox(height: 14),
                                    Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: isDark
                                            ? Colors.white.withValues(
                                                alpha: .05,
                                              )
                                            : AppColors.lightBg,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: isDark
                                              ? AppColors.darkBorder
                                              : AppColors.lightBorder,
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
                                              const SizedBox(width: 8),
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
                                          const SizedBox(height: 8),
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxHeight: 130,
                                            ),
                                            child: SingleChildScrollView(
                                              child: Text(
                                                widget.update.notes,
                                                style: TextStyle(
                                                  fontSize: 12.5,
                                                  height: 1.45,
                                                  color: bodyText,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  if (_launchFailed) ...[
                                    const SizedBox(height: 12),
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: AppColors.accentRed.withValues(
                                          alpha: .08,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: AppColors.accentRed.withValues(
                                            alpha: .25,
                                          ),
                                        ),
                                      ),
                                      child: const Text(
                                        'Could not open the update. Try again.',
                                        style: TextStyle(
                                          color: AppColors.accentRed,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 18),
                                  Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: _opening ? null : _openUpdate,
                                      borderRadius: BorderRadius.circular(14),
                                      child: Container(
                                        height: 48,
                                        decoration: BoxDecoration(
                                          gradient: AppColors.primaryGradient,
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: AppColors.primary
                                                  .withValues(alpha: .30),
                                              blurRadius: 14,
                                              offset: const Offset(0, 5),
                                            ),
                                          ],
                                        ),
                                        child: Center(
                                          child: _opening
                                              ? const Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    SizedBox.square(
                                                      dimension: 17,
                                                      child:
                                                          CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                            color: Colors.white,
                                                          ),
                                                    ),
                                                    SizedBox(width: 10),
                                                    Text(
                                                      'Opening…',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        fontSize: 14,
                                                      ),
                                                    ),
                                                  ],
                                                )
                                              : const Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.download_rounded,
                                                      color: Colors.white,
                                                      size: 18,
                                                    ),
                                                    SizedBox(width: 8),
                                                    Text(
                                                      'Update Now',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        fontSize: 14,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                        ),
                                      ),
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
