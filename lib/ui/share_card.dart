import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'theme.dart';

class ShareCardSheet extends StatelessWidget {
  const ShareCardSheet({
    super.key,
    required this.title,
    required this.uri,
    this.subtitle,
  });

  final String title;
  final String uri;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: const TextStyle(color: meshPaper)),
          ],
          const SizedBox(height: 16),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(
              data: uri,
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            uri,
            style: const TextStyle(fontSize: 12, color: meshPaper),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: uri));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('meshcore:// in Zwischenablage'),
                  ),
                );
              }
            },
            child: const Text('URI kopieren'),
          ),
        ],
      ),
    );
  }
}

Future<void> showShareCard(
  BuildContext context, {
  required String title,
  required String uri,
  String? subtitle,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ShareCardSheet(title: title, uri: uri, subtitle: subtitle),
  );
}
