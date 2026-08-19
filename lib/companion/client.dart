import 'dart:async';
import 'dart:typed_data';

import '../codec/limits.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../transfer/protocol.dart';
import 'constants.dart';
import 'frames.dart';
import 'parser.dart';

abstract class CompanionTransport {
  Stream<Uint8List> get frames;
  Future<void> write(Uint8List frame);
  Future<void> close();
}

/// Talks the MeshCore companion serial protocol over any transport.
class CompanionClient implements PacketRadio {
  CompanionClient({
    required this.transport,
    this.meshPixDataType = kMeshPixDataType,
  }) {
    _sub = transport.frames.listen(_onFrame);
  }

  final CompanionTransport transport;
  final int meshPixDataType;

  DeviceSelf? self;
  final contacts = <MeshContact>[];
  final channels = <MeshChannel>[];

  final _incoming = StreamController<IncomingPacket>.broadcast();
  @override
  Stream<IncomingPacket> get incoming => _incoming.stream;

  StreamSubscription<Uint8List>? _sub;
  Completer<void>? _awaiting;
  int? _awaitCode;

  Future<void> handshake() async {
    await _sendExpect(cmdDeviceQuery(), Resp.deviceInfo);
    await _sendExpect(cmdAppStart(), Resp.selfInfo);
    contacts.clear();
    await _send(cmdGetContacts());
    await _drainUntil(Resp.contactsEnd);
    channels.clear();
    for (var i = 0; i < 8; i++) {
      await _send(cmdGetChannel(i));
    }
    await syncMessages();
  }

  Future<void> syncMessages() async {
    for (var i = 0; i < 32; i++) {
      await _send(cmdSyncNextMessage());
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Future<void> sendText({
    required RadioDestination destination,
    required String text,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (destination.isPublicChannel) {
      await _send(
        cmdSendChannelTxtMsg(
          channelIdx: destination.channelIdx ?? 0,
          text: text,
          timestamp: ts,
        ),
      );
    } else {
      await _send(
        cmdSendTxtMsg(
          pubkeyPrefix: destination.pubkeyPrefix ?? Uint8List(6),
          text: text,
          timestamp: ts,
        ),
      );
    }
  }

  @override
  Future<void> sendDatagram({
    required RadioDestination destination,
    required int dataType,
    required Uint8List payload,
  }) async {
    if (destination.isPublicChannel) {
      await _send(
        cmdSendChannelData(
          channelIdx: destination.channelIdx ?? 0,
          dataType: dataType,
          payload: payload,
        ),
      );
    } else {
      // RAW_CUSTOM has no data_type field; MeshPix magic lives in the payload.
      await _send(
        cmdSendRawData(
          payload: payload,
          path: destination.path,
        ),
      );
    }
  }

  Future<void> _send(Uint8List frame) => transport.write(frame);

  Future<void> _sendExpect(Uint8List frame, int code) async {
    _awaiting = Completer<void>();
    _awaitCode = code;
    await _send(frame);
    await _awaiting!.future.timeout(const Duration(seconds: 3), onTimeout: () {
      if (!(_awaiting?.isCompleted ?? true)) {
        _awaiting!.complete();
      }
    });
    _awaiting = null;
    _awaitCode = null;
  }

  Future<void> _drainUntil(int code) async {
    _awaiting = Completer<void>();
    _awaitCode = code;
    await _awaiting!.future.timeout(const Duration(seconds: 3), onTimeout: () {
      if (!(_awaiting?.isCompleted ?? true)) {
        _awaiting!.complete();
      }
    });
    _awaiting = null;
    _awaitCode = null;
  }

  void _onFrame(Uint8List frame) {
    final parsed = parseCompanionFrame(frame, meshPixDataType: meshPixDataType);
    if (parsed == null) return;
    if (parsed.self != null) self = parsed.self;
    if (parsed.contact != null) contacts.add(parsed.contact!);
    if (parsed.channel != null) {
      channels.removeWhere((c) => c.index == parsed.channel!.index);
      channels.add(parsed.channel!);
    }
    if (parsed.incoming != null) {
      _incoming.add(parsed.incoming!);
    }
    if (parsed.code == Resp.msgWaiting) {
      unawaited(syncMessages());
    }
    if (_awaitCode != null && parsed.code == _awaitCode && !(_awaiting?.isCompleted ?? true)) {
      _awaiting!.complete();
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _incoming.close();
    await transport.close();
  }
}
