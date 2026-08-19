import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_controller.dart';
import 'chat_screen.dart';
import 'theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshPix'),
        actions: [
          if (app.mode == AppMode.simulator)
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: app.activeNodeId,
                dropdownColor: const Color(0xFF1B1C22),
                items: app.sessions.values
                    .map(
                      (s) => DropdownMenuItem(
                        value: s.id,
                        child: Text(s.name),
                      ),
                    )
                    .toList(),
                onChanged: (id) {
                  if (id != null) app.switchNode(id);
                },
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SegmentedButton<AppMode>(
              segments: const [
                ButtonSegment(
                  value: AppMode.simulator,
                  label: Text('Simulator'),
                  icon: Icon(Icons.science_outlined),
                ),
                ButtonSegment(
                  value: AppMode.bluetooth,
                  label: Text('Bluetooth'),
                  icon: Icon(Icons.bluetooth),
                ),
              ],
              selected: {app.mode},
              onSelectionChanged: (s) {
                final mode = s.first;
                if (mode == AppMode.simulator) {
                  app.useSimulator();
                } else {
                  app.startScan();
                }
              },
            ),
          ),
          if (app.status != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(app.status!, style: const TextStyle(color: meshPaper)),
            ),
          if (app.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(app.error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          if (app.mode == AppMode.bluetooth && app.scanning)
            const LinearProgressIndicator(),
          Expanded(
            child: app.mode == AppMode.bluetooth && app.sessions['ble'] == null
                ? _ScanList(app: app)
                : _ConvoList(app: app),
          ),
        ],
      ),
    );
  }
}

class _ConvoList extends StatelessWidget {
  const _ConvoList({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    if (app.sessions.isEmpty) {
      return const Center(child: Text('Kein Mesh verbunden'));
    }
    return ListView(
      children: [
        for (final c in app.active.conversations)
          ListTile(
            leading: Icon(c.isChannel ? Icons.campaign_outlined : Icons.person_outline),
            title: Text(c.title),
            subtitle: Text(
              c.isChannel
                  ? 'Nur 1-Paket-Preview'
                  : 'Direct Message, Nachzug möglich',
            ),
            trailing: Text('${c.messages.length}'),
            onTap: () {
              app.open(c);
              Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
              );
            },
          ),
      ],
    );
  }
}

class _ScanList extends StatelessWidget {
  const _ScanList({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    if (app.bleHits.isEmpty) {
      return const Center(
        child: Text('Suche MeshCore-Nodes …\nName z. B. MeshCore- oder HT-'),
      );
    }
    return ListView(
      children: [
        for (final hit in app.bleHits)
          ListTile(
            leading: const Icon(Icons.radar, color: meshTeal),
            title: Text(hit.name),
            subtitle: Text(hit.id),
            onTap: () => app.connectBle(hit),
          ),
      ],
    );
  }
}
