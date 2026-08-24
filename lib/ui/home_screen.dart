import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_controller.dart';
import 'chat_screen.dart';
import 'channels_screen.dart';
import 'contacts_screen.dart';
import 'format.dart';
import 'path_screen.dart';
import 'radio_screen.dart';
import 'share_card.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshPix'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => _onMenu(context, app, v),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'advert0',
                child: Text('Zero-Hop Advert'),
              ),
              const PopupMenuItem(
                value: 'advertFlood',
                child: Text('Flood Advert'),
              ),
              const PopupMenuItem(
                value: 'card',
                child: Text('Meine Karte (QR)'),
              ),
              const PopupMenuItem(
                value: 'import',
                child: Text('Kontakt aus Zwischenablage'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'ble',
                child: Text('Bluetooth scannen'),
              ),
              if (app.session != null) ...const [
                PopupMenuDivider(),
                PopupMenuItem(value: 'disconnect', child: Text('Trennen')),
                PopupMenuItem(
                  value: 'forget',
                  child: Text('Trennen & vergessen'),
                ),
                PopupMenuItem(value: 'reset', child: Text('Werksreset')),
              ],
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (app.status != null || app.error != null)
            _StatusBanner(status: app.status, error: app.error),
          if (app.scanning) const LinearProgressIndicator(),
          Expanded(
            child: app.session == null
                ? (app.reconnecting
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 32,
                                width: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              ),
                              SizedBox(height: 12),
                              Text('Verbinde …'),
                            ],
                          ),
                        )
                      : _ScanList(app: app))
                : _tabBody(app),
          ),
        ],
      ),
      bottomNavigationBar: app.session == null
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
                  icon: Icon(Icons.campaign_outlined),
                  selectedIcon: Icon(Icons.campaign),
                  label: 'Kanäle',
                ),
                NavigationDestination(
                  icon: Icon(Icons.hub_outlined),
                  selectedIcon: Icon(Icons.hub),
                  label: 'Knoten',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_input_antenna),
                  selectedIcon: Icon(Icons.settings_input_antenna),
                  label: 'Funk',
                ),
                NavigationDestination(
                  icon: Icon(Icons.visibility_outlined),
                  selectedIcon: Icon(Icons.visibility),
                  label: 'Pfad',
                ),
              ],
            ),
    );
  }

  Widget _tabBody(AppController app) {
    switch (app.homeTab) {
      case 1:
        return const ChannelsPane();
      case 2:
        return const ContactsPane();
      case 3:
        return const RadioPane();
      case 4:
        return const PathPane();
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
        showShareCard(context, title: app.self?.name ?? 'Ich', uri: uri);
      case 'import':
        importFromClipboard(context, app);
      case 'ble':
        app.startScan();
      case 'disconnect':
        app.disconnect();
      case 'forget':
        _confirm(
          context,
          'Gerät vergessen? Die Automatik-Verbindung wird gelöscht.',
          () async {
            app.forgetDevice();
          },
        );
      case 'reset':
        _confirm(
          context,
          'Werksreset? Das Gerät startet neu und das BLE-Pairing wird gelöscht.',
          () => app.factoryResetDevice(),
        );
    }
  }

  Future<void> _confirm(
    BuildContext context,
    String text,
    Future<void> Function() action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sicher?'),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Weiter'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) await action();
  }
}

/// Statuszeile oben: Info (Teal) oder Fehler (Rot) mit Icon —
/// deutlich besser lesbar als nackter Text.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({this.status, this.error});
  final String? status;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final isError = error != null;
    final text = isError ? error! : status!;
    final color = isError ? Theme.of(context).colorScheme.error : meshTeal;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: meshPaper)),
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
    if (app.session == null) {
      return const Center(child: Text('Kein Mesh verbunden'));
    }
    // Nur echte DMs: Kanäle leben im Kanäle-Tab, Repeater im Knoten-Tab.
    final convos = app.active.conversations.where((c) => !c.isChannel).toList()
      ..sort((a, b) {
        final at = a.lastMessage?.timestamp;
        final bt = b.lastMessage?.timestamp;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    if (convos.isEmpty) {
      return const Center(
        child: Text('Noch keine Chats — unter „Knoten" einen antippen'),
      );
    }
    return ListView(
      children: [
        for (final c in convos)
          ListTile(
            leading: Icon(
              Icons.person_outline,
              color: c.favourite ? meshAmber : meshTeal,
            ),
            title: Text(c.title),
            subtitle: Text(c.preview ?? 'Direct Message'),
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: meshTeal,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${c.unread}',
                      style: const TextStyle(fontSize: 12),
                    ),
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bluetooth_searching,
              size: 56,
              color: meshTeal.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            const Text(
              'Kein MeshCore-Node gefunden',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              'Name z. B. „MeshCore-“ oder „HT-“. Gerät einschalten und Bluetooth aktivieren.',
              textAlign: TextAlign.center,
              style: TextStyle(color: meshPaper),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: app.scanning ? null : app.startScan,
              icon: app.scanning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.radar),
              label: Text(app.scanning ? 'Suche …' : 'Scannen'),
            ),
          ],
        ),
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
