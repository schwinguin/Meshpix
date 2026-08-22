/// Radio parameters as stored on a MeshCore companion.
class RadioSettings {
  const RadioSettings({
    required this.freqMhz,
    required this.bwKhz,
    required this.spreadingFactor,
    required this.codingRate,
    this.txPowerDbm,
    this.maxTxPowerDbm,
    this.repeatMode = false,
  });

  final double freqMhz;
  final double bwKhz;
  final int spreadingFactor;
  final int codingRate;
  final int? txPowerDbm;
  final int? maxTxPowerDbm;
  final bool repeatMode;

  int get freqWire => (freqMhz * 1000).round();
  int get bwWire => (bwKhz * 1000).round();

  RadioSettings copyWith({
    double? freqMhz,
    double? bwKhz,
    int? spreadingFactor,
    int? codingRate,
    int? txPowerDbm,
    int? maxTxPowerDbm,
    bool? repeatMode,
  }) {
    return RadioSettings(
      freqMhz: freqMhz ?? this.freqMhz,
      bwKhz: bwKhz ?? this.bwKhz,
      spreadingFactor: spreadingFactor ?? this.spreadingFactor,
      codingRate: codingRate ?? this.codingRate,
      txPowerDbm: txPowerDbm ?? this.txPowerDbm,
      maxTxPowerDbm: maxTxPowerDbm ?? this.maxTxPowerDbm,
      repeatMode: repeatMode ?? this.repeatMode,
    );
  }

  String get summary =>
      '${freqMhz.toStringAsFixed(3)} MHz · SF$spreadingFactor · ${bwKhz.toStringAsFixed(1)} kHz · CR$codingRate'
      '${txPowerDbm != null ? ' · ${txPowerDbm}dBm' : ''}';
}

class RadioPreset {
  const RadioPreset({
    required this.id,
    required this.label,
    required this.settings,
  });

  final String id;
  final String label;
  final RadioSettings settings;

  /// Common MeshCore regional starting points (same values as MeshCore One).
  static const all = <RadioPreset>[
    RadioPreset(
      id: 'eu868',
      label: 'EU 868 (Standard)',
      settings: RadioSettings(
        freqMhz: 869.525,
        bwKhz: 250,
        spreadingFactor: 11,
        codingRate: 5,
        txPowerDbm: 22,
      ),
    ),
    RadioPreset(
      id: 'us915',
      label: 'US/CA 915 (Standard)',
      settings: RadioSettings(
        freqMhz: 910.525,
        bwKhz: 62.5,
        spreadingFactor: 7,
        codingRate: 5,
        txPowerDbm: 22,
      ),
    ),
    RadioPreset(
      id: 'au915',
      label: 'AU 915',
      settings: RadioSettings(
        freqMhz: 917.3,
        bwKhz: 62.5,
        spreadingFactor: 8,
        codingRate: 5,
        txPowerDbm: 22,
      ),
    ),
    RadioPreset(
      id: 'uk868',
      label: 'UK 868',
      settings: RadioSettings(
        freqMhz: 869.618,
        bwKhz: 250,
        spreadingFactor: 11,
        codingRate: 5,
        txPowerDbm: 16,
      ),
    ),
  ];
}

class BatteryInfo {
  const BatteryInfo({
    required this.milliVolts,
    this.usedKb,
    this.totalKb,
  });

  final int milliVolts;
  final int? usedKb;
  final int? totalKb;

  double get volts => milliVolts / 1000.0;

  /// Rough Li-ion open-circuit estimate, 3.3–4.2 V.
  int get percent {
    final p = ((milliVolts - 3300) / 9).round();
    if (p < 0) return 0;
    if (p > 100) return 100;
    return p;
  }

  String get label => '${volts.toStringAsFixed(2)} V · $percent %';
}

class FirmwareInfo {
  const FirmwareInfo({
    this.firmwareVer,
    this.buildDate,
    this.model,
    this.semanticVersion,
    this.maxContacts,
    this.maxChannels,
  });

  final int? firmwareVer;
  final String? buildDate;
  final String? model;
  final String? semanticVersion;
  final int? maxContacts;
  final int? maxChannels;

  String get label {
    final ver = semanticVersion?.isNotEmpty == true
        ? semanticVersion!
        : (firmwareVer != null ? 'v$firmwareVer' : 'unbekannt');
    final extra = [
      if (model != null && model!.isNotEmpty) model,
      if (buildDate != null && buildDate!.isNotEmpty) buildDate,
    ].join(' · ');
    return extra.isEmpty ? ver : '$ver · $extra';
  }
}
