import 'dart:io';

import 'package:flutter/material.dart';

import '../services/permission_service.dart';
import '../theme/app_palette.dart';

class PermissionDialog extends StatefulWidget {
  PermissionDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PermissionDialog(),
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
          backgroundColor: storageOk
              ? context.palette.success
              : context.palette.card,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          content: Row(
            children: [
              Icon(
                storageOk
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                color: context.palette.textPrimary,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  storageOk
                      ? 'Storage permissions granted! Downloads saved to Downloads/All in One'
                      : 'Permissions updated. You can adjust permissions anytime in Settings.',
                  style: TextStyle(color: context.palette.textPrimary, fontSize: 13),
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
    final bg = context.palette.card;
    final textCol = isDark ? context.palette.card : context.palette.background;
    final subTextCol = context.palette.textSecondary;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: context.palette.shadowAt(0.4),
            blurRadius: 25,
            offset: Offset(0, -5),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(24, 16, 24, 28),
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
                  color: isDark ? context.palette.tint(context.palette.onScrim, 0.24) : context.palette.tint(context.palette.border, 0.12),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            SizedBox(height: 20),

            // Header with badge
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [context.palette.primary, context.palette.info],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: context.palette.tint(context.palette.primary, 0.35),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.security_update_good_rounded,
                    color: context.palette.background,
                    size: 28,
                  ),
                ),
                SizedBox(width: 16),
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
                      SizedBox(height: 3),
                      Text(
                        'Allow access to store downloads on your phone',
                        style: TextStyle(color: subTextCol, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            SizedBox(height: 22),

            // Feature Permission Items
            _buildPermissionItem(
              icon: Icons.folder_special_rounded,
              iconColor: context.palette.primary,
              title: 'Storage & Media Access',
              subtitle: 'Allows Tub Pure to save downloaded videos, audio, and movies into your phone\'s public Downloads folder so you can view them in Gallery or VLC.',
              isDark: isDark,
            ),
            SizedBox(height: 12),

            _buildPermissionItem(
              icon: Icons.notifications_active_rounded,
              iconColor: context.palette.info,
              title: 'Download Notifications',
              subtitle: 'Shows real-time download speed, progress bar, and completion notifications in your Android status bar.',
              isDark: isDark,
            ),

            if (Platform.isAndroid) ...[
              SizedBox(height: 12),
              _buildPermissionItem(
                icon: Icons.auto_awesome_rounded,
                iconColor: context.palette.success,
                title: 'High-Speed Parallel Multi-Threading',
                subtitle: 'Zero bloatware, 100% private. Files are stored only on your local device without any third-party tracking.',
                isDark: isDark,
              ),
            ],

            SizedBox(height: 24),

            // Action Buttons
            ElevatedButton(
              onPressed: _isRequesting ? null : _handleGrantAll,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.palette.primary,
                foregroundColor: context.palette.background,
                padding: EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 3,
              ),
              child: _isRequesting
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: context.palette.background,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.check_circle_outline_rounded,
                          size: 20,
                          color: context.palette.background,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Allow All Permissions',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: context.palette.background,
                          ),
                        ),
                      ],
                    ),
            ),

            SizedBox(height: 10),

            TextButton(
              onPressed: _handleLater,
              style: TextButton.styleFrom(
                foregroundColor: subTextCol,
                padding: EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text(
                'Not Now / Ask Later',
                style: TextStyle(fontSize: 14),
              ),
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
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? context.palette.surface : context.palette.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: isDark ? context.palette.card : context.palette.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: context.palette.textSecondary,
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
