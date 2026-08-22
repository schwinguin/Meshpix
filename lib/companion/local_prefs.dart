import 'package:shared_preferences/shared_preferences.dart';

/// Letztes erfolgreich verbundenes BLE-Gerät (Auto-Reconnect beim Start).
class DeviceMemory {
  const DeviceMemory(this.remoteId, this.name);
  final String remoteId;
  final String name;
}

/// Lokale, geräteunabhängige Einstellungen: Block-/Mute-Listen und
/// Geräte-Erinnerung. Block/Mute sind reine UI-Filter auf eingehende
/// Nachrichten — das Funkgerät bleibt unberührt.
class LocalPrefs {
  LocalPrefs._();

  static const _deviceKey = 'meshpix.lastDevice';
  static const _deviceNameKey = 'meshpix.lastDeviceName';
  static const _blockedKey = 'meshpix.blockedContacts';
  static const _mutedContactsKey = 'meshpix.mutedContacts';
  static const _mutedChannelsKey = 'meshpix.mutedChannels';

  static Future<DeviceMemory?> readDevice() async {
    final p = await SharedPreferences.getInstance();
    final id = p.getString(_deviceKey);
    if (id == null || id.isEmpty) return null;
    return DeviceMemory(id, p.getString(_deviceNameKey) ?? '');
  }

  static Future<void> saveDevice(String remoteId, String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_deviceKey, remoteId);
    await p.setString(_deviceNameKey, name);
  }

  static Future<void> clearDevice() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_deviceKey);
    await p.remove(_deviceNameKey);
  }

  static Set<String> _readSet(SharedPreferences p, String key) =>
      (p.getString(key) ?? '')
          .split(',')
          .where((s) => s.isNotEmpty)
          .toSet();

  static Future<void> _writeSet(
    SharedPreferences p,
    String key,
    Set<String> values,
  ) =>
      p.setString(key, values.join(','));

  static Future<Set<String>> readBlockedContacts() async {
    final p = await SharedPreferences.getInstance();
    return _readSet(p, _blockedKey);
  }

  static Future<void> saveBlockedContacts(Set<String> keys) async {
    final p = await SharedPreferences.getInstance();
    await _writeSet(p, _blockedKey, keys);
  }

  static Future<Set<String>> readMutedContacts() async {
    final p = await SharedPreferences.getInstance();
    return _readSet(p, _mutedContactsKey);
  }

  static Future<void> saveMutedContacts(Set<String> keys) async {
    final p = await SharedPreferences.getInstance();
    await _writeSet(p, _mutedContactsKey, keys);
  }

  static Future<Set<String>> readMutedChannels() async {
    final p = await SharedPreferences.getInstance();
    return _readSet(p, _mutedChannelsKey);
  }

  static Future<void> saveMutedChannels(Set<String> names) async {
    final p = await SharedPreferences.getInstance();
    await _writeSet(p, _mutedChannelsKey, names);
  }
}
