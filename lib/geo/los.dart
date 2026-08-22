import 'dart:math';

import 'geo.dart';

enum LosVerdict { clear, marginal, blocked, noFix }

class LosSample {
  const LosSample({
    required this.distM,
    required this.terrainM,
    required this.bulgeM,
    required this.losM,
    required this.fresnelM,
    required this.clearanceM,
  });

  final double distM;
  final double terrainM;
  final double bulgeM;
  final double losM;
  final double fresnelM;
  final double clearanceM;

  double get obstacleM => terrainM + bulgeM;
}

class LosResult {
  const LosResult({
    required this.from,
    required this.to,
    required this.fromName,
    required this.toName,
    required this.distanceM,
    required this.bearing,
    required this.freqMhz,
    required this.fsplDb,
    required this.verdict,
    required this.samples,
    required this.worstClearanceM,
    required this.minFresnelClearPct,
  });

  final GeoPoint from;
  final GeoPoint to;
  final String fromName;
  final String toName;
  final double distanceM;
  final double bearing;
  final double freqMhz;
  final double fsplDb;
  final LosVerdict verdict;
  final List<LosSample> samples;
  final double worstClearanceM;
  final double minFresnelClearPct;

  bool get hasProfile => samples.isNotEmpty;

  String get verdictLabel {
    switch (verdict) {
      case LosVerdict.clear:
        return 'Freie Sicht';
      case LosVerdict.marginal:
        return 'Knapp — Fresnel berührt';
      case LosVerdict.blocked:
        return 'Verdeckt';
      case LosVerdict.noFix:
        return 'Keine Position';
    }
  }

  String get verdictHint {
    switch (verdict) {
      case LosVerdict.clear:
        return 'Gelände und Erdkugel bleiben unter der Funkstrecke. 60 % der ersten Fresnelzone sind frei.';
      case LosVerdict.marginal:
        return 'Die direkte Linie ist frei, aber Bäume oder Dächer in der Fresnelzone können dämpfen.';
      case LosVerdict.blocked:
        return 'Ein Hügel oder die Erdkugel schneidet die Strecke. Ohne Repeater auf der Höhe kommt das Signal kaum durch.';
      case LosVerdict.noFix:
        return 'Beide Enden brauchen GPS (aus dem Advert) oder eine eingetippte Position.';
    }
  }
}

/// Free-space path loss in dB. [distanceM] > 0, [freqMhz] > 0.
double freeSpacePathLossDb(double distanceM, double freqMhz) {
  final km = max(distanceM, 1) / 1000.0;
  return 20 * log(km) / ln10 + 20 * log(freqMhz) / ln10 + 32.44;
}

/// Earth bulge with k-factor (4/3 ≈ tropospheric refraction).
double earthBulgeM(double d1m, double d2m, {double k = 4 / 3}) {
  return (d1m * d2m) / (2 * k * earthRadiusM);
}

/// First Fresnel radius in metres.
double fresnelRadiusM({
  required double d1m,
  required double d2m,
  required double freqMhz,
}) {
  final d = d1m + d2m;
  if (d <= 0 || freqMhz <= 0) return 0;
  final lambda = 299792458.0 / (freqMhz * 1e6);
  return sqrt(lambda * d1m * d2m / d);
}

/// Radio horizon (k = 4/3) in metres for two antenna heights.
double radioHorizonM(double h1m, double h2m) {
  final a = max(h1m, 0);
  final b = max(h2m, 0);
  return 4120 * (sqrt(a) + sqrt(b));
}

LosResult analyzeLos({
  required GeoPoint from,
  required GeoPoint to,
  required String fromName,
  required String toName,
  double freqMhz = 869.525,
  List<double>? terrainM,
  int sampleCount = 32,
}) {
  if (!from.isValid || !to.isValid) {
    return LosResult(
      from: from,
      to: to,
      fromName: fromName,
      toName: toName,
      distanceM: 0,
      bearing: 0,
      freqMhz: freqMhz,
      fsplDb: 0,
      verdict: LosVerdict.noFix,
      samples: const [],
      worstClearanceM: 0,
      minFresnelClearPct: 0,
    );
  }
  final dist = haversineM(from, to);
  final brg = bearingDeg(from, to);
  final points = samplePath(from, to, count: sampleCount);
  final elev = terrainM == null
      ? points.map((p) => p.elevM).toList()
      : [
          for (var i = 0; i < points.length; i++)
            i < terrainM.length ? terrainM[i] : points[i].elevM,
        ];
  if (elev.isNotEmpty) {
    elev[0] = from.elevM;
    elev[elev.length - 1] = to.elevM;
  }
  final start = from.antennaM;
  final end = to.antennaM;
  final samples = <LosSample>[];
  var worst = double.infinity;
  var worstFresnelPct = double.infinity;
  for (var i = 0; i < points.length; i++) {
    final d1 = dist * (points.length == 1 ? 0 : i / (points.length - 1));
    final d2 = dist - d1;
    final bulge = earthBulgeM(d1, d2);
    final los = start + (end - start) * (dist == 0 ? 0 : d1 / dist);
    final f1 = fresnelRadiusM(d1m: d1, d2m: d2, freqMhz: freqMhz);
    final obstacle = elev[i] + bulge;
    final clearance = los - obstacle;
    final pct = f1 <= 0 ? 1.0 : clearance / f1;
    samples.add(
      LosSample(
        distM: d1,
        terrainM: elev[i],
        bulgeM: bulge,
        losM: los,
        fresnelM: f1,
        clearanceM: clearance,
      ),
    );
    if (clearance < worst) worst = clearance;
    if (pct < worstFresnelPct) worstFresnelPct = pct;
  }
  final verdict = worst < 0
      ? LosVerdict.blocked
      : (worstFresnelPct < 0.6 ? LosVerdict.marginal : LosVerdict.clear);
  return LosResult(
    from: from,
    to: to,
    fromName: fromName,
    toName: toName,
    distanceM: dist,
    bearing: brg,
    freqMhz: freqMhz,
    fsplDb: freeSpacePathLossDb(dist, freqMhz),
    verdict: verdict,
    samples: samples,
    worstClearanceM: worst.isFinite ? worst : 0,
    minFresnelClearPct: worstFresnelPct.isFinite ? worstFresnelPct : 0,
  );
}

/// Offline stand-in. A city-to-summit hop stays low until near the high end
/// (a linear ramp would fake a 1000 m ridge in the middle of the plain).
List<double> syntheticTerrain(GeoPoint from, GeoPoint to, {int count = 32}) {
  final n = count < 2 ? 2 : count;
  final distKm = haversineM(from, to) / 1000;
  final delta = to.elevM - from.elevM;
  return [
    for (var i = 0; i < n; i++)
      _shapedElev(from.elevM, delta, i / (n - 1)) +
          (distKm < 10 ? 0.0 : 10 * sin(pi * i / (n - 1))),
  ];
}

double _shapedElev(double start, double delta, double t) {
  if (delta.abs() < 80) return start + delta * t;
  if (delta > 0) return start + delta * t * t * t;
  return start + delta * (1 - (1 - t) * (1 - t) * (1 - t));
}
