import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/site_model.dart';
import '../theme/app_palette.dart';
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: context.palette.tint(context.palette.textSecondary, 0.4),
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
                  leading: Icon(
                    Icons.open_in_browser_rounded,
                    color: context.palette.primary,
                  ),
                  title: const Text('Open in In-App Browser'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onSiteTap(site);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.edit_outlined,
                    color: context.palette.onPrimary,
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
                    leading: Icon(
                      Icons.delete_outline_rounded,
                      color: context.palette.error,
                    ),
                    title: Text(
                      'Delete Bookmark',
                      style: TextStyle(color: context.palette.error),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 680
            ? 6
            : constraints.maxWidth >= 272
                ? 4
                : 3;

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: sites.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 8,
            mainAxisExtent: 84,
          ),
          itemBuilder: (context, index) {
            final site = sites[index];
            final brand = Color(site.colorHex);
            final glow = brand.computeLuminance() < .02
                ? context.palette.textSecondary
                : brand;

            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => onSiteTap(site),
                onLongPress: () => _showSiteOptions(context, site),
                child: Tooltip(
                  message: site.title,
                  triggerMode: TooltipTriggerMode.manual,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 52,
                          height: 52,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isDark
                                ? glow.withValues(alpha: 0.15)
                                : Colors.white,
                            gradient: RadialGradient(
                              colors: [
                                glow.withValues(alpha: isDark ? .28 : .21),
                                glow.withValues(alpha: isDark ? .10 : .07),
                                glow.withValues(alpha: 0),
                              ],
                              stops: const [0, .64, 1],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: glow.withValues(alpha: isDark ? 0.32 : 0.20),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: glow.withValues(alpha: isDark ? 0.22 : 0.12),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: SmartNetworkImage(
                            url: site.icon,
                            width: 28,
                            height: 28,
                            fit: BoxFit.contain,
                            placeholderIcon: Icons.public_rounded,
                            accentColor: isDark ? glow : brand,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Flexible(
                          child: Text(
                            site.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: isDark ? Colors.white70 : Colors.black87,
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
