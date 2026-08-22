import '../models/contact.dart';
import '../models/channel.dart';
import '../models/device.dart';

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
  CompanionNotice.advert(this.contact)
      : kind = CompanionNoticeKind.advert,
        ackCode = null,
        rttMs = null,
        statusSummary = null,
        pubkey = contact?.publicKey;

  CompanionNotice.ack({required int this.ackCode, required int this.rttMs})
      : kind = CompanionNoticeKind.ack,
        contact = null,
        statusSummary = null,
        pubkey = null;

  CompanionNotice.status({
    required List<int> prefix,
    required this.statusSummary,
  })  : kind = CompanionNoticeKind.status,
        contact = null,
        ackCode = null,
        rttMs = null,
        pubkey = prefix;

  CompanionNotice.pathUpdated(this.pubkey)
      : kind = CompanionNoticeKind.pathUpdated,
        contact = null,
        ackCode = null,
        rttMs = null,
        statusSummary = null;

  final CompanionNoticeKind kind;
  final MeshContact? contact;
  final int? ackCode;
  final int? rttMs;
  final String? statusSummary;
  final List<int>? pubkey;
}

enum CompanionNoticeKind { advert, ack, status, pathUpdated }

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
}
