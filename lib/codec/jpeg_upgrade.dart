import 'dart:typed_data';

import 'package:image/image.dart' as im;

import 'rgba.dart';

/// Fit [source] into a square JPEG of [size] at [quality] (1–100).
Uint8List encodeJpegSquare(
  RgbaImage source, {
  required int size,
  required int quality,
}) {
  final squared = source.square(size);
  final frame = im.Image(
    width: squared.width,
    height: squared.height,
    numChannels: 3,
  );
  final px = [0, 0, 0, 0];
  for (var y = 0; y < squared.height; y++) {
    for (var x = 0; x < squared.width; x++) {
      squared.getPixel(x, y, px);
      frame.setPixelRgb(x, y, px[0], px[1], px[2]);
    }
  }
  return Uint8List.fromList(
    im.encodeJpg(frame, quality: quality.clamp(1, 100)),
  );
}

class JpegArgb {
  JpegArgb({required this.width, required this.height, required this.argb});
  final int width;
  final int height;
  final Uint32List argb;
}

JpegArgb decodeJpegToArgb(Uint8List jpeg) {
  final frame = im.decodeJpg(jpeg);
  if (frame == null) {
    throw const FormatException('JPEG decode failed');
  }
  final argb = Uint32List(frame.width * frame.height);
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      final p = frame.getPixel(x, y);
      final r = p.r.toInt() & 0xFF;
      final g = p.g.toInt() & 0xFF;
      final b = p.b.toInt() & 0xFF;
      argb[y * frame.width + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
  }
  return JpegArgb(width: frame.width, height: frame.height, argb: argb);
}
