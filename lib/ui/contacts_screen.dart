import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/contact.dart';
import '../state/app_controller.dart';
import 'chat_screen.dart';
import 'contact_detail.dart';
import 'format.dart';
import 'repeater_admin_screen.dart';
import 'theme.dart';

class ContactsPane extends StatelessWidget {
  const ContactsPane({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final items = [...app.contacts]
      ..sort((a, b) {
        if (a.isFavourite != b.isFavourite) return a.isFavourite ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    if (items.isEmpty) {
      return const Center(child: Text('Noch keine Kontakte'));
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final c = items[i];
        return ListTile(
          leading: Icon(
            _icon(c.type),
            color: c.isFavourite ? meshAmber : meshTeal,
          ),
          title: Text(c.name),
          subtitle: Text(
            [
              AdvType.label(c.type),
              if (c.hasPath) '${c.hopCount} Hop',
              formatHeard(c.lastHeard),
            ].join(' · '),
          ),
          trailing: c.isFavourite ? const Icon(Icons.star, color: meshAmber, size: 18) : null,
          onTap: () {
            if (c.isChat) {
              app.openContact(c);
              Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
              );
            } else if (c.isAdminNode) {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => RepeaterAdminScreen(contact: c),
                ),
              );
            } else {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ContactDetailScreen(contact: c),
                ),
              );
            }
          },
          onLongPress: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ContactDetailScreen(contact: c),
              ),
            );
          },
        );
      },
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

Future<void> importFromClipboard(BuildContext context, AppController app) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final err = await app.importContactUri(data?.text ?? '');
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(err ?? 'Kontakt importiert')),
  );
}
