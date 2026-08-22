import 'device.dart';

class AdvType {
  static const none = 0;
  static const chat = 1;
  static const repeater = 2;
  static const room = 3;
  static const sensor = 4;

  static String label(int type) {
    switch (type) {
      case chat:
        return 'Chat';
      case repeater:
        return 'Repeater';
      case room:
        return 'Room';
      case sensor:
        return 'Sensor';
      default:
        return 'Node';
    }
  }
}

class ContactFlags {
  static const favourite = 0x01;
  static const muted = 0x02;
}

class MeshContact {
  MeshContact({
    required this.publicKey,
    required this.name,
    this.type = AdvType.chat,
    this.flags = 0,
    this.outPath,
    this.lastAdvert,
    this.lat,
    this.lon,
    this.lastmod,
  });

  final List<int> publicKey;
  final String name;
  final int type;
  final int flags;
  final List<int>? outPath;
  final int? lastAdvert;
  final double? lat;
  final double? lon;
  final int? lastmod;

  bool get hasPath => outPath != null && outPath!.isNotEmpty;
  int get hopCount => outPath?.length ?? 0;
  bool get isFavourite => (flags & ContactFlags.favourite) != 0;
  bool get isMuted => (flags & ContactFlags.muted) != 0;
  bool get isChat => type == AdvType.chat || type == AdvType.none;
  bool get hasLocation => lat != null && lon != null && (lat != 0 || lon != 0);

  String get keyHex =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String get shortKey {
    if (publicKey.length < 4) return keyHex;
    final a = publicKey
        .take(3)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return a;
  }

  DateTime? get lastHeard {
    if (lastAdvert == null || lastAdvert == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(lastAdvert! * 1000, isUtc: true)
        .toLocal();
  }

  MeshContact copyWith({
    String? name,
    int? type,
    int? flags,
    List<int>? outPath,
    int? lastAdvert,
    double? lat,
    double? lon,
    int? lastmod,
  }) {
    return MeshContact(
      publicKey: publicKey,
      name: name ?? this.name,
      type: type ?? this.type,
      flags: flags ?? this.flags,
      outPath: outPath ?? this.outPath,
      lastAdvert: lastAdvert ?? this.lastAdvert,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      lastmod: lastmod ?? this.lastmod,
    );
  }
}

class DeviceSelf {
  DeviceSelf({
    required this.name,
    required this.publicKey,
    this.type = AdvType.chat,
    this.txPower,
    this.maxTxPower,
    this.lat,
    this.lon,
    this.radio,
    this.manualAddContacts = false,
  });

  final String name;
  final List<int> publicKey;
  final int type;
  final int? txPower;
  final int? maxTxPower;
  final double? lat;
  final double? lon;
  final RadioSettings? radio;
  final bool manualAddContacts;

  String get keyHex =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
