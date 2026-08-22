import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'client.dart';
import 'constants.dart';

class BleScanHit {
  BleScanHit({required this.id, required this.name, required this.device});
  final String id;
  final String name;
  final BluetoothDevice device;
}

class BleScanner {
  Stream<List<BleScanHit>> scan({Duration timeout = const Duration(seconds: 8)}) async* {
    await _ensurePermissions();
    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidUsesFineLocation: false,
    );
    yield* FlutterBluePlus.scanResults.map((results) {
      final hits = <BleScanHit>[];
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        if (!MeshCoreUuids.matchesName(name) && name.isEmpty) {
          // Still offer unnamed devices with the MeshCore service.
          final hasService = r.advertisementData.serviceUuids.any(
            (u) => u.str.toLowerCase() == MeshCoreUuids.service,
          );
          if (!hasService) continue;
        } else if (name.isNotEmpty && !MeshCoreUuids.matchesName(name)) {
          continue;
        }
        hits.add(
          BleScanHit(
            id: r.device.remoteId.str,
            name: name.isEmpty ? r.device.remoteId.str : name,
            device: r.device,
          ),
        );
      }
      return hits;
    });
  }

  Future<void> stop() => FlutterBluePlus.stopScan();

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;
    if (await Permission.bluetoothScan.isDenied) {
      await Permission.bluetoothScan.request();
    }
    if (await Permission.bluetoothConnect.isDenied) {
      await Permission.bluetoothConnect.request();
    }
    if (await Permission.locationWhenInUse.isDenied) {
      await Permission.locationWhenInUse.request();
    }
  }
}

class BleTransport implements CompanionTransport {
  BleTransport(this._device);

  final BluetoothDevice _device;
  BluetoothCharacteristic? _rx;
  bool _writeNoResponse = false;
  final _frames = StreamController<Uint8List>.broadcast();
  StreamSubscription<List<int>>? _notifySub;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  Future<void> connect() async {
    await _device.connect(timeout: const Duration(seconds: 15));
    try {
      await _device.requestMtu(185);
    } catch (_) {}
    final services = await _device.discoverServices();
    BluetoothService? nus;
    for (final s in services) {
      if (s.uuid.str.toLowerCase() == MeshCoreUuids.service) {
        nus = s;
        break;
      }
    }
    if (nus == null) {
      throw StateError('Kein MeshCore Nordic-UART-Service gefunden');
    }
    BluetoothCharacteristic? tx;
    for (final c in nus.characteristics) {
      final id = c.uuid.str.toLowerCase();
      if (id == MeshCoreUuids.rxWrite) _rx = c;
      if (id == MeshCoreUuids.txNotify) tx = c;
    }
    final rx = _rx;
    if (rx == null || tx == null) {
      throw StateError('RX/TX-Characteristic fehlt');
    }
    final rxProps = rx.properties;
    _writeNoResponse = rxProps.writeWithoutResponse;
    if (!_writeNoResponse && !rxProps.write) {
      throw StateError('RX-Characteristic unterstützt kein Schreiben');
    }
    await tx.setNotifyValue(true);
    _notifySub = tx.onValueReceived.listen((value) {
      if (value.isEmpty) return;
      _frames.add(Uint8List.fromList(value));
    });
  }

  @override
  Future<void> write(Uint8List frame) async {
    final rx = _rx;
    if (rx == null) throw StateError('nicht verbunden');
    await rx.write(frame, withoutResponse: _writeNoResponse);
  }

  @override
  Future<void> close() async {
    await _notifySub?.cancel();
    await _frames.close();
    await _device.disconnect();
  }
}
