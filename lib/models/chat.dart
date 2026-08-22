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
    this.pullReceived,
    this.pullTotal,
  });

  final String id;
  final ChatKind kind;
  final bool outgoing;
  final DateTime timestamp;
  final String? text;
  final DecodedImage? image;
  final int? transferId;
  final bool canPull;

  /// Nicht null, solange der Empfänger Nachzug-Pakete sammelt.
  final int? pullReceived;
  final int? pullTotal;

  bool get isPulling => pullTotal != null;

  ChatMessage copyWith({
    String? text,
    DecodedImage? image,
    bool? canPull,
    int? pullReceived,
    int? pullTotal,
  }) {
    return ChatMessage(
      id: id,
      kind: kind,
      outgoing: outgoing,
      timestamp: timestamp,
      text: text ?? this.text,
      image: image ?? this.image,
      transferId: transferId,
      canPull: canPull ?? this.canPull,
      pullReceived: pullReceived ?? this.pullReceived,
      pullTotal: pullTotal ?? this.pullTotal,
    );
  }
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
