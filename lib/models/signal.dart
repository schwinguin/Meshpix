import 'contact.dart';

/// Ergebnis eines Trace-Pings (PUSH_CODE_TRACE_DATA, 0x89).
///
/// Layout: `[0x89, 0, path_len, flags, tag(4), auth(4), hashes(path_len),
/// snrs(path_len >> (flags&3)), final_snr]`.
/// SNR-Werte sind int8 in Viertel-dB-Schritten (SNR*4).
class TraceResult {
  TraceResult({
    required this.tag,
    required this.flags,
    required this.hashes,
    required this.snrs,
    this.finalSnr,
  });

  final int tag;
  final int flags;
  final List<int> hashes;
  final List<int> snrs;
  /// SNR, mit dem das lokale Gerät die letzte Re-Transmit gehört hat.
  final int? finalSnr;

  int get entrySize => 1 << (flags & 0x03);
  int get hopCount => hashes.isEmpty ? 0 : (hashes.length / entrySize).round();

  static double? _snrDb(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final v = bytes
        .map((b) => b >= 128 ? b - 256 : b)
        .reduce((a, b) => a < b ? a : b);
    return v / 4;
  }

  /// Schlechteste Verbindung aller traversierten Hops, in dB.
  double? get worstSnrDb => _snrDb([...snrs, ?finalSnr]);

  /// Empfangsqualität des letzten Hops bei uns, in dB.
  double? get finalSnrDb => finalSnr == null ? null : (finalSnr! >= 128
      ? finalSnr! - 256
      : finalSnr!) / 4;

  String get summary {
    final parts = <String>['Trace · $hopCount Hop${hopCount == 1 ? '' : 's'}'];
    final snr = finalSnrDb ?? worstSnrDb;
    if (snr != null) parts.add('${snr.toStringAsFixed(1)} dB');
    return parts.join(' · ');
  }
}

class PingResult {
  PingResult({
    required this.keyHex,
    required this.name,
    required this.type,
    required this.at,
    this.inFlight = false,
    this.ok = false,
    this.rttMs,
    this.snr,
    this.noiseFloor,
    this.rssi,
    this.hops,
  });

  final String keyHex;
  final String name;
  final int type;
  final DateTime at;
  final bool inFlight;
  final bool ok;
  final int? rttMs;
  final double? snr;
  final int? noiseFloor;
  final int? rssi;
  final int? hops;

  PingResult copyWith({
    bool? inFlight,
    bool? ok,
    int? rttMs,
    double? snr,
    int? noiseFloor,
    int? rssi,
    int? hops,
    DateTime? at,
  }) {
    return PingResult(
      keyHex: keyHex,
      name: name,
      type: type,
      at: at ?? this.at,
      inFlight: inFlight ?? this.inFlight,
      ok: ok ?? this.ok,
      rttMs: rttMs ?? this.rttMs,
      snr: snr ?? this.snr,
      noiseFloor: noiseFloor ?? this.noiseFloor,
      rssi: rssi ?? this.rssi,
      hops: hops ?? this.hops,
    );
  }

  String get rttLabel {
    if (inFlight) return 'klopft …';
    if (!ok) return 'keine Antwort';
    if (rttMs == null) return 'ok';
    return '$rttMs ms';
  }

  String get qualityLabel {
    if (inFlight) return 'warte auf Echo';
    if (!ok) return 'offline oder zu weit';
    final r = rttMs ?? 9999;
    if (r < 80) return 'schnell — nah oder direkt';
    if (r < 200) return 'gut';
    if (r < 500) return 'weit / mehrere Hops';
    return 'langsam';
  }
}

class NoiseSample {
  const NoiseSample({
    required this.dbm,
    required this.at,
    this.sourceName,
  });

  final int dbm;
  final DateTime at;
  final String? sourceName;
}

String noiseQuality(int dbm) {
  if (dbm <= -110) return 'Sehr leise';
  if (dbm <= -100) return 'Leise';
  if (dbm <= -92) return 'Normal';
  if (dbm <= -85) return 'Laut';
  return 'Sehr laut';
}

String noiseHint(int dbm) {
  if (dbm <= -110) {
    return 'Wenig Störer — guter Empfang, mehr Reichweite.';
  }
  if (dbm <= -100) {
    return 'Ruhige Umgebung. Typisch für ländliches LoRa.';
  }
  if (dbm <= -92) {
    return 'Alltagswert. SNR entscheidet, ob Pakete noch lesbar sind.';
  }
  if (dbm <= -85) {
    return 'Stadt / Elektronik in der Nähe. Schwache Signale gehen unter.';
  }
  return 'Sehr unruhig. Antenne, Netzteil oder Nachbar-WLAN prüfen.';
}

String defaultAglLabel(int type) {
  switch (type) {
    case AdvType.repeater:
      return 'Mast ~12 m';
    case AdvType.room:
      return 'Gebäude ~8 m';
    default:
      return 'Handgerät ~2 m';
  }
}

double defaultAgl(int type) {
  switch (type) {
    case AdvType.repeater:
      return 12;
    case AdvType.room:
      return 8;
    default:
      return 2;
  }
}
