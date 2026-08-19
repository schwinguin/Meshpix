import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'quantize.dart';

enum BodyEncoding { raw, zlib, rle }

Uint8List packIndices(List<int> indices, int bitsPerPixel) {
  if (bitsPerPixel == 4) {
    final out = Uint8List((indices.length + 1) >> 1);
    for (var i = 0; i < indices.length; i++) {
      final v = indices[i] & 0x0F;
      if ((i & 1) == 0) {
        out[i >> 1] = v << 4;
      } else {
        out[i >> 1] |= v;
      }
    }
    return out;
  }
  if (bitsPerPixel != 2) {
    throw ArgumentError('bitsPerPixel must be 2 or 4');
  }
  final out = Uint8List((indices.length + 3) >> 2);
  for (var i = 0; i < indices.length; i++) {
    final v = indices[i] & 0x03;
    final shift = 6 - 2 * (i & 3);
    out[i >> 2] |= v << shift;
  }
  return out;
}

List<int> unpackIndices(Uint8List packed, int count, int bitsPerPixel) {
  final indices = List<int>.filled(count, 0);
  if (bitsPerPixel == 4) {
    for (var i = 0; i < count; i++) {
      final b = packed[i >> 1];
      indices[i] = ((i & 1) == 0) ? (b >> 4) & 0x0F : b & 0x0F;
    }
    return indices;
  }
  for (var i = 0; i < count; i++) {
    final b = packed[i >> 2];
    final shift = 6 - 2 * (i & 3);
    indices[i] = (b >> shift) & 0x03;
  }
  return indices;
}

Uint8List rleEncode(List<int> indices) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (i < indices.length) {
    final v = indices[i] & 0xFF;
    var run = 1;
    while (i + run < indices.length &&
        indices[i + run] == v &&
        run < 255) {
      run++;
    }
    out.addByte(run);
    out.addByte(v);
    i += run;
  }
  return out.takeBytes();
}

List<int> rleDecode(Uint8List data, int count) {
  final indices = List<int>.filled(count, 0);
  var o = 0;
  var i = 0;
  while (i + 1 < data.length && o < count) {
    final run = data[i];
    final v = data[i + 1];
    i += 2;
    for (var k = 0; k < run && o < count; k++) {
      indices[o++] = v;
    }
  }
  if (o != count) {
    throw const FormatException('RLE length mismatch');
  }
  return indices;
}

Uint8List zlibEncode(Uint8List data) =>
    Uint8List.fromList(const ZLibEncoder().encode(data, level: 9));

Uint8List zlibDecode(Uint8List data) =>
    Uint8List.fromList(const ZLibDecoder().decodeBytes(data));

class PackedBody {
  PackedBody(this.encoding, this.bytes);
  final BodyEncoding encoding;
  final Uint8List bytes;
}

/// Pick the smallest body that round-trips [image] indices.
PackedBody compressBody(IndexedImage image) {
  final raw = packIndices(image.indices, image.bitsPerPixel);
  PackedBody best = PackedBody(BodyEncoding.raw, raw);

  try {
    final z = zlibEncode(raw);
    if (z.length < best.bytes.length) {
      best = PackedBody(BodyEncoding.zlib, z);
    }
  } catch (_) {}

  final rle = rleEncode(image.indices);
  if (rle.length < best.bytes.length) {
    best = PackedBody(BodyEncoding.rle, rle);
  }
  return best;
}

List<int> decodeBody({
  required PackedBody body,
  required int count,
  required int bitsPerPixel,
}) {
  switch (body.encoding) {
    case BodyEncoding.raw:
      return unpackIndices(body.bytes, count, bitsPerPixel);
    case BodyEncoding.zlib:
      final raw = zlibDecode(body.bytes);
      return unpackIndices(raw, count, bitsPerPixel);
    case BodyEncoding.rle:
      return rleDecode(body.bytes, count);
  }
}
