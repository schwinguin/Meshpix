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
    this.outPathEntrySize = 1,
    this.lastAdvert,
    this.lat,
    this.lon,
    this.alt,
    this.lastmod,
  });

  final List<int> publicKey;
  final String name;
  final int type;
  final int flags;
  final List<int>? outPath;
  /// Byte width of one out-path entry (1/2/4; MeshCore path-hash mode).
  final int outPathEntrySize;
  final int? lastAdvert;
  final double? lat;
  final double? lon;
  final double? alt;
  final int? lastmod;

  bool get hasPath => outPath != null && outPath!.isNotEmpty;
  int get hopCount {
    final p = outPath;
    if (p == null || p.isEmpty) return 0;
    return (p.length / outPathEntrySize).round();
  }
  bool get isFavourite => (flags & ContactFlags.favourite) != 0;
  bool get isMuted => (flags & ContactFlags.muted) != 0;
  bool get isChat => type == AdvType.chat || type == AdvType.none;
  bool get isAdminNode => type == AdvType.repeater || type == AdvType.room;
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
  /// Round-trip path for a trace ping: the known route out to this contact,
  /// then back along the reverse route (excluding the destination), so the
  /// final SNR lands at our own node and the node pushes TRACE_DATA to us.
  /// No known path (zero-hop neighbour) → direct 1-hop trace to the contact.
  List<int> buildPingPath() {
    final w = outPathEntrySize.clamp(1, 4);
    final out = outPath ?? const <int>[];
    if (out.isEmpty) {
      return publicKey.length >= w
          ? publicKey.sublist(0, w)
          : List<int>.of(publicKey);
    }
    final n = (out.length / w).floor();
    final path = List<int>.of(out);
    for (var e = n - 2; e >= 0; e--) {
      path.addAll(out.sublist(e * w, e * w + w));
    }
    return path;
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
    int? outPathEntrySize,
    int? lastAdvert,
    double? lat,
    double? lon,
    double? alt,
    int? lastmod,
  }) {
    return MeshContact(
      publicKey: publicKey,
      name: name ?? this.name,
      type: type ?? this.type,
      flags: flags ?? this.flags,
      outPath: outPath ?? this.outPath,
      outPathEntrySize: outPathEntrySize ?? this.outPathEntrySize,
      lastAdvert: lastAdvert ?? this.lastAdvert,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      alt: alt ?? this.alt,
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
    this.alt,
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
  final double? alt;
  final RadioSettings? radio;
  final bool manualAddContacts;

  String get keyHex =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
