import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat.dart';
import '../state/app_controller.dart';
import 'chat_screen.dart';
import 'theme.dart';

/// Kanäle: Verzeichnis aller Kanäle, die der Knoten abonniert hat
/// (analog MeshCore-App). Leere Kanäle gehören hierher — nicht in die
/// Chat-Übersicht. Antippen öffnet den Channel-Chat.
class ChannelsPane extends StatelessWidget {
  const ChannelsPane({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    if (app.sessions.isEmpty) {
      return const Center(child: Text('Kein Mesh verbunden'));
    }
    final channels = app.active.companion?.channels ?? const [];
    if (channels.isEmpty) {
      return const Center(child: Text('Keine Kanäle'));
    }
    return ListView.builder(
      itemCount: channels.length,
      itemBuilder: (context, i) {
        final ch = channels[i];
        Conversation? conv;
        for (final c in app.active.conversations) {
          if (c.isChannel && c.channelIdx == ch.index) {
            conv = c;
            break;
          }
        }
        final private = ch.secret != null;
        void Function()? onTap;
        if (conv != null) {
          final c = conv;
          onTap = () {
            app.open(c);
            Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
            );
          };
        }
        return ListTile(
          leading: Icon(
            ch.isPublic ? Icons.public : private ? Icons.lock_outline : Icons.campaign_outlined,
            color: ch.isPublic ? meshTeal : meshAmber,
          ),
          title: Text(ch.name),
          subtitle: Text(
            [
              'Kanal ${ch.index}',
              private ? 'Privat' : 'Flood ohne ACK',
              if (conv?.hasPendingCatchUp ?? false) 'Nachziehen offen',
            ].join(' · '),
          ),
          trailing: Text('${conv?.messages.length ?? 0}'),
          onTap: onTap,
        );
      },
    );
  }
}
