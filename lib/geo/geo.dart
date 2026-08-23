import 'dart:math';

class GeoPoint {
  const GeoPoint({
    required this.lat,
    required this.lon,
    this.elevM = 0,
    this.aglM = 2,
  });

  final double lat;
  final double lon;
  final double elevM;
  final double aglM;

  double get antennaM => elevM + aglM;

  bool get isValid =>
      lat.abs() <= 90 && lon.abs() <= 180 && (lat != 0 || lon != 0);
}

const earthRadiusM = 6371000.0;

double _rad(double deg) => deg * pi / 180;
double _deg(double rad) => rad * 180 / pi;

/// Great-circle distance in metres.
double haversineM(GeoPoint a, GeoPoint b) {
  final dLat = _rad(b.lat - a.lat);
  final dLon = _rad(b.lon - a.lon);
  final la1 = _rad(a.lat);
  final la2 = _rad(b.lat);
  final h =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2);
  return 2 * earthRadiusM * atan2(sqrt(h), sqrt(1 - h));
}

/// Initial bearing in degrees, 0 = Nord.
double bearingDeg(GeoPoint a, GeoPoint b) {
  final la1 = _rad(a.lat);
  final la2 = _rad(b.lat);
  final dLon = _rad(b.lon - a.lon);
  final y = sin(dLon) * cos(la2);
  final x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon);
  return (_deg(atan2(y, x)) + 360) % 360;
}

/// Point a fraction [t] (0–1) along the great circle.
GeoPoint greatCirclePoint(GeoPoint a, GeoPoint b, double t) {
  if (t <= 0) return a;
  if (t >= 1) return b;
  final la1 = _rad(a.lat);
  final lo1 = _rad(a.lon);
  final la2 = _rad(b.lat);
  final lo2 = _rad(b.lon);
  final d = haversineM(a, b) / earthRadiusM;
  if (d < 1e-9) return a;
  final sinD = sin(d);
  final u = sin((1 - t) * d) / sinD;
  final v = sin(t * d) / sinD;
  final x = u * cos(la1) * cos(lo1) + v * cos(la2) * cos(lo2);
  final y = u * cos(la1) * sin(lo1) + v * cos(la2) * sin(lo2);
  final z = u * sin(la1) + v * sin(la2);
  return GeoPoint(
    lat: _deg(atan2(z, sqrt(x * x + y * y))),
    lon: _deg(atan2(y, x)),
    elevM: a.elevM + (b.elevM - a.elevM) * t,
    aglM: a.aglM + (b.aglM - a.aglM) * t,
  );
}

List<GeoPoint> samplePath(GeoPoint a, GeoPoint b, {int count = 32}) {
  final n = count < 2 ? 2 : count;
  return [for (var i = 0; i < n; i++) greatCirclePoint(a, b, i / (n - 1))];
}

String formatKm(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  if (meters < 10000) return '${(meters / 1000).toStringAsFixed(2)} km';
  return '${(meters / 1000).toStringAsFixed(1)} km';
}

String formatBearing(double deg) {
  const names = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
  final idx = ((deg + 22.5) / 45).floor() % 8;
  return '${deg.round()}° ${names[idx]}';
}
