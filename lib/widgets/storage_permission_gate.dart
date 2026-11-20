import 'dart:io';
import 'package:flutter/material.dart';
import '../services/download_manager.dart';
import '../services/permission_service.dart';
import '../theme/app_colors.dart';

class StoragePermissionGate extends StatefulWidget {
  final Widget child;

  const StoragePermissionGate({
    super.key,
    required this.child,
  });

  @override
  State<StoragePermissionGate> createState() => _StoragePermissionGateState();
}

class _StoragePermissionGateState extends State<StoragePermissionGate>
    with WidgetsBindingObserver {
  bool _isChecking = true;
  bool _hasStorage = false;
  bool _hasBattery = false;
  bool _hasNotif = false;
  bool _isRequesting = false;
  bool _promptedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStatusSilently();
    }
  }

  Future<void> _checkStatusSilently() async {
    if (!Platform.isAndroid) return;
    final storageOk = await PermissionService.instance.hasStoragePermission();
    final batteryOk = await PermissionService.instance.hasBatteryOptimizationPermission();
    final notifOk = await PermissionService.instance.hasNotificationPermission();

    if (mounted) {
      setState(() {
        _hasStorage = storageOk;
        _hasBattery = batteryOk;
        _hasNotif = notifOk;
      });
      if (storageOk) {
        await DownloadManager.instance.upgradeToPublicStorage();
      }
    }
  }

  Future<void> _checkInitialPermissions() async {
    if (!Platform.isAndroid) {
      setState(() {
        _hasStorage = true;
        _isChecking = false;
      });
      return;
    }

    final storageOk = await PermissionService.instance.hasStoragePermission();
    final batteryOk = await PermissionService.instance.hasBatteryOptimizationPermission();
    final notifOk = await PermissionService.instance.hasNotificationPermission();

    if (mounted) {
      setState(() {
        _hasStorage = storageOk;
        _hasBattery = batteryOk;
        _hasNotif = notifOk;
        _isChecking = false;
      });
    }

    // If storage is not granted on launch, auto-request permissions once
    if (!storageOk && !_promptedOnce) {
      _promptedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleRequestAll();
      });
    }
  }

  Future<void> _handleRequestAll() async {
    if (_isRequesting) return;
    setState(() => _isRequesting = true);

    try {
      final results = await PermissionService.instance.requestAllStartupPermissions();
      final storageOk = results['storage'] == true;
      final batteryOk = results['battery'] == true;
      final notifOk = results['notification'] == true;

      if (mounted) {
        setState(() {
          _hasStorage = storageOk;
          _hasBattery = batteryOk;
          _hasNotif = notifOk;
          _isRequesting = false;
        });

        if (storageOk) {
          await DownloadManager.instance.upgradeToPublicStorage();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: AppColors.accentGreen,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              content: const Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: Colors.black),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'স্টোরেজ পারমিশন অনুমোদিত হয়েছে! অ্যাপে স্বাগতম।',
                      style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.redAccent.shade700,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              duration: const Duration(seconds: 4),
              content: const Text(
                'স্টোরেজ পারমিশন ছাড়া অ্যাপ ওপেন করা যাবে না। অনুগ্রহ করে পারমিশন দিন।',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) setState(() => _isRequesting = false);
    }
  }

  Future<void> _handleOpenSettings() async {
    await PermissionService.instance.openSettings();
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.primary, Color(0xFFFF9100)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.4),
                      blurRadius: 20,
                    ),
                  ],
                ),
                child: const Icon(Icons.download_rounded, color: Colors.white, size: 40),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.primary),
              ),
            ],
          ),
        ),
      );
    }

    // If storage permission is granted (the mandatory requirement), render main app!
    if (_hasStorage || !Platform.isAndroid) {
      return widget.child;
    }

    // Otherwise, block entry with mandatory permission screen
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0F141C) : Colors.white;
    final cardBg = isDark ? const Color(0xFF161F2E) : const Color(0xFFF1F5F9);
    final borderCol = isDark ? const Color(0xFF24334A) : const Color(0xFFE2E8F0);
    final textCol = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextCol = isDark ? Colors.white70 : const Color(0xFF475569);

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // App Icon with pulsing glow
                  Center(
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.primary, Color(0xFFFF9100)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.45),
                            blurRadius: 28,
                            spreadRadius: 2,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.security_update_good_rounded, color: Colors.white, size: 44),
                    ),
                  ),

                  const SizedBox(height: 22),

                  // Title
                  Text(
                    'প্রয়োজনীয় পারমিশন দিন',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: textCol,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'সফটওয়্যারটি ওপেন ও ডাউনলোড করার জন্য স্টোরেজ পারমিশন বাধ্যতামূলক।',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: subTextCol,
                      height: 1.4,
                    ),
                  ),

                  const SizedBox(height: 26),

                  // Permission item 1: Storage (MANDATORY)
                  _buildPermissionCard(
                    icon: Icons.folder_special_rounded,
                    iconColor: AppColors.primary,
                    title: 'স্টোরেজ পারমিশন (আবশ্যক)',
                    subtitle: 'মুভি, গান ও ভিডিও ডাউনলোড করে ফোনে সেভ করার জন্য এই পারমিশন বাধ্যতামূলক। এটি ছাড়া সফটওয়্যার ওপেন হবে না।',
                    statusText: _hasStorage ? 'অনুমোদিত' : 'অনুমতি প্রয়োজন',
                    isGranted: _hasStorage,
                    isMandatory: true,
                    cardBg: cardBg,
                    borderCol: borderCol,
                    textCol: textCol,
                    subTextCol: subTextCol,
                  ),

                  const SizedBox(height: 12),

                  // Permission item 2: Battery optimization / background (Recommended)
                  _buildPermissionCard(
                    icon: Icons.battery_charging_full_rounded,
                    iconColor: const Color(0xFF00E676),
                    title: 'ব্যাকগ্রাউন্ড রানিং (প্রস্তাবিত)',
                    subtitle: 'স্ক্রিন বন্ধ থাকলেও ব্যাকগ্রাউন্ডে যেন নির্বিঘ্নে ডাউনলোড চলতে থাকে এবং অ্যান্ড্রয়েড ব্যাটারি সেভার যেন ডাউনলোড বন্ধ না করে।',
                    statusText: _hasBattery ? 'অ্যাক্টিভ' : 'ঐচ্ছিক',
                    isGranted: _hasBattery,
                    isMandatory: false,
                    cardBg: cardBg,
                    borderCol: borderCol,
                    textCol: textCol,
                    subTextCol: subTextCol,
                  ),

                  const SizedBox(height: 12),

                  // Permission item 3: Notification (Recommended)
                  _buildPermissionCard(
                    icon: Icons.notifications_active_rounded,
                    iconColor: const Color(0xFF29B6F6),
                    title: 'ডাউনলোড নোটিফিকেশন (প্রস্তাবিত)',
                    subtitle: 'ডাউনলোডের অগ্রগতি, স্পিড ও কমপ্লিশন নোটিফিকেশন দেখার জন্য।',
                    statusText: _hasNotif ? 'অ্যাক্টিভ' : 'ঐচ্ছিক',
                    isGranted: _hasNotif,
                    isMandatory: false,
                    cardBg: cardBg,
                    borderCol: borderCol,
                    textCol: textCol,
                    subTextCol: subTextCol,
                  ),

                  const SizedBox(height: 28),

                  // Primary Button: Grant All
                  ElevatedButton(
                    onPressed: _isRequesting ? null : _handleRequestAll,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 5,
                      shadowColor: AppColors.primary.withValues(alpha: 0.5),
                    ),
                    child: _isRequesting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.lock_open_rounded, size: 20, color: Colors.white),
                              SizedBox(width: 8),
                              Text(
                                'পারমিশন নিশ্চিত করুন (Grant Permission)',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                  ),

                  const SizedBox(height: 12),

                  // Secondary Button: Open App Settings (if denied)
                  OutlinedButton.icon(
                    onPressed: _handleOpenSettings,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: Icon(Icons.settings_rounded, size: 18, color: subTextCol),
                    label: Text(
                      'সেটিংস খুলুন (Open Settings)',
                      style: TextStyle(fontSize: 14, color: subTextCol, fontWeight: FontWeight.w600),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Warning footnote
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded, color: Colors.amber, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'স্টোরেজ পারমিশন না দিলে সফটওয়্যার ওপেন হবে না। বাকি পারমিশনগুলো ঐচ্ছিক।',
                            style: TextStyle(
                              color: Colors.amber,
                              fontSize: 12,
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
    );
  }

  Widget _buildPermissionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String statusText,
    required bool isGranted,
    required bool isMandatory,
    required Color cardBg,
    required Color borderCol,
    required Color textCol,
    required Color subTextCol,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: textCol,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: isGranted
                            ? AppColors.accentGreen.withValues(alpha: 0.2)
                            : (isMandatory
                                ? Colors.redAccent.withValues(alpha: 0.2)
                                : Colors.grey.withValues(alpha: 0.2)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isGranted
                              ? AppColors.accentGreen
                              : (isMandatory ? Colors.redAccent : subTextCol),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(color: subTextCol, fontSize: 11.5, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
