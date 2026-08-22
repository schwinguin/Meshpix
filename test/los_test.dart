import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/geo/geo.dart';
import 'package:meshpix/geo/los.dart';
import 'package:meshpix/models/contact.dart';
import 'package:meshpix/state/app_controller.dart';

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
    final clear = analyzeLos(
      from: from,
      to: to,
      fromName: 'A',
      toName: 'B',
    );
    expect(clear.verdict, LosVerdict.clear);

    final n = clear.samples.length;
    final ridge = [
      for (var i = 0; i < n; i++) i == n ~/ 2 ? 2500.0 : 500.0,
    ];
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

  test('simulator ping fills RTT and noise, LOS to Relay1 is clear', () async {
    final app = AppController();
    addTearDown(app.dispose);
    expect(app.selfPoint(), isNotNull);

    final ben = app.contacts.firstWhere((c) => c.name == 'Ben');
    final relay = app.contacts.firstWhere((c) => c.name == 'Relay1');
    expect(ben.hasLocation, isTrue);
    expect(relay.hasLocation, isTrue);
    expect(relay.type, AdvType.repeater);

    await app.ping(ben);
    final start = DateTime.now();
    while (app.pings[ben.keyHex]?.ok != true) {
      if (DateTime.now().difference(start) > const Duration(seconds: 2)) {
        fail('Ping an Ben kam nicht');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final ping = app.pings[ben.keyHex]!;
    expect(ping.rttMs, isNotNull);
    expect(ping.noiseFloor, isNotNull);
    expect(app.noiseSamples, isNotEmpty);

    final losBen = await app.computeLos(ben);
    expect(losBen.verdict, isNot(LosVerdict.noFix));
    expect(losBen.distanceM, greaterThan(2000));

    final losRelay = await app.computeLos(relay);
    expect(losRelay.verdict, LosVerdict.clear);
    expect(losRelay.distanceM, greaterThan(40000));
    expect(losRelay.samples, isNotEmpty);
  });
}
