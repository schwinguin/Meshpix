import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/contact.dart';
import '../models/signal.dart';
import '../state/app_controller.dart';
import 'los_map_screen.dart';
import 'theme.dart';
import 'widgets/noise_gauge.dart';

class PathPane extends StatefulWidget {
  const PathPane({super.key});

  @override
  State<PathPane> createState() => _PathPaneState();
}

class _PathPaneState extends State<PathPane>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: context.read<AppController>().pathSubTab.clamp(0, 2),
  );

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (_tabs.indexIsChanging) {
        context.read<AppController>().setPathSubTab(_tabs.index);
      }
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final sub = app.pathSubTab.clamp(0, 2);
    if (_tabs.index != sub && !_tabs.indexIsChanging) {
      _tabs.animateTo(sub);
    }
    final items = [...app.contacts]
      ..sort((a, b) {
        if (a.isAdminNode != b.isAdminNode) return a.isAdminNode ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pfad', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              const Text(
                'Wer antwortet? Wie laut ist der Äther? Ist die Luftlinie frei?',
                style: TextStyle(color: meshPaper),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabs,
          indicatorColor: meshTeal,
          labelColor: meshTeal,
          unselectedLabelColor: meshPaper,
          indicatorSize: TabBarIndicatorSize.label,
          tabs: const [
            Tab(text: 'Ping'),
            Tab(text: 'Rauschen'),
            Tab(text: 'Sichtlinie'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [_PingCard(app: app, items: items)],
              ),
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  NoiseGauge(
                    dbm: app.lastNoise?.dbm ?? app.localNoiseFloor,
                    source: app.lastNoise?.sourceName,
                    history: app.noiseSamples.map((s) => s.dbm).toList(),
                  ),
                ],
              ),
              const LosMapPane(),
            ],
          ),
        ),
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
