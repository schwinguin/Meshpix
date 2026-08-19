import 'palettes.dart';
import 'rgba.dart';

class IndexedImage {
  IndexedImage({
    required this.width,
    required this.height,
    required this.palette,
    required this.indices,
    required this.dithered,
  }) : assert(indices.length == width * height);

  final int width;
  final int height;
  final Palette palette;
  final List<int> indices;
  final bool dithered;

  int get bitsPerPixel => palette.bitsPerPixel;
}

int _clamp8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// Quantize [src] onto [palette], optionally with Floyd–Steinberg dithering.
IndexedImage quantize(RgbaImage src, Palette palette, {bool dither = true}) {
  final n = src.width * src.height;
  final indices = List<int>.filled(n, 0);
  if (!dither) {
    final px = [0, 0, 0, 0];
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        src.getPixel(x, y, px);
        indices[y * src.width + x] = palette.nearestIndex(px[0], px[1], px[2]);
      }
    }
    return IndexedImage(
      width: src.width,
      height: src.height,
      palette: palette,
      indices: indices,
      dithered: false,
    );
  }

  final rBuf = List<double>.filled(n, 0);
  final gBuf = List<double>.filled(n, 0);
  final bBuf = List<double>.filled(n, 0);
  final px = [0, 0, 0, 0];
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      src.getPixel(x, y, px);
      final i = y * src.width + x;
      rBuf[i] = px[0].toDouble();
      gBuf[i] = px[1].toDouble();
      bBuf[i] = px[2].toDouble();
    }
  }

  void spread(int x, int y, double er, double eg, double eb, double factor) {
    if (x < 0 || y < 0 || x >= src.width || y >= src.height) return;
    final i = y * src.width + x;
    rBuf[i] += er * factor;
    gBuf[i] += eg * factor;
    bBuf[i] += eb * factor;
  }

  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final i = y * src.width + x;
      final r = _clamp8(rBuf[i].round());
      final g = _clamp8(gBuf[i].round());
      final b = _clamp8(bBuf[i].round());
      final idx = palette.nearestIndex(r, g, b);
      indices[i] = idx;
      final c = palette.colors[idx];
      final er = r - c.r;
      final eg = g - c.g;
      final eb = b - c.b;
      spread(x + 1, y, er.toDouble(), eg.toDouble(), eb.toDouble(), 7 / 16);
      spread(x - 1, y + 1, er.toDouble(), eg.toDouble(), eb.toDouble(), 3 / 16);
      spread(x, y + 1, er.toDouble(), eg.toDouble(), eb.toDouble(), 5 / 16);
      spread(x + 1, y + 1, er.toDouble(), eg.toDouble(), eb.toDouble(), 1 / 16);
    }
  }

  return IndexedImage(
    width: src.width,
    height: src.height,
    palette: palette,
    indices: indices,
    dithered: true,
  );
}
