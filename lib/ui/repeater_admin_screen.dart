import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/contact.dart';
import '../models/repeater.dart';
import '../state/app_controller.dart';
import 'format.dart';
import 'theme.dart';

class RepeaterAdminScreen extends StatefulWidget {
  const RepeaterAdminScreen({super.key, required this.contact});

  final MeshContact contact;

  @override
  State<RepeaterAdminScreen> createState() => _RepeaterAdminScreenState();
}

class _RepeaterAdminScreenState extends State<RepeaterAdminScreen> {
  final _password = TextEditingController();
  final _cli = TextEditingController();
  final _aclKey = TextEditingController();
  final _scroll = ScrollController();
  int _aclPerm = 3;

  @override
  void dispose() {
    _password.dispose();
    _cli.dispose();
    _aclKey.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final session = app.repeaterSession(widget.contact);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.contact.name),
        actions: [
          if (session.loggedIn)
            TextButton(
              onPressed: () => app.logoutRepeater(widget.contact),
              child: const Text('Logout'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              widget.contact.type == AdvType.room
                  ? Icons.meeting_room_outlined
                  : Icons.cell_tower,
              color: meshTeal,
            ),
            title: Text(widget.contact.name),
            subtitle: Text(
              '${AdvType.label(widget.contact.type)} · ${session.roleLabel}'
              '${widget.contact.hasPath ? ' · ${widget.contact.hopCount} Hop' : ''}',
            ),
          ),
          if (!session.loggedIn) ...[
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Admin-Passwort',
                hintText: 'Standard oft: password',
              ),
              onSubmitted: (_) => _login(app),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: session.busy ? null : () => _login(app),
              icon: const Icon(Icons.login),
              label: Text(session.busy ? 'Login …' : 'Anmelden'),
            ),
            if (session.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  session.lastError!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
          ] else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => app.requestRepeaterStatus(widget.contact),
                  icon: const Icon(Icons.sensors),
                  label: const Text('Status'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => app.traceRepeater(widget.contact),
                  icon: const Icon(Icons.alt_route),
                  label: const Text('Pfad-Trace'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.pop(context);
                    app.showPath(focus: widget.contact);
                    app.ping(widget.contact);
                  },
                  icon: const Icon(Icons.podcasts),
                  label: const Text('Ping / Sicht'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (session.status != null) _StatusCard(status: session.status!),
            if (session.neighbors.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Nachbarn', style: Theme.of(context).textTheme.titleMedium),
              for (final n in session.neighbors)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.cell_tower, size: 18),
                  title: Text(n.prefixHex),
                  subtitle: Text(
                    [
                      if (n.snr != null) '${n.snr!.toStringAsFixed(1)} dB',
                      if (n.heard != null) formatHeard(n.heard),
                    ].join(' · '),
                  ),
                ),
            ],
            const Divider(height: 28),
            Text('CLI', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Container(
              height: 220,
              decoration: BoxDecoration(
                color: const Color(0xFF121318),
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.all(8),
              child: ListView(
                controller: _scroll,
                children: [
                  for (final line in session.transcript)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        _prefix(line.kind) + line.text,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: _color(line.kind),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cmd in repeaterQuickActions)
                  ActionChip(
                    label: Text(cmd, style: const TextStyle(fontSize: 12)),
                    onPressed: () => _run(app, cmd),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _cli,
                    decoration: const InputDecoration(
                      hintText: 'Befehl, z. B. get radio',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _runTyped(app),
                  ),
                ),
                IconButton.filled(
                  onPressed: () => _runTyped(app),
                  icon: const Icon(Icons.send),
                  style: IconButton.styleFrom(backgroundColor: meshTeal),
                ),
              ],
            ),
            const Divider(height: 28),
            Text(
              'ACL (setperm)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            TextField(
              controller: _aclKey,
              decoration: const InputDecoration(
                labelText: 'Public Key (Hex, Prefix ok)',
              ),
            ),
            DropdownButton<int>(
              value: _aclPerm,
              items: const [
                DropdownMenuItem(value: 0, child: Text('0 Entfernen')),
                DropdownMenuItem(value: 1, child: Text('1 Gast')),
                DropdownMenuItem(value: 2, child: Text('2 Read/Write')),
                DropdownMenuItem(value: 3, child: Text('3 Admin')),
              ],
              onChanged: (v) => setState(() => _aclPerm = v ?? 3),
            ),
            FilledButton.tonal(
              onPressed: () {
                final key = _aclKey.text.trim();
                if (key.isEmpty) return;
                _run(app, 'setperm $key $_aclPerm');
              },
              child: const Text('setperm senden'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _login(AppController app) async {
    await app.loginRepeater(widget.contact, _password.text);
  }

  Future<void> _runTyped(AppController app) async {
    final cmd = _cli.text;
    _cli.clear();
    await _run(app, cmd);
  }

  Future<void> _run(AppController app, String command) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;
    if (isDangerCli(trimmed)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Gefährlicher Befehl'),
          content: Text(
            '„$trimmed“ startet Reboot/Erase auf ${widget.contact.name}.\n\n'
            'Tippe den Namen zur Bestätigung.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ausführen'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await app.sendCli(widget.contact, trimmed);
  }

  String _prefix(CliLineKind kind) {
    switch (kind) {
      case CliLineKind.sent:
        return '> ';
      case CliLineKind.reply:
        return '< ';
      case CliLineKind.error:
        return '! ';
      case CliLineKind.info:
        return '* ';
    }
  }

  Color _color(CliLineKind kind) {
    switch (kind) {
      case CliLineKind.sent:
        return meshTeal;
      case CliLineKind.reply:
        return meshPaper;
      case CliLineKind.error:
        return Colors.redAccent;
      case CliLineKind.info:
        return meshAmber;
    }
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});
  final RepeaterStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF22232B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 16,
          runSpacing: 10,
          children: [
            _stat(
              'Batterie',
              status.volts == null
                  ? '—'
                  : '${status.volts!.toStringAsFixed(2)} V',
            ),
            _stat('Uptime', status.uptimeLabel),
            _stat(
              'Noise',
              status.noiseFloor == null ? '—' : '${status.noiseFloor} dBm',
            ),
            _stat(
              'SNR',
              status.lastSnr == null
                  ? '—'
                  : '${status.lastSnr!.toStringAsFixed(1)} dB',
            ),
            _stat('RX', '${status.packetsRecv ?? '—'}'),
            _stat('TX', '${status.packetsSent ?? '—'}'),
            _stat('Queue', '${status.queueLen ?? '—'}'),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: meshPaper)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
