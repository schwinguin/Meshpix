import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../geo/geo.dart';
import '../geo/los.dart';
import '../models/contact.dart';
import '../models/signal.dart';
import '../state/app_controller.dart';
import 'los_map_screen.dart';
import 'theme.dart';
import 'widgets/los_chart.dart';
import 'widgets/noise_gauge.dart';

class PathPane extends StatelessWidget {
  const PathPane({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final items = [...app.contacts]
      ..sort((a, b) {
        if (a.isAdminNode != b.isAdminNode) return a.isAdminNode ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Pfad',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const LosMapScreen()),
              ),
              icon: const Icon(Icons.map_outlined),
              label: const Text('Karte'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Drei Fragen, von nah nach weit: Wer antwortet? Wie laut ist der Äther? Ist die Luftlinie frei?',
          style: TextStyle(color: meshPaper),
        ),
        const SizedBox(height: 16),
        _PingCard(app: app, items: items),
        const SizedBox(height: 14),
        NoiseGauge(
          dbm: app.lastNoise?.dbm ?? app.localNoiseFloor,
          source: app.lastNoise?.sourceName,
          history: app.noiseSamples.map((s) => s.dbm).toList(),
        ),
        const SizedBox(height: 14),
        _LosCard(app: app, items: items),
      ],
    );
  }
}

class _PingCard extends StatelessWidget {
  const _PingCard({required this.app, required this.items});
  final AppController app;
  final List<MeshContact> items;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF22232B),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Ping',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: app.pingingAll || items.isEmpty
                      ? null
                      : app.pingAll,
                  icon: app.pingingAll
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sensors),
                  label: Text(app.pingingAll ? 'Pingt …' : 'Alle pingen'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Klopft per Status an bekannte Repeater und Kontakte. Die Zahl ist die Laufzeit hin und zurück — klein heißt nah oder ein guter gespeicherter Pfad.',
              style: TextStyle(fontSize: 12, color: meshPaper),
            ),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Keine bekannten Nodes. Erst Advert oder Kontakt importieren.',
                ),
              )
            else
              for (final c in items)
                _PingTile(contact: c, result: app.pings[c.keyHex]),
          ],
        ),
      ),
    );
  }
}

class _PingTile extends StatelessWidget {
  const _PingTile({required this.contact, this.result});
  final MeshContact contact;
  final PingResult? result;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppController>();
    final color = result == null
        ? const Color(0xFF6B7280)
        : result!.inFlight
        ? meshAmber
        : result!.ok
        ? meshTeal
        : const Color(0xFFE76F51);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            contact.isAdminNode ? Icons.cell_tower : Icons.person_outline,
            color: color,
          ),
          if (result?.inFlight == true)
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
            ),
        ],
      ),
      title: Text(contact.name),
      subtitle: Text(
        [
          AdvType.label(contact.type),
          if (contact.hasPath) '${contact.hopCount} Hop',
          if (result != null) result!.qualityLabel,
          if (result?.snr != null) 'SNR ${result!.snr!.toStringAsFixed(1)} dB',
          if (result?.noiseFloor != null) '${result!.noiseFloor} dBm',
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            result?.rttLabel ?? '—',
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
          IconButton(
            tooltip: 'Ping ${contact.name}',
            onPressed: result?.inFlight == true
                ? null
                : () => app.ping(contact),
            icon: const Icon(Icons.podcasts),
          ),
        ],
      ),
      onTap: () => app.computeLos(contact),
    );
  }
}

class _LosCard extends StatelessWidget {
  const _LosCard({required this.app, required this.items});
  final AppController app;
  final List<MeshContact> items;

  @override
  Widget build(BuildContext context) {
    final withFix = items.where((c) => c.hasLocation).toList();
    final focus = withFix.cast<MeshContact?>().firstWhere(
      (c) => c!.keyHex == app.pathFocusKey,
      orElse: () => withFix.isEmpty ? null : withFix.first,
    );
    final los = app.lastLos;
    final self = app.selfPoint();
    return Card(
      color: const Color(0xFF22232B),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sichtlinie', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'Kein Stadtplan — das Profil zeigt Gelände plus Erdkugel zwischen dir und dem Ziel. Grün: frei. Gelb: Fresnelzone knapp. Rot: Berg oder Horizont im Weg.',
              style: TextStyle(fontSize: 12, color: meshPaper),
            ),
            const SizedBox(height: 10),
            _SelfFix(app: app),
            const SizedBox(height: 8),
            if (withFix.isEmpty)
              const Text(
                'Keiner der Kontakte hat GPS im Advert. Dann bleibt nur Ping — Sichtlinie braucht zwei Positionen.',
              )
            else ...[
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Ziel',
                  isDense: true,
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: focus?.keyHex,
                    items: [
                      for (final c in withFix)
                        DropdownMenuItem(
                          value: c.keyHex,
                          child: Text(
                            '${c.name} · ${defaultAglLabel(c.type)}'
                            '${self != null ? ' · ${formatKm(haversineM(self, app.pointFor(c)!))}' : ''}',
                          ),
                        ),
                    ],
                    onChanged: (key) {
                      final c = withFix.cast<MeshContact?>().firstWhere(
                        (x) => x!.keyHex == key,
                        orElse: () => null,
                      );
                      if (c != null) app.computeLos(c);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: focus == null || app.losBusy
                          ? null
                          : () => app.computeLos(focus),
                      icon: const Icon(Icons.visibility_outlined),
                      label: Text(app.losBusy ? 'Rechne …' : 'Sicht prüfen'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Gelände online'),
                    selected: app.useOnlineElevation,
                    onSelected: app.setOnlineElevation,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                app.useOnlineElevation
                    ? 'Open-Meteo-Höhen (Copernicus). Ohne Netz fällt MeshPix auf ein grobes Profil zurück.'
                    : 'Offline-Profil: bekannte Höhen, Erdkugel, leichte Hügel. Für echte Berge Gelände online einschalten.',
                style: const TextStyle(fontSize: 11, color: Color(0xFF9AA0A6)),
              ),
            ],
            if (los != null && los.verdict != LosVerdict.noFix) ...[
              const SizedBox(height: 12),
              LosChart(result: los),
              const SizedBox(height: 10),
              _VerdictBanner(result: los),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
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
            ] else if (los?.verdict == LosVerdict.noFix)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(los!.verdictHint),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String k, String v) {
    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            k,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9AA0A6)),
          ),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SelfFix extends StatelessWidget {
  const _SelfFix({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final p = app.selfPoint();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Text(
        p == null
            ? 'Meine Position fehlt — antippen und eintragen'
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

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.result});
  final LosResult result;

  @override
  Widget build(BuildContext context) {
    final color = switch (result.verdict) {
      LosVerdict.clear => meshTeal,
      LosVerdict.marginal => meshAmber,
      LosVerdict.blocked => const Color(0xFFE76F51),
      LosVerdict.noFix => meshPaper,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        result.verdictLabel,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 16,
        ),
      ),
    );
  }
}
