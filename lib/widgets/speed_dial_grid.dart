import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/site_model.dart';
import '../theme/app_colors.dart';
import 'remote_image.dart';

class SpeedDialGrid extends StatelessWidget {
  final List<SiteModel> sites;
  final Function(SiteModel) onSiteTap;
  final Function(SiteModel)? onEditBookmark;
  final Function(SiteModel)? onDeleteBookmark;

  const SpeedDialGrid({
    super.key,
    required this.sites,
    required this.onSiteTap,
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
                  title: Text(
                    site.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    site.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(
                    Icons.open_in_browser_rounded,
                    color: AppColors.primary,
                  ),
                  title: const Text('Open in In-App Browser'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onSiteTap(site);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.edit_outlined,
                    color: AppColors.accentGold,
                  ),
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
                    leading: const Icon(
                      Icons.delete_outline_rounded,
                      color: AppColors.accentRed,
                    ),
                    title: const Text(
                      'Delete Bookmark',
                      style: TextStyle(color: AppColors.accentRed),
                    ),
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final labelHeight = MediaQuery.textScalerOf(context).scale(12);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 680
            ? 6
            : constraints.maxWidth >= 272 && labelHeight <= 16
            ? 4
            : 3;
        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: sites.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 6,
            crossAxisSpacing: 4,
            mainAxisExtent: 59 + labelHeight * 2.4,
          ),
          itemBuilder: (context, index) {
            final site = sites[index];
            final brand = Color(site.colorHex);
            final glow = brand.computeLuminance() < .02
                ? const Color(0xFF25C9BA)
                : brand;
            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onSiteTap(site),
                onLongPress: () => _showSiteOptions(context, site),
                child: Tooltip(
                  message: site.title,
                  triggerMode: TooltipTriggerMode.manual,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              colors: [
                                glow.withValues(alpha: isDark ? .28 : .21),
                                glow.withValues(alpha: isDark ? .10 : .07),
                                glow.withValues(alpha: 0),
                              ],
                              stops: const [0, .64, 1],
                            ),
                          ),
                          child: SmartNetworkImage(
                            url: site.icon,
                            width: 32,
                            height: 32,
                            fit: BoxFit.contain,
                            placeholderIcon: Icons.public_rounded,
                            accentColor: isDark ? glow : brand,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            site.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontSize: 12,
                              height: 1.15,
                              fontWeight: FontWeight.w600,
                            ),
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
      },
    );
  }
}
