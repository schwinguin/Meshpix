import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/geo/geo.dart';
import 'package:meshpix/geo/los.dart';

void main() {
  test('haversine and bearing for a short Munich hop', () {
    const a = GeoPoint(lat: 48.137154, lon: 11.576124, elevM: 515);
    const b = GeoPoint(lat: 48.1520, lon: 11.6120, elevM: 525);
    final m = haversineM(a, b);
    expect(m, greaterThan(2500));
    expect(m, lessThan(4500));
    expect(bearingDeg(a, b), inInclusiveRange(0, 360));
  });

  test('FSPL and Fresnel have expected ballpark', () {
    expect(freeSpacePathLossDb(10000, 869.525), closeTo(111.2, 0.5));
    final f1 = fresnelRadiusM(d1m: 5000, d2m: 5000, freqMhz: 869.525);
    expect(f1, greaterThan(20));
    expect(f1, lessThan(40));
    expect(earthBulgeM(20000, 20000), greaterThan(20));
  });

  test('clear short link vs blocked ridge', () {
    const handheld = GeoPoint(lat: 48.14, lon: 11.58, elevM: 500, aglM: 2);
    const peer = GeoPoint(lat: 48.15, lon: 11.61, elevM: 510, aglM: 2);
    expect(
      analyzeLos(from: handheld, to: peer, fromName: 'A', toName: 'B').verdict,
      LosVerdict.marginal,
    );

    const from = GeoPoint(lat: 48.14, lon: 11.58, elevM: 500, aglM: 15);
    const to = GeoPoint(lat: 48.15, lon: 11.61, elevM: 510, aglM: 15);
    final clear = analyzeLos(from: from, to: to, fromName: 'A', toName: 'B');
    expect(clear.verdict, LosVerdict.clear);

    final n = clear.samples.length;
    final ridge = [for (var i = 0; i < n; i++) i == n ~/ 2 ? 2500.0 : 500.0];
    final blocked = analyzeLos(
      from: from,
      to: to,
      fromName: 'A',
      toName: 'B',
      terrainM: ridge,
    );
    expect(blocked.verdict, LosVerdict.blocked);
    expect(blocked.worstClearanceM, lessThan(0));
  });

  test('missing GPS is noFix', () {
    final r = analyzeLos(
      from: const GeoPoint(lat: 0, lon: 0),
      to: const GeoPoint(lat: 48, lon: 11),
      fromName: 'A',
      toName: 'B',
    );
    expect(r.verdict, LosVerdict.noFix);
  });
}
