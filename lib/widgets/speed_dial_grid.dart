import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/site_model.dart';
import '../theme/app_colors.dart';
import 'remote_image.dart';

class SpeedDialGrid extends StatelessWidget {
  final List<SiteModel> sites;
  final Function(SiteModel) onSiteTap;
  final VoidCallback onAddBookmark;
  final Function(SiteModel)? onEditBookmark;
  final Function(SiteModel)? onDeleteBookmark;

  const SpeedDialGrid({
    super.key,
    required this.sites,
    required this.onSiteTap,
    required this.onAddBookmark,
    this.onEditBookmark,
    this.onDeleteBookmark,
  });

  void _showSiteOptions(BuildContext context, SiteModel site) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SmartNetworkImage(
                      url: site.icon,
                      width: 28,
                      height: 28,
                      placeholderIcon: Icons.language_rounded,
                    ),
                  ),
                  title: Text(site.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(site.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.open_in_browser_rounded, color: AppColors.primary),
                  title: const Text('Open in In-App Browser'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onSiteTap(site);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.edit_outlined, color: AppColors.accentGold),
                  title: const Text('Edit Bookmark'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onEditBookmark?.call(site);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('Copy URL'),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: site.url));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Copied ${site.url}'),
                        duration: const Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
                if (site.isCustom || onDeleteBookmark != null)
                  ListTile(
                    leading: const Icon(Icons.delete_outline_rounded, color: AppColors.accentRed),
                    title: const Text('Delete Bookmark', style: TextStyle(color: AppColors.accentRed)),
                    onTap: () {
                      Navigator.pop(ctx);
                      onDeleteBookmark?.call(site);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final displayedSites = sites;

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 650 ? 8 : 4;

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          itemCount: displayedSites.length + 1,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 16,
            crossAxisSpacing: 12,
            mainAxisExtent: 88,
          ),
          itemBuilder: (context, index) {
            if (index == displayedSites.length) {
              return _buildAddTile(isDark);
            }
            final site = displayedSites[index];
            return _buildSiteTile(context, site, isDark);
          },
        );
      },
    );
  }

  Widget _buildSiteTile(BuildContext context, SiteModel site, bool isDark) {
    final siteColor = Color(site.colorHex);

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onSiteTap(site),
            onLongPress: () => _showSiteOptions(context, site),
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: siteColor.withValues(alpha: isDark ? 0.10 : 0.06),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SmartNetworkImage(
                        url: site.icon,
                        width: 24,
                        height: 24,
                        fit: BoxFit.contain,
                        placeholderIcon: Icons.public_rounded,
                        accentColor: siteColor,
                      ),
                    ),
                  ),
                ),
                if (site.isCustom)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: AppColors.accentGold,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.star, color: Colors.black, size: 8),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 72,
          child: Text(
            site.title,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAddTile(bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onAddBookmark,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkCard : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Center(
                child: Icon(
                  Icons.add_rounded,
                    color: AppColors.primary,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Add',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
            ),
          ),
        ],
    );
  }
}
