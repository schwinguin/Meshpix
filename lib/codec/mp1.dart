import 'dart:math';
import 'dart:typed_data';

import 'jpeg_upgrade.dart';
import 'limits.dart';
import 'packer.dart';
import 'palettes.dart';
import 'quantize.dart';
import 'rgba.dart';

enum Mp1Kind { preview, chunk, pull, nack, abort }

class Mp1Exception implements Exception {
  Mp1Exception(this.message);
  final String message;
  @override
  String toString() => 'Mp1Exception: $message';
}

class Mp1Packet {
  Mp1Packet({
    required this.kind,
    required this.transferId,
    required this.bytes,
  });

  final Mp1Kind kind;
  final int transferId;
  final Uint8List bytes;
}

class DecodedImage {
  DecodedImage({
    required this.width,
    required this.height,
    required this.palette,
    required this.indices,
    required this.dithered,
    required this.upgradeChunks,
    this.argb,
  });

  final int width;
  final int height;
  final Palette palette;
  final List<int> indices;
  final bool dithered;
  final int upgradeChunks;
  final Uint32List? argb;

  bool get isPhoto => argb != null;

  Uint32List toArgb() {
    if (argb != null) return argb!;
    final out = Uint32List(width * height);
    for (var i = 0; i < indices.length; i++) {
      final idx = indices[i].clamp(0, palette.colors.length - 1);
      out[i] = palette.colors[idx].argb;
    }
    return out;
  }
}

/// Local-only, full-quality render of an original (center-cropped square,
/// never upscaled). The sender side always shows this, not the over-the-air
/// quantized preview.
DecodedImage fullResImage(RgbaImage source) {
  final side = source.width < source.height ? source.width : source.height;
  final sq = source.square(side);
  return DecodedImage(
    width: sq.width,
    height: sq.height,
    palette: mesh16,
    indices: const [],
    dithered: false,
    upgradeChunks: 0,
    argb: sq.toArgb(),
  );
}

class PreviewPacket extends Mp1Packet {
  PreviewPacket({
    required super.transferId,
    required super.bytes,
    required this.image,
  }) : super(kind: Mp1Kind.preview);

  final DecodedImage image;
}

class ChunkPacket extends Mp1Packet {
  ChunkPacket({
    required super.transferId,
    required super.bytes,
    required this.seq,
    required this.total,
    required this.slice,
  }) : super(kind: Mp1Kind.chunk);

  final int seq;
  final int total;
  final Uint8List slice;
}

class PullPacket extends Mp1Packet {
  PullPacket({required super.transferId, required super.bytes})
    : super(kind: Mp1Kind.pull);
}

class NackPacket extends Mp1Packet {
  NackPacket({
    required super.transferId,
    required super.bytes,
    required this.missingMask,
  }) : super(kind: Mp1Kind.nack);

  final int missingMask;
}

class AbortPacket extends Mp1Packet {
  AbortPacket({required super.transferId, required super.bytes})
    : super(kind: Mp1Kind.abort);
}

class EncodeOptions {
  const EncodeOptions({
    this.dither = true,
    this.fourColorPreview = true,
    this.includeUpgrade = true,
    this.maxPayload = kMaxDatagramPayload,
    this.maxChunks = kMaxUpgradeChunks,
    this.previewSize = kPreviewTarget,
    this.upgradeSize = kUpgradeTarget,
    this.jpegUpgrade = true,
    this.jpegSize = kJpegUpgradeTarget,
    this.transferId,
  });

  final bool dither;
  final bool fourColorPreview;
  final bool includeUpgrade;
  final int maxPayload;
  final int maxChunks;
  final int previewSize;
  final int upgradeSize;
  final bool jpegUpgrade;
  final int jpegSize;
  final int? transferId;
}

class EncodeStats {
  EncodeStats({
    required this.previewBytes,
    required this.previewWidth,
    required this.previewBpp,
    required this.chunkCount,
    required this.upgradeWidth,
    required this.encoding,
    int? upgradeHeight,
    this.upgradeEncoding = BodyEncoding.raw,
  }) : upgradeHeight = upgradeHeight ?? upgradeWidth;

