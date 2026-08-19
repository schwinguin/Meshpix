import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../codec/mp1.dart';

class PixelPreview extends StatelessWidget {
  const PixelPreview({
    super.key,
    required this.image,
    this.size = 160,
  });

  final DecodedImage image;
  final double size;

  @override
  Widget build(BuildContext context) {
    final argb = image.toArgb();
    return CustomPaint(
      size: Size(size, size),
      painter: _PixelPainter(
        width: image.width,
        height: image.height,
        argb: argb,
      ),
    );
  }
}

class _PixelPainter extends CustomPainter {
  _PixelPainter({
    required this.width,
    required this.height,
    required this.argb,
  });

  final int width;
  final int height;
  final Uint32List argb;

  @override
  void paint(Canvas canvas, Size size) {
    if (width == 0 || height == 0) return;
    final pw = size.width / width;
    final ph = size.height / height;
    final paint = Paint()..isAntiAlias = false;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        paint.color = Color(argb[y * width + x]);
        canvas.drawRect(
          Rect.fromLTWH(x * pw, y * ph, pw + 0.5, ph + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PixelPainter oldDelegate) =>
      oldDelegate.argb != argb;
}

Future<ui.Image> decodeUiImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}
