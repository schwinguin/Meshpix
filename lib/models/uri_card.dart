import 'dart:typed_data';

import 'contact.dart';

/// MeshCore One / official app `meshcore://` business-card helpers.
class MeshCoreUri {
  static String contact({
    required String name,
    required List<int> publicKey,
    int type = AdvType.chat,
  }) {
    final key = hexOf(publicKey);
    return Uri(
      scheme: 'meshcore',
      host: 'contact',
      path: '/add',
      queryParameters: {
        'name': name,
        'public_key': key,
        'type': '$type',
      },
    ).toString();
  }

  static MeshContact? parseContact(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme != 'meshcore') return null;
    final isAdd = (uri.host == 'contact' && uri.path.contains('add')) ||
        uri.path.contains('contact/add');
    if (!isAdd) return null;
    final name = uri.queryParameters['name'];
    final keyHex = uri.queryParameters['public_key'];
    if (name == null || name.isEmpty || keyHex == null) return null;
    final key = bytesFromHex(keyHex);
    if (key.length != 32) return null;
    final type = int.tryParse(uri.queryParameters['type'] ?? '1') ?? AdvType.chat;
    return MeshContact(publicKey: key, name: name, type: type);
  }

  static String hexOf(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List bytesFromHex(String hex) {
    final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (clean.length.isOdd) return Uint8List(0);
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
