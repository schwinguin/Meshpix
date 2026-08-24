import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../geo/geo.dart';
import '../geo/los.dart';
import '../models/contact.dart';
import '../models/signal.dart';
import '../state/app_controller.dart';
import 'theme.dart';
import 'widgets/los_chart.dart';

/// Sichtlinie (Pfad-Tab): Karte mit Zielen A/B — per Dropdown (B) oder frei
/// per Karten-Tap; der A/B-Schalter bestimmt, welchen Punkt der Tap setzt.
/// Ohne Tap gilt A = eigene Position. Unten als Overlay: Urteil + Profil.
class LosMapPane extends StatefulWidget {
  const LosMapPane({super.key});

  @override
  State<LosMapPane> createState() => _LosMapPaneState();
}

class _LosMapPaneState extends State<LosMapPane> {
  final MapController _controller = MapController();
  bool _showNodes = true;

  /// Zuletzt weggeklicktes Ergebnis; ein neues Ergebnis blendet das Detail
  /// automatisch wieder ein.
  LosResult? _dismissedLos;

  Color _verdictColor(LosResult? r) => switch (r?.verdict) {
    LosVerdict.clear => meshTeal,
    LosVerdict.marginal => meshAmber,
    LosVerdict.blocked => const Color(0xFFE76F51),
    _ => const Color(0xFF6B7280),
  };

  List<GeoPoint> _nodePoints(AppController app) {
    final list = <GeoPoint>[for (final c in app.contacts) ?app.pointFor(c)];
    final self = app.selfPoint();
    if (self != null) list.add(self);
    return list;
  }

  List<LatLng> _fitPoints(AppController app) {
    final pts = <LatLng>[
      if (app.pointA() != null) LatLng(app.pointA()!.lat, app.pointA()!.lon),
      if (app.mapPointB != null) LatLng(app.mapPointB!.lat, app.mapPointB!.lon),
    ];
    if (_showNodes) {
      for (final p in _nodePoints(app)) {
        pts.add(LatLng(p.lat, p.lon));
      }
    }
    return pts;
  }

  LatLng _centerOf(AppController app) {
    final pts = _fitPoints(app);
    if (pts.isEmpty) return const LatLng(49.4, 8.9);
    double lat = 0, lon = 0;
    for (final p in pts) {
      lat += p.latitude;
      lon += p.longitude;
    }
    return LatLng(lat / pts.length, lon / pts.length);
  }

