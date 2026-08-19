import 'dart:typed_data';

import '../codec/mp1.dart';

enum ChatKind { text, image }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.kind,
    required this.outgoing,
    required this.timestamp,
    this.text,
    this.image,
    this.transferId,
    this.canPull = false,
  });

  final String id;
  final ChatKind kind;
  final bool outgoing;
  final DateTime timestamp;
  final String? text;
  final DecodedImage? image;
  final int? transferId;
  final bool canPull;
}

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.isChannel,
    this.channelIdx,
    this.peerKey,
  });

  final String id;
  final String title;
  final bool isChannel;
  final int? channelIdx;
  final Uint8List? peerKey;
  final messages = <ChatMessage>[];
}
