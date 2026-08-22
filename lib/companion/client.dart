import 'dart:async';
import 'dart:typed_data';

import '../codec/limits.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/device.dart';
import '../transfer/protocol.dart';
import 'constants.dart';
import 'control.dart';
import 'frames.dart';
import 'parser.dart';

abstract class CompanionTransport {
  Stream<Uint8List> get frames;
  Future<void> write(Uint8List frame);
  Future<void> close();
}

/// Talks the MeshCore companion serial protocol over any transport.
class CompanionClient implements PacketRadio, CompanionControl {
  CompanionClient({
    required this.transport,
    this.meshPixDataType = kMeshPixDataType,
  }) {
    _sub = transport.frames.listen(_onFrame);
  }

  final CompanionTransport transport;
  final int meshPixDataType;

  @override
  DeviceSelf? self;
  @override
  final contacts = <MeshContact>[];
  @override
  final channels = <MeshChannel>[];
  @override
  RadioSettings? radio;
  @override
  BatteryInfo? battery;
  @override
  FirmwareInfo? firmware;

  final _incoming = StreamController<IncomingPacket>.broadcast();
  @override
  Stream<IncomingPacket> get incoming => _incoming.stream;

  final _notices = StreamController<CompanionNotice>.broadcast();
  @override
  Stream<CompanionNotice> get notices => _notices.stream;

  StreamSubscription<Uint8List>? _sub;
  Completer<ParsedFrame>? _awaiting;
  int? _awaitCode;
  int? _contactsSince;

  Future<void> handshake() async {
    final info = await _sendExpect(cmdDeviceQuery(), Resp.deviceInfo);
    firmware = info?.firmware ?? firmware;
    final selfFrame = await _sendExpect(cmdAppStart(), Resp.selfInfo);
    if (selfFrame?.self != null) {
      self = selfFrame!.self;
      radio = self!.radio;
    }
    await _send(cmdSetDeviceTime(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000));
    await refreshContacts();
    channels.clear();
    final maxCh = firmware?.maxChannels ?? 8;
    for (var i = 0; i < maxCh && i < 16; i++) {
      await _send(cmdGetChannel(i));
    }
    await refreshBattery();
    await syncMessages();
  }

  @override
  Future<void> refreshContacts() async {
    contacts.clear();
    await _send(cmdGetContacts(since: _contactsSince));
    await _drainUntil(Resp.contactsEnd);
  }

  Future<void> syncMessages() async {
    for (var i = 0; i < 32; i++) {
      await _send(cmdSyncNextMessage());
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Future<TxReceipt?> sendText({
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
      return const TxReceipt(flooded: true);
    }
    final frame = await _sendExpect(
      cmdSendTxtMsg(
        pubkeyPrefix: destination.pubkeyPrefix ?? Uint8List(6),
        text: text,
        timestamp: ts,
      ),
      Resp.msgSent,
    );
    return frame?.receipt ?? const TxReceipt();
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
      await _send(
        cmdSendRawData(
          payload: payload,
          path: destination.path,
        ),
      );
    }
  }

  @override
  Future<void> sendSelfAdvert({bool flood = false}) =>
      _send(cmdSendSelfAdvert(flood: flood));

  @override
  Future<void> setAdvertName(String name) async {
    await _send(cmdSetAdvertName(name));
    if (self != null) {
      self = DeviceSelf(
        name: name,
        publicKey: self!.publicKey,
        type: self!.type,
        txPower: self!.txPower,
        maxTxPower: self!.maxTxPower,
        lat: self!.lat,
        lon: self!.lon,
        alt: self!.alt,
        radio: self!.radio,
        manualAddContacts: self!.manualAddContacts,
      );
    }
  }

  @override
  Future<void> setChannel(int idx, String name, Uint8List secret) async {
    await _send(cmdSetChannel(idx, name, secret));
    channels.removeWhere((c) => c.index == idx);
    channels.add(
      MeshChannel(
        index: idx,
        name: name,
        secret: List<int>.of(secret),
      ),
    );
  }

  @override
  Future<void> applyRadio(RadioSettings settings) async {
    await _send(cmdSetRadioParams(settings));
    if (settings.txPowerDbm != null) {
      await _send(cmdSetRadioTxPower(settings.txPowerDbm!));
    }
    radio = settings;
  }

  @override
  Future<BatteryInfo?> refreshBattery() async {
    final frame = await _sendExpect(cmdGetBattAndStorage(), Resp.battAndStorage);
    battery = frame?.battery ?? battery;
    return battery;
  }

  @override
  Future<void> setFavourite(MeshContact contact, bool favourite) async {
    final flags = favourite
        ? (contact.flags | ContactFlags.favourite)
        : (contact.flags & ~ContactFlags.favourite);
    final updated = contact.copyWith(flags: flags);
    await addOrUpdateContact(updated);
  }

  @override
  Future<void> addOrUpdateContact(MeshContact contact) async {
    await _send(cmdAddUpdateContact(contact));
    contacts.removeWhere(_sameKey(contact.publicKey));
    contacts.add(contact);
  }

  @override
  Future<void> removeContact(MeshContact contact) async {
    await _send(cmdRemoveContact(contact.publicKey));
    contacts.removeWhere(_sameKey(contact.publicKey));
  }

  @override
  Future<void> ping(MeshContact contact) => requestStatus(contact);

  @override
  Future<void> requestStatus(MeshContact contact) =>
      _send(cmdSendStatusReq(contact.publicKey));

  @override
  Future<void> requestTelemetry(MeshContact contact) =>
      _send(cmdSendTelemetryReq(contact.publicKey));

  @override
  Future<void> loginRepeater(MeshContact contact, String password) =>
      _send(cmdSendLogin(publicKey: contact.publicKey, password: password));

  @override
  Future<void> logoutRepeater(MeshContact contact) =>
      sendCli(contact, 'logout');

  @override
  Future<void> sendCli(MeshContact contact, String command) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _send(
      cmdSendTxtMsg(
        pubkeyPrefix: Uint8List.fromList(contact.publicKey.take(6).toList()),
        text: command,
        timestamp: ts,
        txtType: TxtType.cli,
      ),
    );
  }

