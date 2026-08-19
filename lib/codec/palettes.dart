class Rgb {
  const Rgb(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;

  int get argb => 0xFF000000 | (r << 16) | (g << 8) | b;

  int distanceSquared(int rr, int gg, int bb) {
    final dr = r - rr;
    final dg = g - gg;
    final db = b - bb;
    return dr * dr + dg * dg + db * db;
  }
}

class Palette {
  const Palette({required this.id, required this.name, required this.colors});

  final int id;
  final String name;
  final List<Rgb> colors;

  int get bitsPerPixel => colors.length <= 4 ? 2 : 4;

  int nearestIndex(int r, int g, int b) {
    var best = 0;
    var bestD = 1 << 30;
    for (var i = 0; i < colors.length; i++) {
      final d = colors[i].distanceSquared(r, g, b);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }
}

/// High-contrast 4-color mesh palette (2 bits/pixel).
const mesh4 = Palette(
  id: 0,
  name: 'mesh4',
  colors: [
    Rgb(0x14, 0x14, 0x18),
    Rgb(0xF4, 0xF1, 0xDE),
    Rgb(0xE8, 0xA8, 0x38),
    Rgb(0x2A, 0x9D, 0x8F),
  ],
);

/// 16-color palette that dithers photos into something recognizable.
const mesh16 = Palette(
  id: 1,
  name: 'mesh16',
  colors: [
    Rgb(0x00, 0x00, 0x00),
    Rgb(0x7F, 0x00, 0x00),
    Rgb(0x00, 0x7F, 0x00),
    Rgb(0x7F, 0x7F, 0x00),
    Rgb(0x00, 0x00, 0x7F),
    Rgb(0x7F, 0x00, 0x7F),
    Rgb(0x00, 0x7F, 0x7F),
    Rgb(0xBF, 0xBF, 0xBF),
    Rgb(0x7F, 0x7F, 0x7F),
    Rgb(0xFF, 0x00, 0x00),
    Rgb(0x00, 0xFF, 0x00),
    Rgb(0xFF, 0xFF, 0x00),
    Rgb(0x00, 0x00, 0xFF),
    Rgb(0xFF, 0x00, 0xFF),
    Rgb(0x00, 0xFF, 0xFF),
    Rgb(0xFF, 0xFF, 0xFF),
  ],
);

Palette paletteById(int id) => id == mesh16.id ? mesh16 : mesh4;

List<Palette> get allPalettes => const [mesh4, mesh16];
