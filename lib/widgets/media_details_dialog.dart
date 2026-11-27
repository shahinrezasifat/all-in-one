import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows the source and file metadata retained for a downloaded media item.
Future<void> showMediaDetails(
  BuildContext context, {
  required String title,
  String creator = '',
  String platform = '',
  String sourceUrl = '',
  String channelUrl = '',
  String filePath = '',
  String format = '',
  int fileSize = 0,
  DateTime? downloadedAt,
}) async {
  final palette = Theme.of(context).colorScheme;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detail('Channel / creator', creator),
            _detail('Website / platform', platform),
            _detail('Format', format),
            if (fileSize > 0) _detail('File size', _formatBytes(fileSize)),
            if (downloadedAt != null)
              _detail(
                'Downloaded',
                downloadedAt.toLocal().toString().split('.').first,
              ),
            if (filePath.isNotEmpty) _detail('Saved file', filePath),
            if (sourceUrl.isNotEmpty) ...[
              const SizedBox(height: 12),
              _linkButton('Open original page', sourceUrl, palette),
            ],
            if (channelUrl.isNotEmpty && channelUrl != sourceUrl) ...[
              const SizedBox(height: 6),
              _linkButton('Open channel page', channelUrl, palette),
            ],
            if (sourceUrl.isEmpty && channelUrl.isEmpty)
              const Text('Source links were not available for this item.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Widget _detail(String label, String value) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: SelectableText('$label: ${value.isEmpty ? 'Unavailable' : value}'),
);

Widget _linkButton(String label, String value, ColorScheme colors) => Align(
  alignment: Alignment.centerLeft,
  child: TextButton.icon(
    onPressed: () async {
      final uri = Uri.tryParse(value);
      if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    },
    icon: Icon(Icons.open_in_new_rounded, color: colors.primary),
    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  ),
);

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024)
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  if (bytes >= 1024 * 1024)
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}
