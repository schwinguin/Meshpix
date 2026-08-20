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
    final file = await picker.pickImage(source: source, maxWidth: 512, imageQuality: 85);
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
        padding: const EdgeInsets.all(16),
        children: [
          if (_encoded != null)
            Center(
              child: PixelPreview(image: _encoded!.preview.image, size: 196),
            ),
          const SizedBox(height: 12),
          if (_encoded != null)
            Text(
              '${_encoded!.stats.summaryDe} · ${_encoded!.stats.previewBytes} Byte',
              textAlign: TextAlign.center,
            ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          const SizedBox(height: 16),
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
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.tonal(
                onPressed: () => _encode(makeTestCard(96)),
                child: const Text('Testbild'),
              ),
              FilledButton.tonal(
                onPressed: () => _pick(ImageSource.gallery),
                child: const Text('Galerie'),
              ),
              FilledButton.tonal(
                onPressed: () => _pick(ImageSource.camera),
                child: const Text('Kamera'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _encoded == null || _busy
                ? null
                : () async {
                    await app.sendEncoded(_encoded!);
                    if (context.mounted) Navigator.pop(context);
                  },
            style: FilledButton.styleFrom(backgroundColor: meshAmber),
            child: Text(_busy ? 'Kodiere …' : 'Senden'),
          ),
        ],
      ),
    );
  }
}

