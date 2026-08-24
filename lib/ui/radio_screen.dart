import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../state/app_controller.dart';
import 'share_card.dart';
import 'theme.dart';

class RadioPane extends StatefulWidget {
  const RadioPane({super.key});

  @override
  State<RadioPane> createState() => _RadioPaneState();
}

class _RadioPaneState extends State<RadioPane> {
  late final TextEditingController _name;
  late final TextEditingController _freq;
  late final TextEditingController _bw;
  late final TextEditingController _sf;
  late final TextEditingController _cr;
  late final TextEditingController _pwr;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppController>();
    final radio = app.radioSettings;
    _name = TextEditingController(text: app.self?.name ?? app.active.name);
    _freq = TextEditingController(text: (radio?.freqMhz ?? 869.525).toString());
    _bw = TextEditingController(text: (radio?.bwKhz ?? 250).toString());
    _sf = TextEditingController(text: '${radio?.spreadingFactor ?? 11}');
    _cr = TextEditingController(text: '${radio?.codingRate ?? 5}');
    _pwr = TextEditingController(text: '${radio?.txPowerDbm ?? 22}');
  }

  @override
  void dispose() {
    _name.dispose();
    _freq.dispose();
    _bw.dispose();
    _sf.dispose();
    _cr.dispose();
    _pwr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final batt = app.battery;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('Gerät', style: Theme.of(context).textTheme.titleMedium),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.badge_outlined, color: meshTeal),
          title: Text(app.self?.name ?? app.active.name),
          subtitle: Text(app.self?.keyHex ?? ''),
        ),
        if (batt != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              batt.percent > 20 ? Icons.battery_std : Icons.battery_alert,
              color: meshAmber,
            ),
            title: Text(batt.label),
            subtitle: const Text('Batterie'),
            trailing: IconButton(
              onPressed: app.refreshBattery,
              icon: const Icon(Icons.refresh),
            ),
          ),
        if (app.firmware != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.memory),
            title: Text(app.firmware!.label),
            subtitle: const Text('Firmware'),
          ),
        const Divider(),
        Text('Identität', style: Theme.of(context).textTheme.titleMedium),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Advert-Name'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () async {
            await app.renameSelf(_name.text);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Name gespeichert: ${app.self?.name ?? _name.text.trim()}',
                  ),
                ),
              );
            }
          },
          child: const Text('Name speichern'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => app.sendAdvert(),
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Zero-Hop Advert'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => app.sendAdvert(flood: true),
              icon: const Icon(Icons.cell_tower),
              label: const Text('Flood Advert'),
            ),
            FilledButton.tonalIcon(
              onPressed: () {
                final uri = app.exportSelfUri();
                if (uri.isEmpty) return;
                showShareCard(
                  context,
                  title: app.self?.name ?? 'Ich',
                  subtitle: 'meshcore:// Kontaktkarte',
                  uri: uri,
                );
              },
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Meine Karte'),
            ),
          ],
        ),
        const Divider(height: 32),
        Text('Funk', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          app.radioSettings?.summary ?? 'Keine Parameter',
          style: const TextStyle(color: meshPaper),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<RadioPreset>(
          decoration: const InputDecoration(
            labelText: 'Preset (wie MeshCore One)',
          ),
          items: [
            for (final p in RadioPreset.all)
              DropdownMenuItem(value: p, child: Text(p.label)),
          ],
          onChanged: (p) {
            if (p == null) return;
            _freq.text = '${p.settings.freqMhz}';
            _bw.text = '${p.settings.bwKhz}';
            _sf.text = '${p.settings.spreadingFactor}';
            _cr.text = '${p.settings.codingRate}';
            _pwr.text = '${p.settings.txPowerDbm ?? 22}';
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _freq,
                decoration: const InputDecoration(labelText: 'MHz'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _bw,
                decoration: const InputDecoration(labelText: 'BW kHz'),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _sf,
                decoration: const InputDecoration(labelText: 'SF'),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _cr,
                decoration: const InputDecoration(labelText: 'CR'),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _pwr,
                decoration: const InputDecoration(labelText: 'dBm'),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () async {
            final settings = RadioSettings(
              freqMhz:
                  double.tryParse(_freq.text.replaceAll(',', '.')) ?? 869.525,
              bwKhz: double.tryParse(_bw.text.replaceAll(',', '.')) ?? 250,
              spreadingFactor: int.tryParse(_sf.text) ?? 11,
              codingRate: int.tryParse(_cr.text) ?? 5,
              txPowerDbm: int.tryParse(_pwr.text) ?? 22,
            );
            await app.applyRadio(settings);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Funk geschrieben: ${settings.summary}'),
                ),
              );
            }
          },
          style: FilledButton.styleFrom(backgroundColor: meshAmber),
          child: const Text('Funkparameter schreiben'),
        ),
      ],
    );
  }
}
