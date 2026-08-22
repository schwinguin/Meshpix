import 'dart:typed_data';

import '../codec/mp1.dart';

enum ChatKind { text, image }

enum DeliveryStatus { sending, sent, delivered, failed }

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
    this.delivery = DeliveryStatus.sent,
    this.ackCode,
    this.rttMs,
    this.hopCount,
    this.snr,
    this.senderName,
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
  final DeliveryStatus delivery;
  final int? ackCode;
  final int? rttMs;
  final int? hopCount;
  final double? snr;
  final String? senderName;

  bool get isPulling => pullTotal != null;

  ChatMessage copyWith({
    String? text,
    DecodedImage? image,
    bool? canPull,
    int? pullReceived,
    int? pullTotal,
    DeliveryStatus? delivery,
    int? ackCode,
    int? rttMs,
    int? hopCount,
    double? snr,
    String? senderName,
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
      delivery: delivery ?? this.delivery,
      ackCode: ackCode ?? this.ackCode,
      rttMs: rttMs ?? this.rttMs,
      hopCount: hopCount ?? this.hopCount,
      snr: snr ?? this.snr,
      senderName: senderName ?? this.senderName,
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
    this.peerType,
    this.favourite = false,
  });

  final String id;
  String title;
  final bool isChannel;
  final int? channelIdx;
  final Uint8List? peerKey;
  int? peerType;
  bool favourite;
  final messages = <ChatMessage>[];
  int unread = 0;

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  String? get preview {
    final m = lastMessage;
    if (m == null) return null;
    if (m.kind == ChatKind.image) return 'Bild';
    return m.text;
  }
}
