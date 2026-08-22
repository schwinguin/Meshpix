import 'dart:async';
import 'dart:typed_data';

import '../companion/control.dart';

/// Estimated airtime and the mandatory silence after a transmit.
class AirtimeBudget {
  AirtimeBudget({
    this.airtimeFactor = 2.0,
    this.bitsPerSecond = 1200,
  });

  /// Gap after TX as a multiple of on-air time (MeshCore AF).
  double airtimeFactor;

  /// Conservative LoRa-ish bitrate used for pacing (not SF-accurate).
  int bitsPerSecond;

  Duration airtimeFor(int payloadBytes) {
    final ms = (payloadBytes * 8 / bitsPerSecond * 1000).ceil();
    return Duration(milliseconds: ms < 1 ? 1 : ms);
  }

  Duration gapAfter(int payloadBytes) {
    final air = airtimeFor(payloadBytes);
    final gapMs = (air.inMilliseconds * airtimeFactor).ceil();
    return Duration(milliseconds: gapMs);
  }

  Duration waitAfter(int payloadBytes) {
    if (airtimeFactor <= 0) return Duration.zero;
    return airtimeFor(payloadBytes) + gapAfter(payloadBytes);
  }
}

enum TxPriority { text, control, preview, chunk }

class QueuedTx {
  QueuedTx({
    required this.priority,
    required this.payload,
    required this.destination,
    this.done,
  });

  final TxPriority priority;
  final Uint8List payload;
  final RadioDestination destination;
  final Completer<TxReceipt?>? done;
}

enum DestKind { channelFlood, directDm }

class RadioDestination {
  const RadioDestination.channel(this.channelIdx)
    : kind = DestKind.channelFlood,
      pubkeyPrefix = null,
      path = null;

  const RadioDestination.dm(this.pubkeyPrefix, {this.path})
    : kind = DestKind.directDm,
      channelIdx = null;

  final DestKind kind;
  final int? channelIdx;
  final Uint8List? pubkeyPrefix;
  final Uint8List? path;

  bool get isPublicChannel => kind == DestKind.channelFlood;
}

enum IncomingKind { text, meshPix, unknown }

class IncomingPacket {
  IncomingPacket({
    required this.kind,
    required this.fromChannel,
    this.channelIdx,
    this.senderPrefix,
    this.text,
    this.dataType,
    this.payload,
    this.flooded = false,
    this.snr,
    this.rssi,
    this.hopCount,
    this.timestamp,
    this.txtType = 0,
  });

  final IncomingKind kind;
  final bool fromChannel;
  final int? channelIdx;
  final Uint8List? senderPrefix;
  final String? text;
  final int? dataType;
  final Uint8List? payload;
  final bool flooded;
  final double? snr;
  final int? rssi;
  final int? hopCount;
  final int? timestamp;
  final int txtType;
}

abstract class PacketRadio {
  Stream<IncomingPacket> get incoming;
  Future<TxReceipt?> sendText({
    required RadioDestination destination,
    required String text,
  });
  Future<void> sendDatagram({
    required RadioDestination destination,
    required int dataType,
    required Uint8List payload,
  });
}
