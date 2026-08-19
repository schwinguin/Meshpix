import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat.dart';
import '../state/app_controller.dart';
import 'composer_screen.dart';
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
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(conv.title),
            Text(
              conv.isChannel ? 'Channel · nur Preview' : 'Direct · Nachzug möglich',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
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
            if (message.text != null && message.text!.isNotEmpty) ...[
              if (message.image != null) const SizedBox(height: 8),
              Text(message.text!),
            ],
            if (onPull != null)
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