  @override
  Future<void> tracePath(MeshContact contact) async {
    await _send(
      cmdSendTracePath(
        path: contact.outPath ?? const [],
        tag: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
      ),
    );
  }

  @override
  Future<void> shareContactZeroHop(MeshContact contact) =>
      _send(cmdShareContact(contact.publicKey));

  @override
  Future<void> resetPath(MeshContact contact) async {
    await _send(cmdResetPath(contact.publicKey));
    final idx = contacts.indexWhere(_sameKey(contact.publicKey));
    if (idx >= 0) {
      contacts[idx] = contacts[idx].copyWith(outPath: Uint8List(0));
    }
  }

  bool Function(MeshContact) _sameKey(List<int> key) => (c) {
        if (c.publicKey.length != key.length) return false;
        for (var i = 0; i < key.length; i++) {
          if (c.publicKey[i] != key[i]) return false;
        }
        return true;
      };

  Future<void> _send(Uint8List frame) => transport.write(frame);

  Future<ParsedFrame?> _sendExpect(Uint8List frame, int code) async {
    _awaiting = Completer<ParsedFrame>();
    _awaitCode = code;
    await _send(frame);
    final result = await _awaiting!.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => ParsedFrame(code),
    );
    _awaiting = null;
    _awaitCode = null;
    return result;
  }

  Future<void> _drainUntil(int code) async {
    _awaiting = Completer<ParsedFrame>();
    _awaitCode = code;
    await _awaiting!.future.timeout(const Duration(seconds: 3), onTimeout: () {
      return ParsedFrame(code);
    });
    _awaiting = null;
    _awaitCode = null;
  }

  void _upsertContact(MeshContact contact) {
    contacts.removeWhere(_sameKey(contact.publicKey));
    contacts.add(contact);
    if (contact.lastmod != null) {
      final prev = _contactsSince ?? 0;
      if (contact.lastmod! > prev) _contactsSince = contact.lastmod;
    }
  }

  void _onFrame(Uint8List frame) {
    final parsed = parseCompanionFrame(frame, meshPixDataType: meshPixDataType);
    if (parsed == null) return;
    if (parsed.self != null) {
      self = parsed.self;
      radio = parsed.self!.radio ?? radio;
    }
    if (parsed.firmware != null) firmware = parsed.firmware;
    if (parsed.battery != null) battery = parsed.battery;
    if (parsed.contact != null) {
      _upsertContact(parsed.contact!);
      if (parsed.code == Resp.newAdvert) {
        _notices.add(CompanionNotice.advert(parsed.contact));
      }
    }
    if (parsed.channel != null) {
      channels.removeWhere((c) => c.index == parsed.channel!.index);
      channels.add(parsed.channel!);
    }
    if (parsed.incoming != null) {
      _incoming.add(parsed.incoming!);
      final incoming = parsed.incoming!;
      if (incoming.txtType == TxtType.cli && incoming.text != null) {
        _notices.add(
          CompanionNotice.cli(
            prefix: incoming.senderPrefix ?? const [],
            cliText: incoming.text!,
          ),
        );
      }
    }
    if (parsed.ackCode != null) {
      _notices.add(CompanionNotice.ack(ackCode: parsed.ackCode!, rttMs: parsed.rttMs ?? 0));
    }
    if (parsed.loginOk != null) {
      _notices.add(
        CompanionNotice.login(
          prefix: parsed.advertKey ?? const [],
          ok: parsed.loginOk!,
          isAdmin: parsed.isAdmin,
          permissions: parsed.permissions,
        ),
      );
    }
    if (parsed.statusSummary != null) {
      _notices.add(
        CompanionNotice.status(
          prefix: parsed.advertKey ?? const [],
          statusSummary: parsed.statusSummary!,
          repeaterStatus: parsed.repeaterStatus,
        ),
      );
    }
    if (parsed.traceSummary != null) {
      _notices.add(
        CompanionNotice.trace(
          traceSummary: parsed.traceSummary,
          prefix: parsed.advertKey,
        ),
      );
    }
    if (parsed.advertKey != null &&
        (parsed.code == Resp.advert || parsed.code == Resp.pathUpdated)) {
      unawaited(refreshContacts());
      if (parsed.code == Resp.pathUpdated) {
        _notices.add(CompanionNotice.pathUpdated(parsed.advertKey!));
      }
    }
    if (parsed.code == Resp.msgWaiting) {
      unawaited(syncMessages());
    }
    if (_awaitCode != null && parsed.code == _awaitCode && !(_awaiting?.isCompleted ?? true)) {
      _awaiting!.complete(parsed);
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _incoming.close();
    await _notices.close();
    await transport.close();
  }
}
