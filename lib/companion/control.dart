import 'dart:typed_data';

import '../models/channel.dart';
import '../models/contact.dart';
import '../models/device.dart';
import '../models/signal.dart';
import '../models/repeater.dart';

class TxReceipt {
  const TxReceipt({
    this.expectedAck,
    this.flooded = false,
    this.timeoutMs,
  });

  final int? expectedAck;
  final bool flooded;
  final int? timeoutMs;
}

class CompanionNotice {
  CompanionNotice({
    required this.kind,
    this.contact,
    this.ackCode,
    this.rttMs,
    this.statusSummary,
    this.pubkey,
    this.loginOk,
    this.isAdmin,
    this.permissions,
    this.cliText,
    this.repeaterStatus,
    this.trace,
  });

  CompanionNotice.advert(this.contact)
      : kind = CompanionNoticeKind.advert,
        ackCode = null,
        rttMs = null,
        statusSummary = null,
        pubkey = contact?.publicKey,
        loginOk = null,
        isAdmin = null,
        permissions = null,
        cliText = null,
        repeaterStatus = null,
        trace = null;

  CompanionNotice.ack({required int this.ackCode, required int this.rttMs})
      : kind = CompanionNoticeKind.ack,
        contact = null,
        statusSummary = null,
        pubkey = null,
        loginOk = null,
        isAdmin = null,
        permissions = null,
        cliText = null,
        repeaterStatus = null,
        trace = null;

  CompanionNotice.status({
    required List<int> prefix,
    required this.statusSummary,
    this.repeaterStatus,
    this.rttMs,
  })  : kind = CompanionNoticeKind.status,
        contact = null,
        ackCode = null,
        pubkey = prefix,
        loginOk = null,
        isAdmin = null,
        permissions = null,
        cliText = null,
        trace = null;

  CompanionNotice.pathUpdated(this.pubkey)
      : kind = CompanionNoticeKind.pathUpdated,
        contact = null,
        ackCode = null,
        rttMs = null,
        statusSummary = null,
        loginOk = null,
        isAdmin = null,
        permissions = null,
        cliText = null,
        repeaterStatus = null,
        trace = null;

  CompanionNotice.login({
    required List<int> prefix,
    required bool ok,
    this.isAdmin,
    this.permissions,
  })  : kind = ok ? CompanionNoticeKind.login : CompanionNoticeKind.loginFail,
        contact = null,
        ackCode = null,
        rttMs = null,
        statusSummary = null,
        pubkey = prefix,
        loginOk = null,
        cliText = null,
        repeaterStatus = null,
        trace = null;

  CompanionNotice.cli({required List<int> prefix, required this.cliText})
      : kind = CompanionNoticeKind.cli,
        contact = null,
        ackCode = null,
        rttMs = null,
        statusSummary = null,
        pubkey = prefix,
        loginOk = null,
        isAdmin = null,
        permissions = null,
        repeaterStatus = null,
        trace = null;

  CompanionNotice.trace({required this.trace, List<int>? prefix})
      : kind = CompanionNoticeKind.trace,
        contact = null,
        ackCode = null,
        rttMs = null,
        statusSummary = null,
        pubkey = prefix,
        loginOk = null,
        isAdmin = null,
        permissions = null,
        cliText = null,
        repeaterStatus = null;

  final CompanionNoticeKind kind;
  final MeshContact? contact;
  final int? ackCode;
  final int? rttMs;
  final String? statusSummary;
  final List<int>? pubkey;
  final bool? loginOk;
  final bool? isAdmin;
  final int? permissions;
  final String? cliText;
  final RepeaterStatus? repeaterStatus;
  final TraceResult? trace;
}

enum CompanionNoticeKind {
  advert,
  ack,
  status,
  pathUpdated,
  login,
  loginFail,
  cli,
  trace,
}

/// Extra MeshCore-One-style actions on top of [PacketRadio].
abstract class CompanionControl {
  DeviceSelf? get self;
  List<MeshContact> get contacts;
  List<MeshChannel> get channels;
  RadioSettings? get radio;
  BatteryInfo? get battery;
  FirmwareInfo? get firmware;
  Stream<CompanionNotice> get notices;

  Future<void> sendSelfAdvert({bool flood = false});
  Future<void> setAdvertName(String name);
  Future<void> applyRadio(RadioSettings settings);
  Future<BatteryInfo?> refreshBattery();
  Future<void> setFavourite(MeshContact contact, bool favourite);
  Future<void> removeContact(MeshContact contact);
  Future<void> addOrUpdateContact(MeshContact contact);
  Future<void> ping(MeshContact contact);
  Future<void> shareContactZeroHop(MeshContact contact);
  Future<void> resetPath(MeshContact contact);
  Future<void> refreshContacts();
  Future<void> loginRepeater(MeshContact contact, String password);
  Future<void> logoutRepeater(MeshContact contact);
  Future<void> sendCli(MeshContact contact, String command);
  Future<void> requestStatus(MeshContact contact);
  Future<void> requestTelemetry(MeshContact contact);
  Future<void> tracePath(MeshContact contact, {int? tag, int? flags});
  Future<void> setChannel(int idx, String name, Uint8List secret);
  /// Kanal löschen: `setChannel(idx, "", 0…0)` — leeres Name + Null-Secret
  /// verwandelt den Slot in einen leeren "dead" Slot.
  Future<void> deleteChannel(int idx);
  /// `[0x33, "reset"]` — das Gerät startet neu, ohne OK-Frame.
  Future<void> factoryReset();
}