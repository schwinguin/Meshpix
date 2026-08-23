import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/chat.dart';
import '../state/app_controller.dart';
import 'chat_screen.dart';
import 'theme.dart';

/// Kanäle: Verzeichnis aller Kanäle, die es auf dem Knoten wirklich gibt:
/// Public (0) + benannte Slots 1–7 (analog MeshCore-App). Leere Slots
/// (nie angelegt/beigetreten) erscheinen nicht. "+" legt einen Kanal an.
class ChannelsPane extends StatelessWidget {
  const ChannelsPane({super.key});

  static int? freeSlot(List<MeshChannel> channels) {
    final used = channels
        .where((c) => c.index == 0 || c.name.isNotEmpty)
        .map((c) => c.index)
        .toSet();
    for (var i = 1; i <= 7; i++) {
      if (!used.contains(i)) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final all = app.active.companion?.channels ?? const <MeshChannel>[];
    final channels = all
        .where((c) => c.index == 0 || c.name.isNotEmpty)
        .toList();
    final free = freeSlot(all);
    return Scaffold(
      body: channels.isEmpty
          ? const Center(child: Text('Keine Kanäle'))
          : ListView.builder(
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
                      MaterialPageRoute<void>(
                        builder: (_) => const ChatScreen(),
                      ),
                    );
                  };
                }
                return ListTile(
                  leading: Icon(
                    ch.isPublic
                        ? Icons.public
                        : private
                        ? Icons.lock_outline
                        : Icons.campaign_outlined,
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
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${conv?.messages.length ?? 0}'),
                      IconButton(
                        tooltip: app.mutedChannels.contains(ch.name)
                            ? 'Gedämpft — aktivieren'
                            : 'Dämpfen',
                        onPressed: () => app.toggleMutedChannel(ch.name),
                        icon: Icon(
                          app.mutedChannels.contains(ch.name)
                              ? Icons.notifications_off
                              : Icons.notifications_active_outlined,
                        ),
                      ),
                    ],
                  ),
                  onTap: onTap,
                  onLongPress: () async {
                    final v = await showMenu<String>(
                      context: context,
                      position: const RelativeRect.fromLTRB(72, 24, 0, 0),
                      items: [
                        PopupMenuItem(
                          value: 'mute',
                          child: Text(
                            app.mutedChannels.contains(ch.name)
                                ? 'Entdämpfen'
                                : 'Dämpfen',
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Kanal löschen'),
                        ),
                      ],
                    );
                    if (!context.mounted) return;
                    switch (v) {
                      case 'mute':
                        app.toggleMutedChannel(ch.name);
                      case 'delete':
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Kanal löschen?'),
                            content: Text(
                              '„${ch.name}" (Kanal ${ch.index}) wird frei gegeben.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Abbrechen'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Löschen'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true && context.mounted) {
                          await app.deleteChannel(ch.index);
                        }
                    }
                  },
                );
              },
            ),
      floatingActionButton: free == null
          ? null
          : FloatingActionButton(
              tooltip: 'Neuer Kanal',
              onPressed: () => _showCreateChannel(context, app),
              child: const Icon(Icons.add),
            ),
    );
  }
}

Future<void> _showCreateChannel(BuildContext context, AppController app) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Neuer Kanal'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 32,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Anlegen'),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty || !context.mounted) return;
  await app.createChannel(trimmed);
}
