import 'dart:typed_data';

/// Tight RGBA8 bitmap used by the encoder (no Flutter dependency).
class RgbaImage {
  RgbaImage({required this.width, required this.height, required this.bytes}) {
    if (bytes.length != width * height * 4) {
      throw ArgumentError(
        'RGBA buffer is ${bytes.length} bytes, expected ${width * height * 4}',
      );
    }
  }

  final int width;
  final int height;
  final Uint8List bytes;

  int offset(int x, int y) => (y * width + x) * 4;

  void getPixel(int x, int y, List<int> out) {
    final o = offset(x, y);
    out[0] = bytes[o];
    out[1] = bytes[o + 1];
    out[2] = bytes[o + 2];
    out[3] = bytes[o + 3];
  }

  /// Integer nearest-neighbor scale (good enough for 24–96 px mesh images).
  RgbaImage resizeNearest(int newW, int newH) {
    if (newW == width && newH == height) return this;
    final out = Uint8List(newW * newH * 4);
    for (var y = 0; y < newH; y++) {
      final srcY = (y * height) ~/ newH;
      for (var x = 0; x < newW; x++) {
        final srcX = (x * width) ~/ newW;
        final si = (srcY * width + srcX) * 4;
        final di = (y * newW + x) * 4;
        out[di] = bytes[si];
        out[di + 1] = bytes[si + 1];
        out[di + 2] = bytes[si + 2];
        out[di + 3] = bytes[si + 3];
      }
    }
    return RgbaImage(width: newW, height: newH, bytes: out);
  }

  /// Center-crop to a square, then scale.
  RgbaImage square(int size) {
    final side = width < height ? width : height;
    final x0 = (width - side) ~/ 2;
    final y0 = (height - side) ~/ 2;
    final cropped = Uint8List(side * side * 4);
    for (var y = 0; y < side; y++) {
      final src = offset(x0, y0 + y);
      cropped.setRange(y * side * 4, (y + 1) * side * 4, bytes, src);
    }
    return RgbaImage(
      width: side,
      height: side,
      bytes: cropped,
    ).resizeNearest(size, size);
  }

  /// 0xAARRGGBB pixel buffer (Flutter `Color` layout).
  Uint32List toArgb() {
    final out = Uint32List(width * height);
    for (var i = 0; i < width * height; i++) {
      final r = bytes[i * 4];
      final g = bytes[i * 4 + 1];
      final b = bytes[i * 4 + 2];
      out[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
    return out;
  }
}

/// Synthetic test card so the composer works without a camera.
RgbaImage makeTestCard(int size) {
  final bytes = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      final fx = x / (size - 1);
      final fy = y / (size - 1);
      var r = (fx * 255).round();
      var g = (fy * 180 + 40).round();
      var b = ((1 - fx) * 200 + 30).round();
      final dx = x - size * 0.5;
      final dy = y - size * 0.45;
      if (dx * dx + dy * dy < size * size * 0.04) {
        r = 244;
        g = 241;
        b = 222;
      }
      if (y > size * 0.82) {
        r = 232;
        g = 168;
        b = 56;
      }
      bytes[i] = r.clamp(0, 255);
      bytes[i + 1] = g.clamp(0, 255);
      bytes[i + 2] = b.clamp(0, 255);
      bytes[i + 3] = 255;
    }
  }
  return RgbaImage(width: size, height: size, bytes: bytes);
}
