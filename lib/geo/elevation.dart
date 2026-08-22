import 'dart:convert';
import 'dart:io';

import 'geo.dart';
import 'los.dart';

abstract class ElevationSource {
  Future<List<double>> along(GeoPoint from, GeoPoint to, {int count = 32});
}

class SyntheticElevation implements ElevationSource {
  const SyntheticElevation();

  @override
  Future<List<double>> along(GeoPoint from, GeoPoint to, {int count = 32}) {
    return Future<List<double>>.value(
      syntheticTerrain(from, to, count: count),
    );
  }
}

/// Copernicus 90 m DEM via Open-Meteo. Falls back to [SyntheticElevation].
class OpenMeteoElevation implements ElevationSource {
  OpenMeteoElevation({this.fallback = const SyntheticElevation()});

  final ElevationSource fallback;
  final _client = HttpClient();

  @override
  Future<List<double>> along(GeoPoint from, GeoPoint to, {int count = 32}) async {
    final points = samplePath(from, to, count: count);
    try {
      final lats = points.map((p) => p.lat.toStringAsFixed(5)).join(',');
      final lons = points.map((p) => p.lon.toStringAsFixed(5)).join(',');
      final uri = Uri.https('api.open-meteo.com', '/v1/elevation', {
        'latitude': lats,
        'longitude': lons,
      });
      final req = await _client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) {
        return await fallback.along(from, to, count: count);
      }
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      final list = (json['elevation'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList();
      if (list == null || list.length != points.length) {
        return await fallback.along(from, to, count: count);
      }
      return list;
    } catch (_) {
      return await fallback.along(from, to, count: count);
    }
  }
}
