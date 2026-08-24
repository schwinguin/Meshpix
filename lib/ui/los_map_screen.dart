import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../geo/geo.dart';
import '../geo/los.dart';
import '../state/app_controller.dart';
import 'theme.dart';
import 'widgets/los_chart.dart';

/// LOS-Karte (Tab-Pane): A und B per Tap auf einer OpenStreetMap-Karte
/// wählen — wie bei MeshCore One. Die Verbindungslinie färbt sich nach
/// Urteil (grün/gelb/rot), bekannte Mesh-Knoten werden als Pins eingeblendet.
class LosMapPane extends StatefulWidget {
  const LosMapPane({super.key});

  @override
  State<LosMapPane> createState() => _LosMapPaneState();
}

class _LosMapPaneState extends State<LosMapPane> {
  final MapController _controller = MapController();
  bool _showNodes = true;

  Color _verdictColor(LosResult? r) => switch (r?.verdict) {
    LosVerdict.clear => meshTeal,
    LosVerdict.marginal => meshAmber,
    LosVerdict.blocked => const Color(0xFFE76F51),
    _ => const Color(0xFF6B7280),
  };

  List<GeoPoint> _centerPoints(AppController app) {
    return <GeoPoint>[
      if (app.mapPointA != null) app.mapPointA!,
      if (app.mapPointB != null) app.mapPointB!,
      ..._nodePoints(app),
    ];
  }

  LatLng _centerOf(AppController app) {
    final pts = _centerPoints(app);
    if (pts.isEmpty) return const LatLng(49.4, 8.9);
    double lat = 0, lon = 0;
    for (final p in pts) {
      lat += p.lat;
      lon += p.lon;
    }
    return LatLng(lat / pts.length, lon / pts.length);
  }

  List<GeoPoint> _nodePoints(AppController app) {
    final list = <GeoPoint>[for (final c in app.contacts) ?app.pointFor(c)];
    final self = app.selfPoint();
    if (self != null) list.add(self);
    return list;
  }

  void _fit(AppController app) {
    final pts = <LatLng>[
      if (app.mapPointA != null) LatLng(app.mapPointA!.lat, app.mapPointA!.lon),
      if (app.mapPointB != null) LatLng(app.mapPointB!.lat, app.mapPointB!.lon),
    ];
    if (_showNodes) {
      for (final p in _nodePoints(app)) {
        pts.add(LatLng(p.lat, p.lon));
      }
    }
    if (pts.length < 2) {
      final c = _centerOf(app);
      _controller.move(c, 12);
      return;
    }
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.all(56),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final a = app.mapPointA;
    final b = app.mapPointB;
    final los = app.lastLosMap;
    final lineColor = _verdictColor(los);

    return Column(
      children: [
        // Fit + Zurücksetzen.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Karte an A/B/Knoten anpassen',
                onPressed: () => _fit(app),
                icon: const Icon(Icons.fit_screen_outlined),
              ),
              IconButton(
                tooltip: 'Zurücksetzen',
                onPressed: app.mapPointA == null && app.mapPointB == null
                    ? null
                    : app.clearMapPoints,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            children: [
              // A/B-Auswahl + Statuszeile.
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    _EndpointChip(
                      label: 'A',
                      color: meshAmber,
                      active: app.mapTapTarget == 0,
                      has: a != null,
                      onTap: () => app.setMapTapTarget(0),
                    ),
                    const Text(' → ', style: TextStyle(fontSize: 18)),
                    _EndpointChip(
                      label: 'B',
                      color: meshTeal,
                      active: app.mapTapTarget == 1,
                      has: b != null,
                      onTap: () => app.setMapTapTarget(1),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        a == null
                            ? 'Tippe die Karte: Punkt A setzen'
                            : b == null
                            ? 'Tippe die Karte: Punkt B setzen'
                            : app.losMapBusy
                            ? 'Rechne Sicht …'
                            : los != null
                            ? '${los.fromName} → ${los.toName}'
                            : 'A und B stehen',
                        style: const TextStyle(fontSize: 12, color: meshPaper),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
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
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          maxZoom: 19,
                        ),
                        const SimpleAttributionWidget(
                          source: Text('© OpenStreetMap-Mitwirkende'),
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
                        // A/B-Pins.
                        MarkerLayer(
                          markers: [
                            if (a != null)
                              Marker(
                                point: LatLng(a.lat, a.lon),
                                width: 36,
                                height: 36,
                                alignment: const Alignment(0, 1),
                                child: _EndpointPin(
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
                                child: _EndpointPin(
                                  label: 'B',
                                  color: meshTeal,
                                ),
                              ),
                          ],
                        ),
                        // Verbindungslinie A–B, nach Urteil gefärbt.
                        if (a != null && b != null)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: [
                                  LatLng(a.lat, a.lon),
                                  LatLng(b.lat, b.lon),
                                ],
                                color: lineColor,
                                strokeWidth: 3.5,
                                borderStrokeWidth: 6,
                                borderColor: Colors.white.withValues(
                                  alpha: 0.85,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    // Deutlicher Hinweis, was der nächste Tap macht.
                    Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.touch_app,
                                size: 15,
                                color: app.mapTapTarget == 0
                                    ? meshAmber
                                    : meshTeal,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                app.mapTapTarget == 0
                                    ? 'Nächster Tipp: A'
                                    : 'Nächster Tipp: B',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Unten rechts: Knoten ein/aus.
                    Align(
                      alignment: Alignment.bottomRight,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: FilterChip(
                          label: const Text('Knoten'),
                          selected: _showNodes,
                          onSelected: (v) => setState(() => _showNodes = v),
                        ),
                      ),
                    ),
                    // Unten links: eigene Position zentrieren.
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: IconButton.filledTonal(
                          tooltip: 'Meine Position zentrieren',
                          onPressed: app.selfPoint() == null
                              ? null
                              : () {
                                  final p = app.selfPoint()!;
                                  _controller.move(LatLng(p.lat, p.lon), 15);
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
                  ],
                ),
              ),
              // Urteil + Kompakt-Profil unter der Karte.
              if (los != null && los.verdict != LosVerdict.noFix)
                _MapLosPanel(los: los, color: lineColor, app: app),
            ],
          ),
        ),
      ],
    );
  }
}

class _EndpointChip extends StatelessWidget {
  const _EndpointChip({
    required this.label,
    required this.color,
    required this.active,
    required this.has,
    required this.onTap,
  });
  final String label;
  final Color color;
  final bool active;
  final bool has;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.25) : meshCardElevated,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: active ? color : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: has ? color : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1.5),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: active ? color : meshPaper,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
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

class _MapLosPanel extends StatelessWidget {
  const _MapLosPanel({
    required this.los,
    required this.color,
    required this.app,
  });
  final LosResult los;
  final Color color;
  final AppController app;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: meshCard,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                los.verdictLabel,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => app.setPathSubTab(2),
                icon: const Icon(Icons.insights_outlined, size: 18),
                label: const Text('Details: Sichtlinie'),
              ),
            ],
          ),
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
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String k, String v) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