  final int previewBytes;
  final int previewWidth;
  final int previewBpp;
  final int chunkCount;
  final int upgradeWidth;
  final int upgradeHeight;
  final BodyEncoding encoding;
  final BodyEncoding upgradeEncoding;

  String get summaryDe {
    if (chunkCount == 0) {
      return '1 Paket Preview ($previewWidth×$previewWidth, $previewBpp bit)';
    }
    final kind =
        upgradeEncoding == BodyEncoding.jpeg ? 'JPEG-Nachzug' : 'Nachzug';
    return '1 Paket Preview + $chunkCount Chunks $kind '
        '($upgradeWidth×$upgradeHeight)';
  }
}

class EncodedTransfer {
  EncodedTransfer({
    required this.transferId,
    required this.preview,
    required this.chunks,
    required this.upgradeBlob,
    required this.stats,
  });

  final int transferId;
  final PreviewPacket preview;
  final List<ChunkPacket> chunks;
  final Uint8List upgradeBlob;
  final EncodeStats stats;
}

int _kindBits(Mp1Kind kind) => kind.index;

Mp1Kind _kindFromBits(int bits) {
  final i = bits & 0x07;
  if (i >= Mp1Kind.values.length) {
    throw Mp1Exception('unknown kind $i');
  }
  return Mp1Kind.values[i];
}

int _flags({
  required Mp1Kind kind,
  required BodyEncoding encoding,
  required int bitsPerPixel,
  required bool dithered,
}) {
  var f = _kindBits(kind);
  f |= encoding.index << 3;
  if (bitsPerPixel == 4) f |= 1 << 5;
  if (dithered) f |= 1 << 6;
  return f;
}

BodyEncoding _encodingFromFlags(int flags) {
  final i = (flags >> 3) & 0x03;
  if (i >= BodyEncoding.values.length) {
    throw Mp1Exception('unknown encoding $i');
  }
  return BodyEncoding.values[i];
}

int _bppFromFlags(int flags) => ((flags >> 5) & 1) == 1 ? 4 : 2;

bool _ditherFromFlags(int flags) => ((flags >> 6) & 1) == 1;

void _writeHeader(BytesBuilder out, int flags, int transferId) {
  out.addByte(kMp1Magic0);
  out.addByte(kMp1Magic1);
  out.addByte(kMp1Version);
  out.addByte(flags);
  out.addByte(transferId & 0xFF);
  out.addByte((transferId >> 8) & 0xFF);
}

bool _isMp1(Uint8List b) =>
    b.length >= 6 &&
    b[0] == kMp1Magic0 &&
    b[1] == kMp1Magic1 &&
    b[2] == kMp1Version;

IndexedImage _quantizeTo(RgbaImage src, int size, Palette palette, bool dither) {
  return quantize(src.square(size), palette, dither: dither);
}

Uint8List _blobFor(IndexedImage img) {
  final packed = compressBody(img);
  final out = BytesBuilder(copy: false);
  out.addByte(img.width);
  out.addByte(img.height);
  out.addByte(img.palette.id);
  out.addByte(_flags(
    kind: Mp1Kind.preview,
    encoding: packed.encoding,
    bitsPerPixel: img.bitsPerPixel,
    dithered: img.dithered,
  ));
  out.add(packed.bytes);
  return out.takeBytes();
}

DecodedImage _imageFromIndexed(IndexedImage img, int upgradeChunks) {
  return DecodedImage(
    width: img.width,
    height: img.height,
    palette: img.palette,
    indices: img.indices,
    dithered: img.dithered,
    upgradeChunks: upgradeChunks,
  );
}

