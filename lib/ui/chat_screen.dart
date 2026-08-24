import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/chat.dart';
import '../models/contact.dart';
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
  late final VoidCallback _onTextChange;

  @override
  void initState() {
    super.initState();
    // Senden-Button erst aktivieren, wenn Text da ist.
    _onTextChange = () => setState(() {});
    _text.addListener(_onTextChange);
  }

  @override
  void dispose() {
    _text.removeListener(_onTextChange);
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
          if (conv.isChannel)
            IconButton(
              tooltip: app.mutedChannels.contains(conv.title)
                  ? 'Gedämpft — aktivieren'
                  : 'Dämpfen',
              onPressed: () => app.toggleMutedChannel(conv.title),
              icon: Icon(
                app.mutedChannels.contains(conv.title)
                    ? Icons.notifications_off
                    : Icons.notifications_active_outlined,
              ),
            )
          else
            ..._dmActions(app, conv),
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
                crossAxisAlignment: CrossAxisAlignment.end,
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
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(
                        hintText: 'Nachricht',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(app),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _text.text.trim().isEmpty
                        ? null
                        : () => _send(app),
                    icon: const Icon(Icons.send),
                    tooltip: 'Senden',
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
    if (t.trim().isEmpty) return;
    _text.clear();
    FocusScope.of(context).unfocus();
    app.sendText(t);
  }

  List<Widget> _dmActions(AppController app, Conversation conv) {
    final key = conv.peerKey;
    MeshContact? contact;
    if (key != null && key.length >= 6) {
      for (final c in app.contacts) {
        if (c.publicKey.length < 6) continue;
        var ok = true;
        for (var i = 0; i < 6; i++) {
          if (c.publicKey[i] != key[i]) {
            ok = false;
            break;
          }
        }
        if (ok) {
          contact = c;
          break;
        }
      }
    }
    final c = contact;
    if (c == null) return const [];
    final muted = app.mutedContacts.contains(c.keyHex);
    final blocked = app.blockedContacts.contains(c.keyHex);
    return [
      IconButton(
        tooltip: 'Kontakt',
        onPressed: () => _openContact(c, context, app),
        icon: const Icon(Icons.info_outline),
      ),
      IconButton(
        tooltip: muted ? 'Gedämpft — aktivieren' : 'Dämpfen',
        onPressed: () => app.toggleMutedContact(c.keyHex),
        icon: Icon(
          muted ? Icons.notifications_off : Icons.notifications_active_outlined,
        ),
      ),
      IconButton(
        tooltip: blocked ? 'Blockiert — freigeben' : 'Blockieren',
        onPressed: () => app.toggleBlockedContact(c.keyHex),
        icon: Icon(blocked ? Icons.block : Icons.block_outlined),
      ),
    ];
  }

  void _openContact(MeshContact c, BuildContext context, AppController app) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => ContactDetailScreen(contact: c)),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.onPull});
  final ChatMessage message;
  final VoidCallback? onPull;

  @override
  Widget build(BuildContext context) {
    final align = message.outgoing
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final bg = message.outgoing
        ? meshTeal.withValues(alpha: 0.35)
        : meshCardElevated;
    // Bubble-Breite responsiv: auf großen Displays (Tablet) bis ~78 %,
    // auf kleinen nie breiter als 280 px.
    final maxW = math.min(280.0, MediaQuery.of(context).size.width * 0.78);
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(maxWidth: maxW),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: message.outgoing
              ? null
              : const Border(
                  top: BorderSide(color: Color(0xFF3A3D47)),
                  bottom: BorderSide(color: Color(0xFF3A3D47)),
                  left: BorderSide(color: Color(0xFF3A3D47)),
                  right: BorderSide(width: 0, color: Color(0x00000000)),
                ),
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
              TextButton(onPressed: onPull, child: const Text('Nachladen')),
          ],
        ),
      ),
    );
  }
}
