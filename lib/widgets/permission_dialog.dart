import 'dart:io';
import 'package:flutter/material.dart';
import '../services/permission_service.dart';
import '../theme/app_colors.dart';

class PermissionDialog extends StatefulWidget {
  const PermissionDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const PermissionDialog(),
    );
  }

  @override
  State<PermissionDialog> createState() => _PermissionDialogState();
}

class _PermissionDialogState extends State<PermissionDialog> {
  bool _isRequesting = false;

  Future<void> _handleGrantAll() async {
    setState(() => _isRequesting = true);
    
    await PermissionService.instance.markStartupPromptShown();
    final results = await PermissionService.instance.requestAllPermissions();
    
    if (mounted) {
      setState(() => _isRequesting = false);
      Navigator.of(context).pop(true);

      final storageOk = results['storage'] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: storageOk ? AppColors.accentGreen : AppColors.darkCard,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          content: Row(
            children: [
              Icon(
                storageOk ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                color: Colors.white,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  storageOk
                      ? 'Storage permissions granted! Downloads saved to Downloads/SnapTube'
                      : 'Permissions updated. You can adjust permissions anytime in Settings.',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  void _handleLater() async {
    await PermissionService.instance.markStartupPromptShown();
    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF161B22) : Colors.white;
    final textCol = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextCol = isDark ? Colors.white70 : const Color(0xFF475569);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 25,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Header with badge
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppColors.primary, Color(0xFFFF9100)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.35),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.security_update_good_rounded, color: Colors.black, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Permissions Required',
                        style: TextStyle(
                          color: textCol,
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Allow access to store downloads on your phone',
                        style: TextStyle(
                          color: subTextCol,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 22),

            // Feature Permission Items
            _buildPermissionItem(
              icon: Icons.folder_special_rounded,
              iconColor: AppColors.primary,
              title: 'Storage & Media Access',
              subtitle: 'Allows Tub Pure to save downloaded videos, audio, and movies into your phone\'s public Downloads folder so you can view them in Gallery or VLC.',
              isDark: isDark,
            ),
            const SizedBox(height: 12),

            _buildPermissionItem(
              icon: Icons.notifications_active_rounded,
              iconColor: AppColors.accentBlue,
              title: 'Download Notifications',
              subtitle: 'Shows real-time download speed, progress bar, and completion notifications in your Android status bar.',
              isDark: isDark,
            ),

            if (Platform.isAndroid) ...[
              const SizedBox(height: 12),
              _buildPermissionItem(
                icon: Icons.auto_awesome_rounded,
                iconColor: AppColors.accentGreen,
                title: 'High-Speed Parallel Multi-Threading',
                subtitle: 'Zero bloatware, 100% private. Files are stored only on your local device without any third-party tracking.',
                isDark: isDark,
              ),
            ],

            const SizedBox(height: 24),

            // Action Buttons
            ElevatedButton(
              onPressed: _isRequesting ? null : _handleGrantAll,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 3,
              ),
              child: _isRequesting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_outline_rounded, size: 20, color: Colors.black),
                        SizedBox(width: 8),
                        Text(
                          'Allow All Permissions',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    ),
            ),

            const SizedBox(height: 10),

            TextButton(
              onPressed: _handleLater,
              style: TextButton.styleFrom(
                foregroundColor: subTextCol,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('Not Now / Ask Later', style: TextStyle(fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2633) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
