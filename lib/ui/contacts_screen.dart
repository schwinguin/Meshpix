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

/// Knoten: alle bekannten Mesh-Knoten, untergliedert nach Rolle
/// (analog MeshCore-App): Kontakte (Chat-Knoten), Repeater, Sonstige.
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
      return const Center(child: Text('Noch keine Knoten'));
    }
    final chat = items.where((c) => c.isChat).toList();
    final repeaters = items.where((c) => c.type == AdvType.repeater).toList();
    final other =
        items.where((c) => !c.isChat && c.type != AdvType.repeater).toList();
    return ListView(
      children: [
        if (chat.isNotEmpty) ...[
          _header('Kontakte'),
          for (final c in chat) _row(context, app, c),
        ],
        if (repeaters.isNotEmpty) ...[
          _header('Repeater'),
          for (final c in repeaters) _row(context, app, c),
        ],
        if (other.isNotEmpty) ...[
          _header('Andere'),
          for (final c in other) _row(context, app, c),
        ],
      ],
    );
  }

  Widget _header(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: meshAmber,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, AppController app, MeshContact c) {
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Ping',
            onPressed: () {
              app.showPath(focus: c);
              app.ping(c);
            },
            icon: const Icon(Icons.podcasts, size: 20),
          ),
          if (c.isFavourite) const Icon(Icons.star, color: meshAmber, size: 18),
        ],
      ),
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