PreviewPacket? _tryPreview({
  required IndexedImage img,
  required int transferId,
  required int maxPayload,
  required int upgradeChunks,
}) {
  final packed = compressBody(img);
  final out = BytesBuilder(copy: false);
  _writeHeader(
    out,
    _flags(
      kind: Mp1Kind.preview,
      encoding: packed.encoding,
      bitsPerPixel: img.bitsPerPixel,
      dithered: img.dithered,
    ),
    transferId,
  );
  out.addByte(img.width);
  out.addByte(img.height);
  out.addByte(img.palette.id);
  out.addByte(upgradeChunks);
  out.add(packed.bytes);
  final bytes = out.takeBytes();
  if (bytes.length > maxPayload) return null;
  return PreviewPacket(
    transferId: transferId,
    bytes: bytes,
    image: _imageFromIndexed(img, upgradeChunks),
  );
}

List<ChunkPacket> _chunkBlob({
  required Uint8List blob,
  required int transferId,
  required int maxPayload,
  required int maxChunks,
}) {
  const header = 8;
  final sliceSize = maxPayload - header;
  if (sliceSize < 8) {
    throw Mp1Exception('payload budget too small for chunks');
  }
  final total = (blob.length + sliceSize - 1) ~/ sliceSize;
  if (total > maxChunks) {
    throw Mp1Exception('upgrade needs $total chunks, cap is $maxChunks');
  }
  final chunks = <ChunkPacket>[];
  for (var seq = 0; seq < total; seq++) {
    final start = seq * sliceSize;
    final end = min(blob.length, start + sliceSize);
    final slice = blob.sublist(start, end);
    final out = BytesBuilder(copy: false);
    _writeHeader(
      out,
      _flags(
        kind: Mp1Kind.chunk,
        encoding: BodyEncoding.raw,
        bitsPerPixel: 2,
        dithered: false,
      ),
      transferId,
    );
    out.addByte(seq);
    out.addByte(total);
    out.add(slice);
    final bytes = out.takeBytes();
    chunks.add(
      ChunkPacket(
        transferId: transferId,
        bytes: bytes,
        seq: seq,
        total: total,
        slice: slice,
      ),
    );
  }
  return chunks;
}

Uint8List _blobForJpeg(int width, int height, Uint8List jpeg) {
  final out = BytesBuilder(copy: false);
  out.addByte(width);
  out.addByte(height);
  out.addByte(0xFF);
  out.addByte(
    _flags(
      kind: Mp1Kind.preview,
      encoding: BodyEncoding.jpeg,
      bitsPerPixel: 4,
      dithered: false,
    ),
  );
  out.add(jpeg);
  return out.takeBytes();
}

class Mp1Codec {
  Mp1Codec({Random? random}) : _random = random ?? Random();

  final Random _random;