  void _fit(AppController app) {
    final pts = _fitPoints(app);
    if (pts.length < 2) {
      _controller.move(_centerOf(app), 12);
      return;
    }
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.all(56),
      ),
    );
  }

  String _matchName(AppController app, GeoPoint p) {
    for (final c in app.contacts) {
      final cp = app.pointFor(c);
      if (cp != null &&
          (cp.lat - p.lat).abs() < 1e-5 &&
          (cp.lon - p.lon).abs() < 1e-5) {
        return c.name;
      }
    }
    return 'Punkt B';
  }

  /// Statuszeile: Route zusammengefasst + was der nächste Tap macht.
  Widget _hint(GeoPoint? a, GeoPoint? b, AppController app) {
    final aLabel = a == null
        ? 'A fehlt'
        : app.mapPointA != null
        ? 'Punkt A'
        : 'Ich';
    final bLabel = b == null ? 'B fehlt' : _matchName(app, b);
    final pick = app.losTapTarget == 'a' ? 'A' : 'B';
    return Row(
      children: [
        const Icon(Icons.touch_app, size: 15, color: meshTeal),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$aLabel → $bLabel · Karte tippen: $pick',
            style: const TextStyle(fontSize: 12, color: meshPaper),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final aPoint = app.pointA();
    final b = app.mapPointB;
    final los = app.lastLosMap;
    final lineColor = _verdictColor(los);
    final withFix = app.contacts.where((c) => c.hasLocation).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Zeile 1: A/B-Wahl + Ziel-Dropdown + Kartensteuerung.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'a', label: Text('A')),
                  ButtonSegment(value: 'b', label: Text('B')),
                ],
                selected: {app.losTapTarget},
                onSelectionChanged: (s) => app.setLosTapTarget(s.first),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _TargetDropdown(app: app, withFix: withFix, current: b),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Karte an Route anpassen',
                onPressed: () => _fit(app),
                icon: const Icon(Icons.fit_screen_outlined),
              ),
              IconButton(
                tooltip: 'Zurücksetzen',
                onPressed: (b == null && app.mapPointA == null)
                    ? null
                    : app.clearMapPoints,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        // Zeile 2: Status + Darstellung-Toggles.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(
            children: [
              Expanded(child: _hint(aPoint, b, app)),
              const SizedBox(width: 4),
              FilterChip(
                label: const Text('Knoten'),
                selected: _showNodes,
                onSelected: (v) => setState(() => _showNodes = v),
              ),
              const SizedBox(width: 4),
              FilterChip(
                label: const Text('Gelände'),
                selected: app.useOnlineElevation,
                onSelected: app.setOnlineElevation,
              ),
            ],
          ),
        ),
        // Karte: volle Fläche, Detail unten als Overlay.
        Expanded(
          child: Stack(
            children: [
              FlutterMap(
                mapController: _controller,
                options: MapOptions(
                  initialCenter: _centerOf(context.read<AppController>()),
                  initialZoom: 12,
                  onTap: (tapPos, point) {
                    app.placeTapped(
                      GeoPoint(lat: point.latitude, lon: point.longitude),
                    );
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/dark_all/{z}/{x}/{y}.png',
                    maxZoom: 19,
                    // CARTO-Basemap (OSM-Daten): zuverlaessiges Deep-Zoom,
                    // kein OSM-Rate-Limit. {s} verteilt auf a/b/c.
                    tileProvider: NetworkTileProvider(
                      headers: {
                        'User-Agent': 'MeshPix/1.0 (https://github.com/schwinguin/Meshpix)',
                      },
                    ),
                  ),
                  const SimpleAttributionWidget(
                    source: Text('© OpenStreetMap-Mitwirkende · © CARTO'),
                  ),
                  // Knoten des Mesh (inkl. eigener Position).
                  if (_showNodes)
                    MarkerLayer(
                      markers: [
                        for (final p in _nodePoints(app))
                          Marker(
                            point: LatLng(p.lat, p.lon),
                            width: 26,
                            height: 26,
                            child: _NodePin(point: p),
                          ),
                      ],
                    ),
                  // A (frei getippt oder ich) + B (Ziel) Pins.
                  MarkerLayer(
                    markers: [
                      if (aPoint != null)
                        Marker(
                          point: LatLng(aPoint.lat, aPoint.lon),
                          width: 36,
                          height: 36,
                          alignment: const Alignment(0, 1),
                          child: const _EndpointPin(
                            label: 'A',
                            color: meshAmber,
                          ),
                        ),
                      if (b != null)
                        Marker(
                          point: LatLng(b.lat, b.lon),
                          width: 36,
                          height: 36,
                          alignment: const Alignment(0, 1),
                          child: const _EndpointPin(
                            label: 'B',
                            color: meshTeal,
                          ),
                        ),
                    ],
                  ),
                  // Verbindungslinie A–B, nach Urteil gefärbt.
                  if (aPoint != null && b != null)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: [
                            LatLng(aPoint.lat, aPoint.lon),
                            LatLng(b.lat, b.lon),
                          ],
                          color: lineColor,
                          strokeWidth: 3.5,
                          borderStrokeWidth: 6,
                          borderColor: Colors.white.withValues(alpha: 0.85),
                        ),
                      ],
                    ),
                ],
              ),
              // Oben links: Punkt A zentrieren.
              if (aPoint != null)
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: IconButton.filledTonal(
                      tooltip: 'Punkt A zentrieren',
                      onPressed: () {
                        _controller.move(LatLng(aPoint.lat, aPoint.lon), 15);
                      },
                      icon: const Icon(Icons.my_location),
                    ),
                  ),
                ),
              if (app.losMapBusy)
                const Align(
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(),
                  ),
                ),
              // Unten: Urteil + Profil + Kennzahlen (wegklickbar).
              if (los != null &&
                  los.verdict != LosVerdict.noFix &&
                  los != _dismissedLos)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _LosDetail(
                    los: los,
                    color: lineColor,
                    onDismiss: () => setState(() => _dismissedLos = los),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TargetDropdown extends StatelessWidget {
  const _TargetDropdown({
    required this.app,
    required this.withFix,
    required this.current,
  });
  final AppController app;
  final List<MeshContact> withFix;
  final GeoPoint? current;

  String? get _selected {
    if (current == null) return null;
    for (final c in withFix) {
      final p = app.pointFor(c);
      if (p != null &&
          (p.lat - current!.lat).abs() < 1e-5 &&
          (p.lon - current!.lon).abs() < 1e-5) {
        return c.keyHex;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(labelText: 'Ziel (B)', isDense: true),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _selected,
          hint: const Text('frei wählen (Karte tippen)'),
          items: [
            for (final c in withFix)
              DropdownMenuItem(
                value: c.keyHex,
                child: Text(
                  '${c.name} · ${defaultAglLabel(c.type)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (key) {
            if (key == null) return;
            final c = withFix.firstWhere((x) => x.keyHex == key);
            app.computeLos(c);
          },
        ),
      ),
    );
  }
}

class _EndpointPin extends StatelessWidget {
  const _EndpointPin({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
          Container(width: 2, height: 10, color: color),
        ],
      ),
    );
  }
}

class _NodePin extends StatelessWidget {
  const _NodePin({required this.point});
  final GeoPoint point;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: meshInk,
        shape: BoxShape.circle,
        border: Border.all(color: meshTeal, width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: const Icon(Icons.cell_tower, size: 13, color: meshTeal),
    );
  }
}

/// Urteil + Profil + Kennzahlen — Overlay unten auf der Karte, begrenzt auf
/// 45 % der Bildhöhe, wegklickbar (neue Rechnung blendet es wieder ein).
class _LosDetail extends StatelessWidget {
  const _LosDetail({
    required this.los,
    required this.color,
    required this.onDismiss,
  });
  final LosResult los;
  final Color color;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.45,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              color: meshCard,
              border: Border.all(color: Color(0xFF33343E)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 12),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: color.withValues(alpha: 0.6),
                            ),
                          ),
                          child: Text(
                            '${los.fromName} → ${los.toName} · ${los.verdictLabel}',
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Ausblenden',
                        onPressed: onDismiss,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  LosChart(result: los, height: 110),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 14,
                    runSpacing: 6,
                    children: [
                      _stat('Distanz', formatKm(los.distanceM)),
                      _stat('Richtung', formatBearing(los.bearing)),
                      _stat('FSPL', '${los.fsplDb.toStringAsFixed(0)} dB'),
                      _stat('Freihalte', '${los.worstClearanceM.round()} m'),
                      _stat(
                        'Fresnel',
                        '${(los.minFresnelClearPct * 100).clamp(0, 999).round()} %',
                      ),
                      _stat(
                        'Horizont',
                        formatKm(
                          radioHorizonM(los.from.antennaM, los.to.antennaM),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    los.verdictHint,
                    style: const TextStyle(fontSize: 12, color: meshPaper),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String k, String v) {
    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            k,
            style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
          ),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
