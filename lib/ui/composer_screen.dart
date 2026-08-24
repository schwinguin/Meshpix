import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../codec/mp1.dart';
import '../../codec/rgba.dart';
import '../../state/app_controller.dart';
import 'theme.dart';
import 'widgets/pixel_preview.dart';

class ComposerScreen extends StatefulWidget {
  const ComposerScreen({super.key});

  @override
  State<ComposerScreen> createState() => _ComposerScreenState();
}

class _ComposerScreenState extends State<ComposerScreen> {
  bool _dither = true;
  bool _fourColor = true;
  bool _upgrade = false;
  EncodedTransfer? _encoded;
  DecodedImage? _localPreview;
  String? _error;
  bool _busy = false;
  RgbaImage _source = makeTestCard(96);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final conv = context.read<AppController>().openConversation;
      _upgrade = conv != null && !conv.isChannel;
      _encode(_source);
    });
  }

  Future<void> _encode(RgbaImage src) async {
    _source = src;
    final app = context.read<AppController>();
    final conv = app.openConversation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final encoded = app.codec.encode(
        src,
        options: EncodeOptions(
          dither: _dither,
          fourColorPreview: _fourColor,
          includeUpgrade: _upgrade && conv != null && !conv.isChannel,
        ),
      );
      setState(() {
        _encoded = encoded;
        _localPreview = fullResImage(src);
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _pick(ImageSource source) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: source,
      maxWidth: 512,
      imageQuality: 85,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final uiImage = await decodeUiImage(bytes);
    final bd = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return;
    await _encode(
      RgbaImage(
        width: uiImage.width,
        height: uiImage.height,
        bytes: bd.buffer.asUint8List(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final conv = app.openConversation;
    final channel = conv?.isChannel ?? true;
    return Scaffold(
      appBar: AppBar(title: const Text('Bild senden')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          if (_localPreview != null) ...[
            // Sender sieht sein eigenes Foto in voller Qualität, nicht die
            // quantisierte Mesh-Preview, die der Empfänger bekommt.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Center(
                      child: PixelPreview(image: _localPreview!, size: 196),
                    ),
                    if (_encoded != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        '${_encoded!.stats.summaryDe} · ${_encoded!.stats.previewBytes} Byte',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: meshPaper),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_localPreview == null)
            Center(
              child: Icon(
                Icons.image_outlined,
                size: 56,
                color: meshTeal.withValues(alpha: 0.5),
              ),
            ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      'QUALITÄT',
                      style: TextStyle(
                        color: meshAmber,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('4 Farben (sicher 1 Paket)'),
                    value: _fourColor,
                    onChanged: (v) {
                      setState(() => _fourColor = v);
                      if (_encoded != null) {
                        _encode(_source);
                      }
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Dithering'),
                    value: _dither,
                    onChanged: (v) {
                      setState(() => _dither = v);
                      if (_encoded != null) _encode(_source);
                    },
                  ),
                  SwitchListTile(
                    title: const Text('JPEG-Nachzug (Foto, nur Direct/DM)'),
                    subtitle: Text(
                      channel
                          ? 'Public Channel: nur Preview, kein Flood der Chunks'
                          : 'Empfänger tippt Nachladen. Ziel ~160px JPEG, sonst 96px Pixelart.',
                    ),
                    value: _upgrade && !channel,
                    onChanged: channel
                        ? null
                        : (v) {
                            setState(() => _upgrade = v);
                            if (_encoded != null) _encode(_source);
                          },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FilledButton.icon(
                onPressed: () => _encode(makeTestCard(96)),
                style: FilledButton.styleFrom(
                  backgroundColor: meshCardElevated,
                  foregroundColor: meshPaper,
                ),
                icon: const Icon(Icons.grid_on_outlined),
                label: const Text('Testbild'),
              ),
              FilledButton.icon(
                onPressed: () => _pick(ImageSource.gallery),
                style: FilledButton.styleFrom(
                  backgroundColor: meshCardElevated,
                  foregroundColor: meshPaper,
                ),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Galerie'),
              ),
              FilledButton.icon(
                onPressed: () => _pick(ImageSource.camera),
                style: FilledButton.styleFrom(
                  backgroundColor: meshCardElevated,
                  foregroundColor: meshPaper,
                ),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Kamera'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _encoded == null || _busy
                  ? null
                  : () async {
                      await app.sendEncoded(_encoded!, source: _source);
                      if (context.mounted) Navigator.pop(context);
                    },
              style: FilledButton.styleFrom(
                backgroundColor: meshAmber,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(
                _busy
                    ? 'Kodiere …'
                    : _encoded != null
                    ? 'Senden (${_encoded!.stats.previewBytes} Byte)'
                    : 'Bild wählen',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