  EncodedTransfer encode(RgbaImage source, {EncodeOptions options = const EncodeOptions()}) {
    final transferId = options.transferId ?? _random.nextInt(0xFFFF);
    final previewPalettes = options.fourColorPreview
        ? <Palette>[mesh4, mesh16]
        : <Palette>[mesh16, mesh4];
    final sizes = <int>{
      options.previewSize,
      24,
      16,
    }.toList()
      ..sort((a, b) => b.compareTo(a));

    PreviewPacket? preview;
    IndexedImage? previewImg;
    for (final size in sizes) {
      for (final pal in previewPalettes) {
        final img = _quantizeTo(source, size, pal, options.dither);
        final attempt = _tryPreview(
          img: img,
          transferId: transferId,
          maxPayload: options.maxPayload,
          upgradeChunks: 0,
        );
        if (attempt != null) {
          preview = attempt;
          previewImg = img;
          break;
        }
      }
      if (preview != null) break;
    }
    if (preview == null || previewImg == null) {
      throw Mp1Exception('could not fit a preview into ${options.maxPayload} bytes');
    }
    final chosenPreviewImg = previewImg;

    var chunks = <ChunkPacket>[];
    var blob = Uint8List(0);
    var upgradeEncoding = BodyEncoding.raw;
    if (options.includeUpgrade) {
      if (options.jpegUpgrade) {
        jpegSearch:
        for (final size in ({options.jpegSize, 160, 128, 96}
              .where((s) => s > chosenPreviewImg.width)
              .toList()
            ..sort((a, b) => b.compareTo(a)))) {
          for (final quality in const [45, 35, 28, 22]) {
            try {
              final jpg = encodeJpegSquare(source, size: size, quality: quality);
              blob = _blobForJpeg(size, size, jpg);
              chunks = _chunkBlob(
                blob: blob,
                transferId: transferId,
                maxPayload: options.maxPayload,
                maxChunks: options.maxChunks,
              );
              upgradeEncoding = BodyEncoding.jpeg;
              break jpegSearch;
            } catch (_) {
              chunks = [];
              blob = Uint8List(0);
              upgradeEncoding = BodyEncoding.raw;
            }
          }
        }
      }
      if (chunks.isEmpty) {
        final sizes = <int>{
          options.upgradeSize,
          96,
          80,
          64,
          48,
          32,
        }.where((s) => s > chosenPreviewImg.width).toList()
          ..sort((a, b) => b.compareTo(a));
        upgradeSearch:
        for (final size in sizes) {
          for (final pal in [mesh16, mesh4]) {
            try {
              final up = _quantizeTo(source, size, pal, options.dither);
              blob = _blobFor(up);
              chunks = _chunkBlob(
                blob: blob,
                transferId: transferId,
                maxPayload: options.maxPayload,
                maxChunks: options.maxChunks,
              );
              upgradeEncoding = compressBody(up).encoding;
              break upgradeSearch;
            } catch (_) {
              chunks = [];
              blob = Uint8List(0);
            }
          }
        }
      }
    }

    final fitted = _tryPreview(
      img: chosenPreviewImg,
      transferId: transferId,
      maxPayload: options.maxPayload,
      upgradeChunks: chunks.length,
    );
    if (fitted == null) {
      throw Mp1Exception('preview no longer fits after tagging upgrade');
    }
    preview = fitted;

    final packed = compressBody(chosenPreviewImg);
    return EncodedTransfer(
      transferId: transferId,
      preview: preview,
      chunks: chunks,
      upgradeBlob: blob,
      stats: EncodeStats(
        previewBytes: preview.bytes.length,
        previewWidth: chosenPreviewImg.width,
        previewBpp: chosenPreviewImg.bitsPerPixel,
        chunkCount: chunks.length,
        upgradeWidth: chunks.isEmpty ? chosenPreviewImg.width : (blob.isEmpty ? 0 : blob[0]),
        upgradeHeight: chunks.isEmpty ? chosenPreviewImg.height : (blob.isEmpty ? 0 : blob[1]),
        encoding: packed.encoding,
        upgradeEncoding: chunks.isEmpty ? BodyEncoding.raw : upgradeEncoding,
      ),
    );
  }

  PullPacket pull(int transferId) {
    final out = BytesBuilder(copy: false);
    _writeHeader(
      out,
      _flags(
        kind: Mp1Kind.pull,
        encoding: BodyEncoding.raw,
        bitsPerPixel: 2,
        dithered: false,
      ),
      transferId,
    );
    return PullPacket(transferId: transferId, bytes: out.takeBytes());
  }

  NackPacket nack(int transferId, int missingMask) {
    final out = BytesBuilder(copy: false);
    _writeHeader(
      out,
      _flags(
        kind: Mp1Kind.nack,
        encoding: BodyEncoding.raw,
        bitsPerPixel: 2,
        dithered: false,
      ),
      transferId,
    );
    out.addByte(missingMask & 0xFF);
    out.addByte((missingMask >> 8) & 0xFF);
    out.addByte((missingMask >> 16) & 0xFF);
    out.addByte((missingMask >> 24) & 0xFF);
    return NackPacket(
      transferId: transferId,
      bytes: out.takeBytes(),
      missingMask: missingMask,
    );
  }

  AbortPacket abort(int transferId) {
    final out = BytesBuilder(copy: false);
    _writeHeader(
      out,
      _flags(
        kind: Mp1Kind.abort,
        encoding: BodyEncoding.raw,
        bitsPerPixel: 2,
        dithered: false,
      ),
      transferId,
    );
    return AbortPacket(transferId: transferId, bytes: out.takeBytes());
  }

