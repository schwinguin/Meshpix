import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/chat.dart';
import '../state/app_controller.dart';
import 'composer_screen.dart';
import 'contact_detail.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets/pixel_preview.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final conv = app.openConversation;
    if (conv == null) {
      return const Scaffold(body: Center(child: Text('Kein Chat')));
    }
    final channels = app.active.companion?.channels ?? const <MeshChannel>[];
    final ch = conv.isChannel
        ? channels.where((c) => c.index == conv.channelIdx).firstOrNull
        : null;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(conv.title),
            Text(
              conv.isChannel
                  ? 'Channel · ${ch?.secret != null ? 'Privat' : 'Flood ohne ACK'}'
                  : 'Direct · Nachzug möglich',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          if (!conv.isChannel)
            IconButton(
              tooltip: 'Kontakt',
              onPressed: () {
                final key = conv.peerKey;
                if (key == null) return;
                for (final c in app.contacts) {
                  if (c.publicKey.length >= 6 &&
                      key.length >= 6 &&
                      c.publicKey[0] == key[0] &&
                      c.publicKey[1] == key[1] &&
                      c.publicKey[2] == key[2]) {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ContactDetailScreen(contact: c),
                      ),
                    );
                    return;
                  }
                }
              },
              icon: const Icon(Icons.info_outline),
            ),
        ],
      ),
      body: Column(
        children: [
          if (conv.isChannel)
            Material(
              color: const Color(0xFF2A2D36),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        ch?.secret != null
                            ? 'Privater Kanal: nur Knoten mit dem Secret-Key können mitlesen.'
                            : 'Flood hat keine Empfangsbestätigung. Wer off-grid war, bekommt die Nachricht per DM nachgereicht, sobald er wieder wirbt.',
                        style: TextStyle(fontSize: 12, color: meshPaper),
                      ),
                    ),
                    if (conv.hasPendingCatchUp)
                      TextButton(
                        onPressed: () => app.replayChannel(),
                        child: const Text('Nachreichen'),
                      ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: conv.messages.length,
              itemBuilder: (context, i) => _Bubble(
                message: conv.messages[i],
                onPull: conv.messages[i].canPull
                    ? () => app.pull(conv.messages[i])
                    : null,
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const ComposerScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.photo_outlined),
                    tooltip: 'Bild',
                  ),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      decoration: const InputDecoration(
                        hintText: 'Nachricht',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(app),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: () => _send(app),
                    icon: const Icon(Icons.send),
                    style: IconButton.styleFrom(backgroundColor: meshTeal),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _send(AppController app) {
    final t = _text.text;
    _text.clear();
    app.sendText(t);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.onPull});
  final ChatMessage message;
  final VoidCallback? onPull;

  @override
  Widget build(BuildContext context) {
    final align = message.outgoing ? Alignment.centerRight : Alignment.centerLeft;
    final bg = message.outgoing ? meshTeal.withValues(alpha: 0.35) : const Color(0xFF2A2D36);
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.image != null)
              PixelPreview(image: message.image!, size: 132),
            if (message.senderName != null && !message.outgoing)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  message.senderName!,
                  style: const TextStyle(color: meshAmber, fontSize: 12),
                ),
              ),
            if (message.catchUp && !message.outgoing)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'nachgereicht',
                  style: TextStyle(fontSize: 11, color: meshAmber),
                ),
              ),
            if (message.text != null && message.text!.isNotEmpty) ...[
              if (message.image != null) const SizedBox(height: 8),
              Text(message.text!),
            ],
            const SizedBox(height: 4),
            Text(
              [
                formatTime(message.timestamp),
                if (message.outgoing) deliveryLabel(message),
                formatHops(hopCount: message.hopCount, snr: message.snr),
              ].where((s) => s.isNotEmpty).join(' · '),
              style: const TextStyle(fontSize: 11, color: meshPaper),
            ),
            if (message.hasChannelTracking) ...[
              const SizedBox(height: 4),
              Text(
                message.channelAcks
                    .map((a) => '${a.name} ${channelPeerLabel(a.state)}')
                    .join(' · '),
                style: const TextStyle(fontSize: 11, color: meshPaper),
              ),
            ],
            if (message.isPulling) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: (message.pullTotal ?? 0) > 0
                      ? (message.pullReceived ?? 0) / message.pullTotal!
                      : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Lade Nachzug … '
                  '${message.pullReceived ?? 0}/${message.pullTotal ?? 0} Pakete',
                ),
              ),
            ] else if (onPull != null)
              TextButton(
                onPressed: onPull,
                child: const Text('Nachladen'),
              ),
          ],
        ),
      ),
    );
  }
}
