import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../codec/limits.dart';
import '../codec/mp1.dart';
import '../companion/control.dart';
import 'protocol.dart';

class TransferEvent {
  TransferEvent(
    this.message, {
    this.image,
    this.transferId,
    this.outgoing = false,
    this.destination,
    this.fromChannel = false,
    this.channelIdx,
    this.senderPrefix,
    this.isText = false,
    this.chunkReceived,
    this.chunkTotal,
    this.hopCount,
    this.snr,
    this.timestamp,
    this.receipt,
  });
  final String message;
  final DecodedImage? image;
  final int? transferId;
  final bool outgoing;
  final RadioDestination? destination;
  final bool fromChannel;
  final int? channelIdx;
  final Uint8List? senderPrefix;
  final bool isText;
  final int? chunkReceived;
  final int? chunkTotal;
  final int? hopCount;
  final double? snr;
  final int? timestamp;
  final TxReceipt? receipt;
}

class _Offer {
  _Offer(this.encoded, this.destination);
  final EncodedTransfer encoded;
  final RadioDestination destination;
}

class _IncomingUpgrade {
  _IncomingUpgrade(int total, this.from)
    : total = total,
      parts = List<Uint8List?>.filled(total, null);
  final List<Uint8List?> parts;
  final int total;
  final RadioDestination from;
  bool get complete => parts.isNotEmpty && parts.every((p) => p != null);
}

/// Owns preview/chunk/pull/nack state. Public channels never get chunks.
class TransferEngine {
  TransferEngine({
    required this.radio,
    required this.codec,
    required this.budget,
    this.maxPayload = kMaxDatagramPayload,
  }) {
    _sub = radio.incoming.listen(_onIncoming);
  }

  final PacketRadio radio;
  final Mp1Codec codec;
  final AirtimeBudget budget;
  final int maxPayload;

  final _events = StreamController<TransferEvent>.broadcast();
  Stream<TransferEvent> get events => _events.stream;

  final _queue = <QueuedTx>[];
  bool _pumping = false;
  StreamSubscription<IncomingPacket>? _sub;

  final _offers = <int, _Offer>{};
  final _upgrades = <int, _IncomingUpgrade>{};

  Future<EncodedTransfer> sendImage({
    required EncodedTransfer encoded,
    required RadioDestination destination,
  }) async {
    if (destination.isPublicChannel) {
      final bytes = Uint8List.fromList(encoded.preview.bytes);
      if (bytes.length > 9) bytes[9] = 0;
      final strippedImage = DecodedImage(
        width: encoded.preview.image.width,
        height: encoded.preview.image.height,
        palette: encoded.preview.image.palette,
        indices: encoded.preview.image.indices,
        dithered: encoded.preview.image.dithered,
        upgradeChunks: 0,
      );
      final preview = PreviewPacket(
        transferId: encoded.transferId,
        bytes: bytes,
        image: strippedImage,
      );
      final previewOnly = EncodedTransfer(
        transferId: encoded.transferId,
        preview: preview,
        chunks: const [],
        upgradeBlob: Uint8List(0),
        stats: EncodeStats(
          previewBytes: bytes.length,
          previewWidth: encoded.stats.previewWidth,
          previewBpp: encoded.stats.previewBpp,
          chunkCount: 0,
          upgradeWidth: encoded.stats.previewWidth,
          encoding: encoded.stats.encoding,
        ),
      );
      _enqueue(
        QueuedTx(
          priority: TxPriority.preview,
          payload: previewOnly.preview.bytes,
          destination: destination,
        ),
      );
      _events.add(
        TransferEvent(
          previewOnly.stats.summaryDe,
          image: previewOnly.preview.image,
          transferId: previewOnly.transferId,
          outgoing: true,
          destination: destination,
        ),
      );
      return previewOnly;
    }

    _offers[encoded.transferId] = _Offer(encoded, destination);
    _enqueue(
      QueuedTx(
        priority: TxPriority.preview,
        payload: encoded.preview.bytes,
        destination: destination,
      ),
    );
    _events.add(
      TransferEvent(
        encoded.stats.summaryDe,
        image: encoded.preview.image,
        transferId: encoded.transferId,
        outgoing: true,
        destination: destination,
      ),
    );
    return encoded;
  }

  Future<TxReceipt?> sendText(RadioDestination destination, String text) {
    final done = Completer<TxReceipt?>();
    _enqueue(
      QueuedTx(
        priority: TxPriority.text,
        payload: Uint8List.fromList(utf8.encode(text)),
        destination: destination,
        done: done,
      ),
    );
    return done.future;
  }

  Future<void> requestUpgrade(int transferId, RadioDestination from) async {
    final pkt = codec.pull(transferId);
    _enqueue(
      QueuedTx(
        priority: TxPriority.control,
        payload: pkt.bytes,
        destination: from,
      ),
    );
  }

  Future<void> cancel(int transferId, RadioDestination dest) async {
    _offers.remove(transferId);
    _upgrades.remove(transferId);
    _enqueue(
      QueuedTx(
        priority: TxPriority.control,
        payload: codec.abort(transferId).bytes,
        destination: dest,
      ),
    );
  }