  Mp1Packet parse(Uint8List bytes) {
    if (!_isMp1(bytes)) {
      throw Mp1Exception('not an MP1 packet');
    }
    if (bytes.length > kMaxDatagramPayload) {
      throw Mp1Exception('packet exceeds $kMaxDatagramPayload bytes');
    }
    final flags = bytes[3];
    final kind = _kindFromBits(flags);
    final transferId = bytes[4] | (bytes[5] << 8);
    switch (kind) {
      case Mp1Kind.preview:
        if (bytes.length < 10) throw Mp1Exception('truncated preview');
        final width = bytes[6];
        final height = bytes[7];
        final palette = paletteById(bytes[8]);
        final upgrade = bytes[9];
        final bpp = _bppFromFlags(flags);
        final encoding = _encodingFromFlags(flags);
        final body = PackedBody(encoding, bytes.sublist(10));
        final indices = decodeBody(
          body: body,
          count: width * height,
          bitsPerPixel: bpp,
        );
        return PreviewPacket(
          transferId: transferId,
          bytes: bytes,
          image: DecodedImage(
            width: width,
            height: height,
            palette: palette,
            indices: indices,
            dithered: _ditherFromFlags(flags),
            upgradeChunks: upgrade,
          ),
        );
      case Mp1Kind.chunk:
        if (bytes.length < 8) throw Mp1Exception('truncated chunk');
        return ChunkPacket(
          transferId: transferId,
          bytes: bytes,
          seq: bytes[6],
          total: bytes[7],
          slice: bytes.sublist(8),
        );
      case Mp1Kind.pull:
        return PullPacket(transferId: transferId, bytes: bytes);
      case Mp1Kind.nack:
        if (bytes.length < 8) throw Mp1Exception('truncated nack');
        var mask = bytes[6] | (bytes[7] << 8);
        if (bytes.length >= 10) {
          mask |= bytes[8] << 16;
          mask |= bytes[9] << 24;
        }
        return NackPacket(
          transferId: transferId,
          bytes: bytes,
          missingMask: mask,
        );
      case Mp1Kind.abort:
        return AbortPacket(transferId: transferId, bytes: bytes);
    }
  }

  DecodedImage decodeUpgradeBlob(Uint8List blob) {
    if (blob.length < 4) throw Mp1Exception('truncated upgrade blob');
    final width = blob[0];
    final height = blob[1];
    final palette = blob[2] == 0xFF ? mesh16 : paletteById(blob[2]);
    final flags = blob[3];
    final encoding = _encodingFromFlags(flags);
    if (encoding == BodyEncoding.jpeg) {
      final photo = decodeJpegToArgb(blob.sublist(4));
      return DecodedImage(
        width: photo.width,
        height: photo.height,
        palette: palette,
        indices: const [],
        dithered: false,
        upgradeChunks: 0,
        argb: photo.argb,
      );
    }
    final bpp = _bppFromFlags(flags);
    final body = PackedBody(encoding, blob.sublist(4));
    final indices = decodeBody(
      body: body,
      count: width * height,
      bitsPerPixel: bpp,
    );
    return DecodedImage(
      width: width,
      height: height,
      palette: palette,
      indices: indices,
      dithered: _ditherFromFlags(flags),
      upgradeChunks: 0,
    );
  }

  Uint8List reassembleChunks(List<Uint8List?> parts) {
    final out = BytesBuilder(copy: false);
    for (final p in parts) {
      if (p == null) throw Mp1Exception('missing chunk during reassembly');
      out.add(p);
    }
    return out.takeBytes();
  }
}

int missingMaskFor(List<Uint8List?> parts) {
  var mask = 0;
  for (var i = 0; i < parts.length && i < 32; i++) {
    if (parts[i] == null) mask |= 1 << i;
  }
  return mask;
}

List<int> seqsFromMask(int mask, int total) {
  final seqs = <int>[];
  for (var i = 0; i < total && i < 32; i++) {
    if ((mask & (1 << i)) != 0) seqs.add(i);
  }
  return seqs;
}
