import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/vault_item.dart';
import '../models/video_item.dart';
import '../services/player_service.dart';
import 'audio_player_screen.dart';
import '../services/vault_service.dart';
import '../theme/app_palette.dart';
import '../widgets/remote_image.dart';
import '../widgets/media_details_dialog.dart';

class VaultScreen extends StatefulWidget {
  /// `standalone` is true when pushed as a route from a download tile; in that
  /// case system back pops the page instead of being swallowed by the shell.
  const VaultScreen({super.key, this.standalone = false});

  final bool standalone;

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final _busyItems = <String>{};
  final _folderPath = <String>[];

  void _goUp() => setState(() => _folderPath.removeLast());

  List<String> _folderParts(VaultItem item, VaultService vault) => vault
      .sourceFolderFor(item)
      .split(RegExp(r'[/\\]+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();

  @override
  void initState() {
    super.initState();
    unawaited(_autoBiometricUnlock());
  }

  Future<void> _autoBiometricUnlock() async {
    final vault = VaultService.instance;
    await vault.ready;
    if (!mounted ||
        Platform.environment.containsKey('FLUTTER_TEST') ||
        vault.isUnlocked ||
        !vault.hasPin ||
        !vault.biometricsEnabled) {
      return;
    }
    await _useBiometrics(enable: false);
  }

  bool _biometricBusy = false;
  String _enteredPin = '';
  String? _errorMessage;

  // Mandatory setup-first flow: a first-time user must CREATE a vault PIN and
  // CONFIRM it before the vault exists. The app never silently converts the
  // first typed digits into a password, and never shows an "enter existing
  // password" prompt for a vault that was never set up.
  bool _awaitingConfirm = false;
  String _firstPinCandidate = '';

  // ---------------------------------------------------------------------------
  // Theme helpers
  // ---------------------------------------------------------------------------
  bool get _dark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent =>
      _dark ? context.palette.primary : context.palette.primary;
  Color get _accentSoft => _accent.withValues(alpha: .12);
  Color get _secondaryText =>
      _dark ? context.palette.textSecondary : context.palette.textSecondary;

  Widget _glass({
    required Widget child,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(20)),
    double blur = 16,
    Color? color,
    List<BoxShadow>? shadows,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow:
            shadows ??
            [
              BoxShadow(
                color: context.palette.shadowAt(_dark ? .30 : .07),
                blurRadius: 22,
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
              color:
                  color ??
                  (_dark
                      ? context.palette.tint(context.palette.card, 0.086)
                      : context.palette.tint(context.palette.card, 0.659)),
              borderRadius: borderRadius,
              border: Border.all(
                color: _dark
                    ? context.palette.tint(context.palette.card, 0.133)
                    : context.palette.tint(context.palette.card, 0.600),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _orb(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );

  Widget _ambientBackground() => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _dark
              ? [
                  context.palette.background,
                  context.palette.background,
                  context.palette.background,
                ]
              : [
                  context.palette.background,
                  context.palette.tint(context.palette.primary, 0.04),
                  context.palette.background,
                ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: -110,
            top: -60,
            child: _orb(_accent.withValues(alpha: _dark ? .26 : .22), 300),
          ),
          Positioned(
            right: -120,
            bottom: -120,
            child: _orb(
              context.palette.tint(context.palette.error, _dark ? .18 : .12),
              340,
            ),
          ),
        ],
      ),
    ),
  );

  // ---------------------------------------------------------------------------
  // PIN logic (unchanged)
  // ---------------------------------------------------------------------------
  void _onDigitPress(String digit) {
    if (_enteredPin.length < 4) {
      setState(() {
        _enteredPin += digit;
        _errorMessage = null;
      });

      if (_enteredPin.length == 4) {
        if (_awaitingConfirm) {
          _confirmSetupPin();
        } else if (VaultService.instance.hasPin) {
          _verifyPin();
        } else {
          _firstPinCandidate = _enteredPin;
          _enteredPin = '';
          _awaitingConfirm = true;
        }
      }
    }
  }

  void _onBackspace() {
    if (_enteredPin.isNotEmpty) {
      setState(() {
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
        _errorMessage = null;
      });
    }
  }

  void _confirmSetupPin() {
    if (_enteredPin == _firstPinCandidate) {
      VaultService.instance.setPin(_enteredPin).then((ok) {
        if (!mounted || ok) return;
        setState(() {
          _errorMessage = 'Could not create the vault. Try again.';
          _enteredPin = '';
          _awaitingConfirm = false;
          _firstPinCandidate = '';
        });
      });
    } else {
      setState(() {
        _errorMessage = 'PINs did not match. Choose a new PIN.';
        _enteredPin = '';
        _awaitingConfirm = false;
        _firstPinCandidate = '';
      });
    }
  }

  Future<void> _verifyPin() async {
    final success = await VaultService.instance.unlock(_enteredPin);
    if (!mounted) return;
    if (!success) {
      setState(() {
        _errorMessage = 'Incorrect PIN. Try again.';
        _enteredPin = '';
      });
    } else {
      setState(() {
        _enteredPin = '';
        _errorMessage = null;
      });
    }
  }

  Future<void> _useBiometrics({required bool enable}) async {
    if (_biometricBusy) return;
    final vault = VaultService.instance;
    setState(() => _biometricBusy = true);
    final success = enable
        ? await vault.setBiometricsEnabled(!vault.biometricsEnabled)
        : await vault.unlockWithBiometrics();
    if (!mounted) return;
    setState(() {
      _biometricBusy = false;
      _enteredPin = '';
      _errorMessage = success
          ? null
          : 'Biometric verification unavailable. Use your PIN.';
    });
    if (enable) {
      _message(
        success
            ? (vault.biometricsEnabled
                  ? 'Biometric unlock enabled'
                  : 'Biometric unlock disabled')
            : 'Set up biometrics in Android settings and try again',
      );
    }
  }

  void _message(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: VaultService.instance,
      builder: (context, _) {
        final vault = VaultService.instance;
        if (!vault.isUnlocked) {
          return _buildPinLockScreen(vault.hasPin);
        }
        return _buildUnlockedVault(vault);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Modern PIN setup / unlock screen
  // ---------------------------------------------------------------------------
  Widget _buildPinLockScreen(bool hasPin) {
    final creating = !hasPin;
    final headline = creating
        ? (_awaitingConfirm ? 'Confirm PIN' : 'Create Vault PIN')
        : 'Welcome back';
    final subline = creating
        ? (_awaitingConfirm
              ? 'Re-enter the same 4 digits to secure your vault'
              : 'Choose a 4-digit PIN to protect your private media')
        : 'Enter your 4-digit PIN to unlock your vault';

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _ambientBackground()),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(24),
                child: _glass(
                  blur: 22,
                  padding: EdgeInsets.fromLTRB(24, 28, 24, 26),
                  borderRadius: BorderRadius.circular(30),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              _accentSoft,
                              _accent.withValues(alpha: .05),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: _accent.withValues(alpha: .25),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _accent.withValues(alpha: .22),
                              blurRadius: 20,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Icon(
                          creating
                              ? Icons.admin_panel_settings_rounded
                              : Icons.lock_rounded,
                          size: 34,
                          color: _accent,
                        ),
                      ),
                      SizedBox(height: 20),
                      AnimatedSwitcher(
                        duration: Duration(milliseconds: 220),
                        child: Text(
                          key: ValueKey(headline),
                          headline,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: -.5,
                              ),
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        subline,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: _secondaryText),
                      ),
                      SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(4, (index) {
                          final filled = index < _enteredPin.length;
                          return AnimatedContainer(
                            duration: Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            margin: EdgeInsets.symmetric(horizontal: 9),
                            width: filled ? 16 : 12,
                            height: filled ? 16 : 12,
                            decoration: BoxDecoration(
                              color: filled
                                  ? _accent
                                  : _accent.withValues(alpha: .16),
                              shape: BoxShape.circle,
                              boxShadow: filled
                                  ? [
                                      BoxShadow(
                                        color: _accent.withValues(alpha: .4),
                                        blurRadius: 10,
                                        offset: Offset(0, 3),
                                      ),
                                    ]
                                  : null,
                              border: filled
                                  ? null
                                  : Border.all(
                                      color: _accent.withValues(alpha: .30),
                                    ),
                            ),
                          );
                        }),
                      ),
                      if (_errorMessage != null) ...[
                        SizedBox(height: 16),
                        _glass(
                          blur: 8,
                          color: context.palette.tint(
                            context.palette.error,
                            .10,
                          ),
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          borderRadius: BorderRadius.circular(14),
                          shadows: [],
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.error_outline_rounded,
                                size: 16,
                                color: context.palette.error,
                              ),
                              SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(
                                    color: context.palette.error,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (VaultService.instance.biometricsEnabled &&
                          !creating) ...[
                        // Automation hook only — no visible button.
                        GestureDetector(
                          onTap: _biometricBusy
                              ? null
                              : () => _useBiometrics(enable: false),
                          child: const Opacity(
                            opacity: 0,
                            child: Padding(
                              padding: EdgeInsets.all(1),
                              child: Text('Unlock with biometrics'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextButton.icon(
                          onPressed: () => setState(() {
                            _errorMessage = null;
                            _enteredPin = '';
                          }),
                          icon: const Icon(
                            Icons.lock_outline_rounded,
                            size: 15,
                          ),
                          label: const Text('Try password instead'),
                        ),
                      ],
                      SizedBox(height: 24),
                      SizedBox(
                        width: 280,
                        child: Column(
                          children: [
                            _buildPadRow(['1', '2', '3']),
                            SizedBox(height: 14),
                            _buildPadRow(['4', '5', '6']),
                            SizedBox(height: 14),
                            _buildPadRow(['7', '8', '9']),
                            SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                SizedBox(width: 64, height: 64),
                                _buildPadButton('0'),
                                SizedBox(
                                  width: 64,
                                  height: 64,
                                  child: _glass(
                                    blur: 8,
                                    padding: EdgeInsets.zero,
                                    borderRadius: BorderRadius.circular(20),
                                    shadows: [],
                                    child: IconButton(
                                      icon: Icon(
                                        Icons.backspace_outlined,
                                        size: 22,
                                      ),
                                      color: _secondaryText,
                                      onPressed: _onBackspace,
                                    ),
                                  ),
                                ),
                              ],
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
        ],
      ),
    );
  }

  Widget _buildPadRow(List<String> digits) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: digits.map(_buildPadButton).toList(),
  );

  Widget _buildPadButton(String digit) => _glass(
    blur: 8,
    padding: EdgeInsets.zero,
    borderRadius: BorderRadius.circular(20),
    color: context.palette.selectedBg,
    shadows: [],
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _onDigitPress(digit),
        child: SizedBox(
          width: 64,
          height: 64,
          child: Center(
            child: Text(
              digit,
              style: TextStyle(
                color: context.palette.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  // ---------------------------------------------------------------------------
  // Modern unlocked vault
  // ---------------------------------------------------------------------------
  Widget _buildUnlockedVault(VaultService vault) {
    final theme = Theme.of(context);
    final folders = <String, ({String label, int count})>{};
    final files = <VaultItem>[];
    for (final item in vault.items) {
      final parts = _folderParts(item, vault);
      if (parts.length < _folderPath.length ||
          _folderPath.indexed.any(
            (entry) => parts[entry.$1].toLowerCase() != entry.$2.toLowerCase(),
          )) {
        continue;
      }
      if (parts.length == _folderPath.length) {
        files.add(item);
      } else {
        final label = parts[_folderPath.length];
        final key = label.toLowerCase();
        final previous = folders[key];
        folders[key] = (
          label: previous?.label ?? (key == 'youtube' ? 'YouTube' : label),
          count: (previous?.count ?? 0) + 1,
        );
      }
    }
    final folderEntries = folders.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    final atRoot = _folderPath.isEmpty;
    final total = vault.items.length;

    // The main navigation shell owns the system back gesture. Only folder
    // navigation is consumed here; at root the shell unwinds its own history.
    return PopScope(
      canPop: widget.standalone && _folderPath.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _folderPath.isNotEmpty) _goUp();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          // No title / header — only two compact action icons in one corner.
          leading: atRoot
              ? null
              : IconButton(
                  tooltip: 'Back',
                  icon: Icon(
                    Icons.arrow_back_rounded,
                    size: 20,
                    color: _accent,
                  ),
                  onPressed: _goUp,
                ),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            if (vault.supportsBiometrics)
              IconButton(
                tooltip: vault.biometricsEnabled
                    ? 'Disable biometric unlock'
                    : 'Enable biometric unlock',
                iconSize: 20,
                padding: EdgeInsets.symmetric(horizontal: 6),
                constraints: BoxConstraints(),
                icon: Icon(Icons.fingerprint_rounded, color: _accent),
                onPressed: _biometricBusy
                    ? null
                    : () => _useBiometrics(enable: true),
              ),
            IconButton(
              tooltip: 'Lock Vault',
              iconSize: 20,
              padding: EdgeInsets.symmetric(horizontal: 6),
              constraints: BoxConstraints(),
              icon: Icon(Icons.lock_outline_rounded, color: _accent),
              onPressed: () {
                _folderPath.clear();
                vault.lock();
              },
            ),
            SizedBox(width: 6),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(child: _ambientBackground()),
            SafeArea(
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : Duration(milliseconds: 200),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: Offset(.035, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: ListView(
                  key: ValueKey(_folderPath.join('/')),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    14,
                    16,
                    20 + MediaQuery.paddingOf(context).bottom,
                  ),
                  children: [
                    if (atRoot) ...[
                      _glass(
                        blur: 18,
                        padding: EdgeInsets.fromLTRB(18, 16, 18, 16),
                        borderRadius: BorderRadius.circular(26),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    _accentSoft,
                                    _accent.withValues(alpha: .04),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: _accent.withValues(alpha: .22),
                                ),
                              ),
                              child: Icon(
                                Icons.enhanced_encryption_rounded,
                                color: _accent,
                                size: 23,
                              ),
                            ),
                            SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Private collection',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    '$total ${total == 1 ? 'item' : 'items'} secured · only you can see these',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: _secondaryText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 20),
                    ],
                    if (!atRoot)
                      Padding(
                        padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
                        child: Row(
                          children: [
                            Icon(
                              Icons.folder_open_rounded,
                              size: 14,
                              color: _secondaryText,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                ['Vault', ..._folderPath].join(' / '),
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: _secondaryText,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (folders.isEmpty && files.isEmpty)
                      _glass(
                        blur: 14,
                        padding: EdgeInsets.symmetric(
                          vertical: 44,
                          horizontal: 24,
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: _accentSoft,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Icon(
                                Icons.folder_open_rounded,
                                color: _accent,
                                size: 28,
                              ),
                            ),
                            SizedBox(height: 14),
                            Text(
                              atRoot
                                  ? 'Your vault is empty'
                                  : 'This folder is empty',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              atRoot
                                  ? 'Move a file here from Downloads to keep it private.'
                                  : 'Go back and add something here.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _secondaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    for (final folder in folderEntries)
                      Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: _glass(
                          blur: 14,
                          padding: EdgeInsets.zero,
                          borderRadius: BorderRadius.circular(22),
                          child: Material(
                            color: Colors.transparent,
                            child: ListTile(
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              leading: Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      _accentSoft,
                                      _accent.withValues(alpha: .04),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: _accent.withValues(alpha: .18),
                                  ),
                                ),
                                child: Icon(
                                  Icons.folder_rounded,
                                  color: _accent,
                                ),
                              ),
                              title: Text(
                                folder.label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                folder.count == 1
                                    ? '1 file'
                                    : '${folder.count} files',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _secondaryText,
                                ),
                              ),
                              trailing: Icon(
                                Icons.chevron_right_rounded,
                                color: _secondaryText,
                              ),
                              onTap: () =>
                                  setState(() => _folderPath.add(folder.label)),
                            ),
                          ),
                        ),
                      ),
                    if (files.any(_isVaultVideo))
                      _buildVaultVideoGrid(
                        files.where(_isVaultVideo).toList(),
                        vault,
                      ),
                    for (final item in files.where(
                      (item) => !_isVaultVideo(item),
                    ))
                      _buildVaultTile(item, vault),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isVaultVideo(VaultItem item) => !item.isAudio && !item.isImage;

  Widget _buildVaultVideoGrid(List<VaultItem> videos, VaultService vault) {
    return GridView.builder(
      shrinkWrap: true,
      physics: NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(bottom: 10),
      itemCount: videos.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: .78,
      ),
      itemBuilder: (context, index) =>
          _buildVaultVideoTile(videos[index], vault),
    );
  }

  Widget _buildVaultVideoTile(VaultItem item, VaultService vault) {
    final theme = Theme.of(context);
    final busy = _busyItems.contains(item.id);
    return _glass(
      blur: 14,
      padding: EdgeInsets.all(8),
      borderRadius: BorderRadius.circular(20),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: busy ? null : () => _openItem(item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (item.thumbnailUrl.isNotEmpty)
                        SmartNetworkImage(
                          url: item.thumbnailUrl,
                          fit: BoxFit.cover,
                          placeholderColor: _accentSoft,
                          placeholderIcon: Icons.movie_rounded,
                          accentColor: _accent,
                        )
                      else
                        Container(
                          color: _accentSoft,
                          child: Icon(
                            Icons.movie_rounded,
                            color: _accent,
                            size: 34,
                          ),
                        ),
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: Icon(
                          Icons.play_circle_fill_rounded,
                          color: Colors.white,
                          size: 30,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 8),
                          ],
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: busy
                            ? Container(
                                padding: EdgeInsets.all(7),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                              )
                            : PopupMenuButton<String>(
                                tooltip: 'File options',
                                icon: Icon(
                                  Icons.more_vert_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                color: context.palette.card,
                                onSelected: (action) {
                                  if (action == 'details') {
                                    _showItemDetails(item);
                                  } else {
                                    _updateItem(
                                      vault,
                                      item,
                                      restore: action == 'restore',
                                    );
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'details',
                                    child: Text('Details'),
                                  ),
                                  PopupMenuItem(
                                    value: 'restore',
                                    child: Text('Restore to Downloads'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 8),
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '${item.ext.replaceAll('.', '').toUpperCase()} · '
                '${(item.fileSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _secondaryText,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVaultTile(VaultItem item, VaultService vault) {
    final theme = Theme.of(context);
    final busy = _busyItems.contains(item.id);
    final (IconData icon, String label) = item.isImage
        ? (Icons.image_rounded, 'IMAGE')
        : item.isAudio
        ? (Icons.headphones_rounded, 'AUDIO')
        : (Icons.play_arrow_rounded, 'VIDEO');
    return Padding(
      padding: EdgeInsets.only(bottom: 10),
      child: _glass(
        blur: 14,
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(22),
        child: Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: EdgeInsets.fromLTRB(12, 6, 6, 6),
            onTap: busy ? null : () => _openItem(item),
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_accentSoft, _accent.withValues(alpha: .04)],
                ),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: _accent.withValues(alpha: .18)),
              ),
              child: !item.isAudio && item.thumbnailUrl.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SmartNetworkImage(
                        url: item.thumbnailUrl,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        placeholderColor: _accentSoft,
                        placeholderIcon: icon,
                        accentColor: _accent,
                      ),
                    )
                  : Icon(icon, color: _accent, size: 22),
            ),
            title: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Row(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: _accentSoft,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: _accent,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .4,
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  '${item.ext.replaceAll('.', '').toUpperCase()} · ${(item.fileSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _secondaryText,
                  ),
                ),
              ],
            ),
            trailing: busy
                ? SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _accent,
                    ),
                  )
                : PopupMenuButton<String>(
                    tooltip: 'File options',
                    color: _dark ? context.palette.card : context.palette.card,
                    onSelected: (action) {
                      if (action == 'details') {
                        _showItemDetails(item);
                      } else {
                        _updateItem(vault, item, restore: action == 'restore');
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'details', child: Text('Details')),
                      PopupMenuItem(
                        value: 'restore',
                        child: Text('Restore to Downloads'),
                      ),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  void _showItemDetails(VaultItem item) {
    final record = item.downloadRecord ?? const <String, dynamic>{};
    final originalUrl = record['originalUrl']?.toString() ?? '';
    showMediaDetails(
      context,
      title: item.title,
      creator: record['author']?.toString() ?? '',
      platform: originalUrl.isEmpty
          ? ''
          : (Uri.tryParse(originalUrl)?.host ?? ''),
      sourceUrl: originalUrl,
      channelUrl: record['channelUrl']?.toString() ?? '',
      filePath: item.vaultPath,
      format:
          '${item.ext.replaceAll('.', '').toUpperCase()}${(record['formatLabel']?.toString().isNotEmpty ?? false) ? ' · ${record['formatLabel']}' : ''}',
      fileSize: item.fileSize,
      downloadedAt:
          DateTime.tryParse(record['completedAt']?.toString() ?? '') ??
          item.addedAt,
    );
  }

  void _openItem(VaultItem item) {
    if (item.isImage) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => _VaultImageViewer(item: item)),
      );
      return;
    }
    final video = VideoItem(
      id: item.id,
      title: item.title,
      author: 'Secret Vault',
      duration: '',
      views: '',
      thumbnailUrl: '',
      videoUrl: item.vaultPath,
      platform: 'Vault',
    );
    PlayerService.instance.playVideoItem(video, isAudio: item.isAudio);
    if (item.isAudio && ModalRoute.of(context)?.isFirst == false) {
      Navigator.of(context)
          .push<void>(MaterialPageRoute(builder: (_) => AudioPlayerScreen()));
    }
  }

  Future<void> _updateItem(
    VaultService vault,
    VaultItem item, {
    required bool restore,
  }) async {
    if (!restore) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Delete this file?'),
          content: Text(item.title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _busyItems.add(item.id));
    try {
      if (restore) {
        await vault.restoreFromVault(item);
        if (mounted) _message('Restored to ${vault.sourceFolderFor(item)}');
      } else {
        await vault.deleteFromVault(item);
      }
    } on StateError catch (error) {
      if (mounted) _message(error.message);
    } catch (_) {
      if (mounted) {
        _message(
          restore ? 'Could not restore the file' : 'Could not delete the file',
        );
      }
    } finally {
      if (mounted) setState(() => _busyItems.remove(item.id));
    }
  }
}

/// Minimal, modern full-screen image viewer for vault images.
class _VaultImageViewer extends StatelessWidget {
  _VaultImageViewer({required this.item});

  final VaultItem item;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.background,
      appBar: AppBar(
        backgroundColor: context.palette.background,
        foregroundColor: context.palette.card,
        title: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.file(
            File(item.vaultPath),
            errorBuilder: (_, _, _) => Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Could not open this image',
                style: TextStyle(color: context.palette.textSecondary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