  void _enqueue(QueuedTx tx) {
    _queue.add(tx);
    _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        final next = _queue.removeAt(0);
        try {
          if (next.priority == TxPriority.text) {
            final receipt = await radio.sendText(
              destination: next.destination,
              text: utf8.decode(next.payload),
            );
            if (!(next.done?.isCompleted ?? true)) {
              next.done!.complete(receipt);
            }
          } else {
            if (next.payload.length > maxPayload) {
              continue;
            }
            await radio.sendDatagram(
              destination: next.destination,
              dataType: kMeshPixDataType,
              payload: next.payload,
            );
          }
        } catch (e) {
          if (!(next.done?.isCompleted ?? true)) {
            next.done!.completeError(e);
          }
          rethrow;
        }
        await Future<void>.delayed(budget.waitAfter(next.payload.length));
      }
    } catch (e) {
      for (final q in _queue) {
        if (!(q.done?.isCompleted ?? true)) {
          q.done!.completeError(e);
        }
      }
      rethrow;
    } finally {
      _pumping = false;
    }
  }

  void _onIncoming(IncomingPacket packet) {
    if (packet.kind == IncomingKind.text) {
      _events.add(
        TransferEvent(
          packet.text ?? '',
          outgoing: false,
          isText: true,
          fromChannel: packet.fromChannel,
          channelIdx: packet.channelIdx,
          senderPrefix: packet.senderPrefix,
          hopCount: packet.hopCount,
          snr: packet.snr,
          timestamp: packet.timestamp,
        ),
      );
      return;
    }
    if (packet.kind == IncomingKind.unknown) {
      return;
    }
    if (packet.dataType != null && packet.dataType != kMeshPixDataType) {
      return;
    }
    final payload = packet.payload;
    if (payload == null) return;
    late final Mp1Packet parsed;
    try {
      parsed = codec.parse(payload);
    } catch (_) {
      return;
    }
    final from = packet.fromChannel
        ? RadioDestination.channel(packet.channelIdx ?? 0)
        : RadioDestination.dm(packet.senderPrefix ?? Uint8List(6));
    switch (parsed) {
      case PreviewPacket p:
        if (p.image.upgradeChunks > 0 && !packet.fromChannel) {
          _upgrades[p.transferId] = _IncomingUpgrade(
            p.image.upgradeChunks,
            from,
          );
        }
        _events.add(
          TransferEvent(
            p.image.upgradeChunks > 0
                ? 'Bild-Preview (${p.image.width}×${p.image.height}), Nachzug möglich'
                : 'Bild-Preview (${p.image.width}×${p.image.height})',
            image: p.image,
            transferId: p.transferId,
            fromChannel: packet.fromChannel,
            channelIdx: packet.channelIdx,
            senderPrefix: packet.senderPrefix,
          ),
        );
      case PullPacket p:
        final offer = _offers[p.transferId];
        if (offer == null) return;
        if (offer.destination.isPublicChannel) return;
        for (final chunk in offer.encoded.chunks) {
          _enqueue(
            QueuedTx(
              priority: TxPriority.chunk,
              payload: chunk.bytes,
              destination: offer.destination,
            ),
          );
        }
      case ChunkPacket p:
        if (from.isPublicChannel) return;
        final up = _upgrades[p.transferId];
        if (up == null) return;
        if (p.seq < 0 || p.seq >= up.parts.length) return;
        final fresh = up.parts[p.seq] == null;
        up.parts[p.seq] = p.slice;
        if (fresh) {
          final received = up.parts.where((part) => part != null).length;
          _events.add(
            TransferEvent(
              'Nachzug: $received/${up.total} Pakete',
              transferId: p.transferId,
              fromChannel: packet.fromChannel,
              channelIdx: packet.channelIdx,
              senderPrefix: packet.senderPrefix,
              chunkReceived: received,
              chunkTotal: up.total,
            ),
          );
        }
        if (up.complete) {
          try {
            final blob = codec.reassembleChunks(up.parts);
            final image = codec.decodeUpgradeBlob(blob);
            _events.add(
              TransferEvent(
                'Bild vollständig (${image.width}×${image.height})',
                image: image,
                transferId: p.transferId,
                fromChannel: packet.fromChannel,
                channelIdx: packet.channelIdx,
                senderPrefix: packet.senderPrefix,
              ),
            );
            _upgrades.remove(p.transferId);
          } catch (_) {
            _nack(p.transferId, up);
          }
        }
      case NackPacket p:
        final offer = _offers[p.transferId];
        if (offer == null) return;
        for (final seq in seqsFromMask(p.missingMask, offer.encoded.chunks.length)) {
          if (seq < 0 || seq >= offer.encoded.chunks.length) continue;
          _enqueue(
            QueuedTx(
              priority: TxPriority.chunk,
              payload: offer.encoded.chunks[seq].bytes,
              destination: offer.destination,
            ),
          );
        }
      case AbortPacket p:
        _offers.remove(p.transferId);
        _upgrades.remove(p.transferId);
        _events.add(TransferEvent('Transfer ${p.transferId} abgebrochen'));
      case Mp1Packet():
        break;
    }
  }

  void nackMissing(int transferId) {
    final up = _upgrades[transferId];
    if (up == null) return;
    _nack(transferId, up);
  }

  void _nack(int transferId, _IncomingUpgrade up) {
    final mask = missingMaskFor(up.parts);
    if (mask == 0) return;
    _enqueue(
      QueuedTx(
        priority: TxPriority.control,
        payload: codec.nack(transferId, mask).bytes,
        destination: up.from,
      ),
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _events.close();
  }
}
