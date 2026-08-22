import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/contact.dart';
import '../state/app_controller.dart';
import 'chat_screen.dart';
import 'format.dart';
import 'share_card.dart';
import 'theme.dart';

class ContactDetailScreen extends StatelessWidget {
  const ContactDetailScreen({super.key, required this.contact});

  final MeshContact contact;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final live = app.contacts.cast<MeshContact?>().firstWhere(
          (c) => c != null && c.keyHex == contact.keyHex,
          orElse: () => contact,
        )!;
    return Scaffold(
      appBar: AppBar(
        title: Text(live.name),
        actions: [
          IconButton(
            tooltip: live.isFavourite ? 'Favorit entfernen' : 'Favorit',
            onPressed: () => app.toggleFavourite(live),
            icon: Icon(live.isFavourite ? Icons.star : Icons.star_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: Icon(_icon(live.type), color: meshTeal, size: 36),
            title: Text(live.name),
            subtitle: Text('${AdvType.label(live.type)} · ${live.shortKey}…'),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Zuletzt gehört'),
            subtitle: Text(formatHeard(live.lastHeard)),
          ),
          ListTile(
            leading: const Icon(Icons.alt_route),
            title: const Text('Pfad'),
            subtitle: Text(
              live.hasPath ? '${live.hopCount} Hop${live.hopCount == 1 ? '' : 's'}' : 'kein gespeicherter Pfad',
            ),
          ),
          if (live.hasLocation)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: const Text('Position'),
              subtitle: Text(
                '${live.lat!.toStringAsFixed(5)}, ${live.lon!.toStringAsFixed(5)}',
              ),
            ),
          const Divider(),
          if (live.isChat)
            FilledButton.icon(
              onPressed: () {
                app.openContact(live);
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
                );
              },
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Nachricht'),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => app.ping(live),
                icon: const Icon(Icons.sensors),
                label: const Text('Ping / Status'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => showShareCard(
                  context,
                  title: live.name,
                  subtitle: AdvType.label(live.type),
                  uri: app.exportContactUri(live),
                ),
                icon: const Icon(Icons.qr_code_2),
                label: const Text('QR teilen'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => app.shareZeroHop(live),
                icon: const Icon(Icons.cell_tower),
                label: const Text('Zero-Hop teilen'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => app.resetPath(live),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Pfad reset'),
              ),
              TextButton.icon(
                onPressed: () async {
                  await app.deleteContact(live);
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                label: const Text('Löschen', style: TextStyle(color: Colors.redAccent)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _icon(int type) {
    switch (type) {
      case AdvType.repeater:
        return Icons.cell_tower;
      case AdvType.room:
        return Icons.meeting_room_outlined;
      case AdvType.sensor:
        return Icons.thermostat;
      default:
        return Icons.person_outline;
    }
  }
}
