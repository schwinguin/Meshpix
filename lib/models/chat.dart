import 'dart:typed_data';

import '../codec/mp1.dart';

enum ChatKind { text, image }

enum DeliveryStatus { sending, sent, delivered, failed }

enum ChannelPeerState { pending, live, replayed, delivered }

class ChannelPeerAck {
  ChannelPeerAck({
    required this.keyHex,
    required this.name,
    required this.state,
  });

  final String keyHex;
  final String name;
  ChannelPeerState state;

  ChannelPeerAck copyWith({ChannelPeerState? state, String? name}) {
    return ChannelPeerAck(
      keyHex: keyHex,
      name: name ?? this.name,
      state: state ?? this.state,
    );
  }
}

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
    this.catchUpId,
    this.catchUp = false,
    List<ChannelPeerAck>? channelAcks,
  }) : channelAcks = channelAcks ?? [];

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
  final int? catchUpId;
  final bool catchUp;
  final List<ChannelPeerAck> channelAcks;

  bool get isPulling => pullTotal != null;
  bool get hasChannelTracking => channelAcks.isNotEmpty;
  int get channelKnown => channelAcks.length;
  int get channelGot => channelAcks
      .where((a) =>
          a.state == ChannelPeerState.live ||
          a.state == ChannelPeerState.delivered)
      .length;
  int get channelPending => channelAcks
      .where((a) =>
          a.state == ChannelPeerState.pending ||
          a.state == ChannelPeerState.replayed)
      .length;

  String get channelTrackLabel {
    if (!hasChannelTracking) return '';
    if (channelPending == 0) {
      return 'Flood · $channelGot/$channelKnown gehört';
    }
    final missing = channelAcks
        .where((a) =>
            a.state == ChannelPeerState.pending ||
            a.state == ChannelPeerState.replayed)
        .map((a) => a.name)
        .join(', ');
    return 'Flood · $channelGot/$channelKnown gehört ($missing fehlt)';
  }

  ChatMessage withPeerAck(String keyOrPrefixHex, ChannelPeerState state) {
    final needle = keyOrPrefixHex.toLowerCase();
    final next = <ChannelPeerAck>[];
    for (final a in channelAcks) {
      final hex = a.keyHex.toLowerCase();
      if (hex.startsWith(needle) || needle.startsWith(hex)) {
        next.add(a.copyWith(state: state));
      } else {
        next.add(a);
      }
    }
    return copyWith(channelAcks: next);
  }

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
    int? catchUpId,
    bool? catchUp,
    List<ChannelPeerAck>? channelAcks,
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
      catchUpId: catchUpId ?? this.catchUpId,
      catchUp: catchUp ?? this.catchUp,
      channelAcks: channelAcks ?? this.channelAcks,
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

  bool get hasPendingCatchUp => messages.any(
        (m) => m.outgoing && m.hasChannelTracking && m.channelPending > 0,
      );

  String? get preview {
    final m = lastMessage;
    if (m == null) return null;
    if (m.kind == ChatKind.image) return 'Bild';
    return m.text;
  }
}
