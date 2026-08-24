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

/// Sichtlinie (Pfad-Tab): Karte mit Ziel B — Kontakt per Dropdown oder frei per
/// Tap. A ist immer die eigene Position. Darunter Urteil + Profil + Kennzahlen.
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

  List<GeoPoint> _nodePoints(AppController app) {
    final list = <GeoPoint>[for (final c in app.contacts) ?app.pointFor(c)];
    final self = app.selfPoint();
    if (self != null) list.add(self);
    return list;
  }

  List<LatLng> _fitPoints(AppController app) {
    final pts = <LatLng>[
      if (app.selfPoint() != null)
        LatLng(app.selfPoint()!.lat, app.selfPoint()!.lon),
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

  Widget _hint(GeoPoint? self, GeoPoint? b) {
    final text = self == null
        ? 'Eigene Position fehlt — siehe „Ich"'
        : b == null
        ? 'Ziel setzen: Karte tippen'
        : 'Karte tippen: Ziel verschieben';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.touch_app, size: 15, color: meshTeal),
            const SizedBox(width: 6),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final self = app.selfPoint();
    final b = app.mapPointB;
    final los = app.lastLosMap;
    final lineColor = _verdictColor(los);
    final withFix = app.contacts.where((c) => c.hasLocation).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final targetName = b == null ? '—' : _matchName(app, b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A = ich (Position + Fix).
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _SelfFix(),
        ),
        // B = Ziel: Kontakt-Dropdown + Fit/Reset.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
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
                onPressed: b == null ? null : app.clearMapPoints,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        // Statuszeile + Gelände-Toggle.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Ich → $targetName',
                  style: const TextStyle(fontSize: 12, color: meshPaper),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              FilterChip(
                label: const Text('Gelände'),
                selected: app.useOnlineElevation,
                onSelected: app.setOnlineElevation,
              ),
            ],
          ),
        ),
        // Karte.
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
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
                    // A (ich) + B (Ziel) Pins.
                    MarkerLayer(
                      markers: [
                        if (self != null)
                          Marker(
                            point: LatLng(self.lat, self.lon),
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
                    if (self != null && b != null)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: [
                              LatLng(self.lat, self.lon),
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
                // Hinweis oben: was der nächste Tap macht.
                Align(alignment: Alignment.topCenter, child: _hint(self, b)),
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
                if (self != null)
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: IconButton.filledTonal(
                        tooltip: 'Meine Position zentrieren',
                        onPressed: () {
                          _controller.move(LatLng(self.lat, self.lon), 15);
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
        ),
        // Urteil + Profil + Kennzahlen.
        if (los != null && los.verdict != LosVerdict.noFix)
          _LosDetail(los: los, color: lineColor),
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

class _SelfFix extends StatelessWidget {
  const _SelfFix();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final p = app.selfPoint();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Text(
        p == null
            ? 'Ich: Position fehlt — antippen und eintragen'
            : 'Ich: ${p.lat.toStringAsFixed(4)}, ${p.lon.toStringAsFixed(4)} · ${p.elevM.round()} m + ${p.aglM.round()} m Antenne',
        style: const TextStyle(fontSize: 13),
      ),
      children: [
        const Text(
          'Kommt aus dem eigenen Advert, oder du tippst sie. Antennenhöhe über Grund — nicht die Meereshöhe.',
          style: TextStyle(fontSize: 12, color: meshPaper),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                initialValue:
                    (app.selfLatOverride ?? app.self?.lat)?.toString() ?? '',
                decoration: const InputDecoration(
                  labelText: 'Breite',
                  isDense: true,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                onChanged: (v) => app.setSelfFix(
                  lat: double.tryParse(v.replaceAll(',', '.')),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                initialValue:
                    (app.selfLonOverride ?? app.self?.lon)?.toString() ?? '',
                decoration: const InputDecoration(
                  labelText: 'Länge',
                  isDense: true,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                onChanged: (v) => app.setSelfFix(
                  lon: double.tryParse(v.replaceAll(',', '.')),
                ),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                initialValue:
                    (app.selfAltOverride ?? app.self?.alt)?.toString() ?? '',
                decoration: const InputDecoration(
                  labelText: 'Höhe m ü. NN',
                  isDense: true,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                onChanged: (v) => app.setSelfFix(
                  alt: double.tryParse(v.replaceAll(',', '.')),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Antenne ${app.selfAglM.round()} m',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        Slider(
          value: app.selfAglM.clamp(1, 30),
          min: 1,
          max: 30,
          divisions: 29,
          label: '${app.selfAglM.round()} m',
          onChanged: (v) => app.setSelfFix(aglM: v),
        ),
      ],
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

class _LosDetail extends StatelessWidget {
  const _LosDetail({required this.los, required this.color});
  final LosResult los;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: meshCard,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.6)),
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
                formatKm(radioHorizonM(los.from.antennaM, los.to.antennaM)),
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
