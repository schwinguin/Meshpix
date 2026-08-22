import 'contact.dart';

enum CliLineKind { sent, reply, error, info }

class CliLine {
  CliLine({required this.kind, required this.text, DateTime? at})
      : at = at ?? DateTime.now();

  final CliLineKind kind;
  final String text;
  final DateTime at;
}

class RepeaterNeighbor {
  RepeaterNeighbor({
    required this.prefixHex,
    this.heard,
    this.snr,
  });

  final String prefixHex;
  final DateTime? heard;
  final double? snr;

  String get label {
    final bits = <String>[prefixHex];
    if (snr != null) bits.add('${snr!.toStringAsFixed(1)} dB');
    return bits.join(' · ');
  }
}

class RepeaterStatus {
  const RepeaterStatus({
    this.milliVolts,
    this.queueLen,
    this.noiseFloor,
    this.lastRssi,
    this.packetsRecv,
    this.packetsSent,
    this.airtimeSecs,
    this.uptimeSecs,
    this.sentFlood,
    this.sentDirect,
    this.recvFlood,
    this.recvDirect,
    this.lastSnr,
    this.rawSummary,
  });

  final int? milliVolts;
  final int? queueLen;
  final int? noiseFloor;
  final int? lastRssi;
  final int? packetsRecv;
  final int? packetsSent;
  final int? airtimeSecs;
  final int? uptimeSecs;
  final int? sentFlood;
  final int? sentDirect;
  final int? recvFlood;
  final int? recvDirect;
  final double? lastSnr;
  final String? rawSummary;

  double? get volts => milliVolts == null ? null : milliVolts! / 1000.0;

  String get uptimeLabel {
    final s = uptimeSecs;
    if (s == null) return '—';
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s % 60}s';
    return '${s}s';
  }

  String get summary {
    if (rawSummary != null && rawSummary!.isNotEmpty) return rawSummary!;
    final parts = <String>[
      if (volts != null) '${volts!.toStringAsFixed(2)} V',
      if (uptimeSecs != null) 'Up $uptimeLabel',
      if (lastSnr != null) 'SNR ${lastSnr!.toStringAsFixed(1)} dB',
      if (packetsRecv != null) 'RX $packetsRecv',
    ];
    return parts.isEmpty ? 'Status empfangen' : parts.join(' · ');
  }
}

class RepeaterSession {
  RepeaterSession(this.contact);

  MeshContact contact;
  bool loggedIn = false;
  bool isAdmin = false;
  int permissions = 0;
  RepeaterStatus? status;
  final transcript = <CliLine>[];
  final neighbors = <RepeaterNeighbor>[];
  bool busy = false;
  String? lastError;
  String? lastCommand;

  String get roleLabel {
    if (!loggedIn) return 'nicht angemeldet';
    if (isAdmin || permissions >= 3) return 'Admin';
    if (permissions == 2) return 'Read/Write';
    if (permissions == 1) return 'Gast';
    return 'angemeldet';
  }
}

/// Neighbors CLI lines: `{prefix-hex}:{epoch}:{snr*4}`
List<RepeaterNeighbor> parseNeighborsReply(String text) {
  final out = <RepeaterNeighbor>[];
  for (final raw in text.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) continue;
    final hex = parts[0].toLowerCase();
    if (!RegExp(r'^[0-9a-f]{2,64}$').hasMatch(hex)) continue;
    final epoch = int.tryParse(parts[1]);
    double? snr;
    if (parts.length > 2) {
      final rawSnr = int.tryParse(parts[2]);
      if (rawSnr != null) snr = rawSnr / 4.0;
    }
    out.add(
      RepeaterNeighbor(
        prefixHex: hex,
        heard: epoch == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true).toLocal(),
        snr: snr,
      ),
    );
  }
  return out;
}

bool isDangerCli(String command) {
  return RegExp(r'\b(reboot|erase|clkreboot|factory)\b(?!\.)', caseSensitive: false)
      .hasMatch(command.trim());
}

const repeaterQuickActions = <String>[
  'ver',
  'board',
  'clock',
  'clock sync',
  'get name',
  'get radio',
  'get tx',
  'neighbors',
  'advert',
  'advert.zerohop',
  'reboot',
];
