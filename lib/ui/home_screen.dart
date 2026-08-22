import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat.dart';
import '../state/app_controller.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';
import 'format.dart';
import 'radio_screen.dart';
import 'share_card.dart';
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
          PopupMenuButton<String>(
            onSelected: (v) => _onMenu(context, app, v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'advert0', child: Text('Zero-Hop Advert')),
              const PopupMenuItem(value: 'advertFlood', child: Text('Flood Advert')),
              const PopupMenuItem(value: 'card', child: Text('Meine Karte (QR)')),
              const PopupMenuItem(value: 'import', child: Text('Kontakt aus Zwischenablage')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'sim', child: Text('Simulator')),
              const PopupMenuItem(value: 'ble', child: Text('Bluetooth scannen')),
            ],
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
                : _tabBody(app),
          ),
        ],
      ),
      bottomNavigationBar: app.mode == AppMode.bluetooth && app.sessions['ble'] == null
          ? null
          : NavigationBar(
              selectedIndex: app.homeTab,
              onDestinationSelected: app.selectTab,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: 'Chats',
                ),
                NavigationDestination(
                  icon: Icon(Icons.people_outline),
                  selectedIcon: Icon(Icons.people),
                  label: 'Kontakte',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_input_antenna),
                  selectedIcon: Icon(Icons.settings_input_antenna),
                  label: 'Funk',
                ),
              ],
            ),
    );
  }

  Widget _tabBody(AppController app) {
    switch (app.homeTab) {
      case 1:
        return const ContactsPane();
      case 2:
        return const RadioPane();
      default:
        return _ConvoList(app: app);
    }
  }

  void _onMenu(BuildContext context, AppController app, String v) {
    switch (v) {
      case 'advert0':
        app.sendAdvert();
      case 'advertFlood':
        app.sendAdvert(flood: true);
      case 'card':
        final uri = app.exportSelfUri();
        if (uri.isEmpty) return;
        showShareCard(
          context,
          title: app.self?.name ?? 'Ich',
          uri: uri,
        );
      case 'import':
        importFromClipboard(context, app);
      case 'sim':
        app.useSimulator();
      case 'ble':
        app.startScan();
    }
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
    final convos = [...app.active.conversations]
      ..sort((a, b) {
        final at = a.lastMessage?.timestamp;
        final bt = b.lastMessage?.timestamp;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    return ListView(
      children: [
        for (final c in convos)
          ListTile(
            leading: Icon(
              c.isChannel ? Icons.campaign_outlined : Icons.person_outline,
              color: c.favourite ? meshAmber : meshTeal,
            ),
            title: Text(c.title),
            subtitle: Text(
              c.preview ??
                  (c.isChannel ? 'Channel · Preview + Text' : 'Direct Message'),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (c.lastMessage != null)
                  Text(
                    formatTime(c.lastMessage!.timestamp),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (c.unread > 0)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: meshTeal,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${c.unread}', style: const TextStyle(fontSize: 12)),
                  )
                else
                  Text('${c.messages.length}'),
              ],
            ),
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
