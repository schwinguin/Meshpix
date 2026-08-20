import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshpix/codec/limits.dart';
import 'package:meshpix/codec/mp1.dart';
import 'package:meshpix/codec/packer.dart';
import 'package:meshpix/codec/rgba.dart';

void main() {
  final codec = Mp1Codec();
  final src = makeTestCard(96);

  test('24x24 2bpp preview always fits in 163 bytes', () {
    final encoded = codec.encode(
      src,
      options: const EncodeOptions(
        fourColorPreview: true,
        includeUpgrade: false,
        transferId: 7,
      ),
    );
    expect(encoded.preview.bytes.length, lessThanOrEqualTo(kMaxDatagramPayload));
    expect(encoded.stats.previewWidth, 24);
    expect(encoded.stats.previewBpp, 2);
    expect(encoded.chunks, isEmpty);
  });

  test('16x16 4bpp preview fits when requested', () {
    final encoded = codec.encode(
      src,
      options: const EncodeOptions(
        fourColorPreview: false,
        includeUpgrade: false,
        previewSize: 16,
        transferId: 8,
      ),
    );
    expect(encoded.preview.bytes.length, lessThanOrEqualTo(kMaxDatagramPayload));
    final parsed = codec.parse(encoded.preview.bytes) as PreviewPacket;
    expect(parsed.image.indices.length, parsed.image.width * parsed.image.height);
    expect(parsed.image.indices.every((i) => i >= 0 && i < 16), isTrue);
  });

  test('preview roundtrip restores dimensions and palette', () {
    final encoded = codec.encode(
      src,
      options: const EncodeOptions(includeUpgrade: false, transferId: 9),
    );
    final parsed = codec.parse(encoded.preview.bytes) as PreviewPacket;
    expect(parsed.transferId, 9);
    expect(parsed.image.width, encoded.preview.image.width);
    expect(parsed.image.height, encoded.preview.image.height);
    expect(parsed.image.indices, encoded.preview.image.indices);
  });

  test('upgrade defaults to a JPEG photo within 32 chunks', () {
    final encoded = codec.encode(
      src,
      options: const EncodeOptions(
        includeUpgrade: true,
        fourColorPreview: true,
        transferId: 42,
      ),
    );
    expect(encoded.stats.upgradeEncoding, BodyEncoding.jpeg);
    expect(encoded.stats.upgradeWidth, greaterThanOrEqualTo(96));
    expect(encoded.chunks.length, greaterThan(0));
    expect(encoded.chunks.length, lessThanOrEqualTo(kMaxUpgradeChunks));
    for (final c in encoded.chunks) {
      expect(c.bytes.length, lessThanOrEqualTo(kMaxDatagramPayload));
    }
    final parts = encoded.chunks.map((c) => c.slice).toList();
    final blob = codec.reassembleChunks(parts);
    expect(blob, encoded.upgradeBlob);
    final image = codec.decodeUpgradeBlob(blob);
    expect(image.isPhoto, isTrue);
    expect(image.width, encoded.stats.upgradeWidth);
    expect(image.height, encoded.stats.upgradeHeight);
    expect(image.toArgb().length, image.width * image.height);
  });

  test('indexed 96px upgrade still works when JPEG is disabled', () {
    final encoded = codec.encode(
      src,
      options: const EncodeOptions(
        includeUpgrade: true,
        jpegUpgrade: false,
        fourColorPreview: true,
        transferId: 44,
      ),
    );
    expect(encoded.stats.upgradeWidth, 96);
    expect(encoded.stats.upgradeEncoding, isNot(BodyEncoding.jpeg));
    final image = codec.decodeUpgradeBlob(
      codec.reassembleChunks(encoded.chunks.map((c) => c.slice).toList()),
    );
    expect(image.isPhoto, isFalse);
    expect(image.indices.length, 96 * 96);
  });

  test('encode still succeeds if upgrade cannot fit', () {
    final encoded = codec.encode(
      src,
      options: const EncodeOptions(
        includeUpgrade: true,
        maxChunks: 0,
        transferId: 43,
      ),
    );
    expect(encoded.chunks, isEmpty);
    expect(encoded.preview.bytes.length, lessThanOrEqualTo(kMaxDatagramPayload));
    expect(encoded.stats.previewWidth, greaterThan(0));
  });

  test('nack bitmap lists missing sequences', () {
    final parts = <Uint8List?>[Uint8List(1), null, Uint8List(1), null];
    final mask = missingMaskFor(parts);
    expect(seqsFromMask(mask, 4), [1, 3]);
    final pkt = codec.nack(99, mask);
    final parsed = codec.parse(pkt.bytes) as NackPacket;
    expect(parsed.missingMask, mask);
    expect(parsed.bytes.length, lessThanOrEqualTo(kMaxDatagramPayload));
  });

  test('nack bitmap covers chunks beyond 16', () {
    final parts = List<Uint8List?>.filled(24, Uint8List(1));
    parts[20] = null;
    final mask = missingMaskFor(parts);
    expect(seqsFromMask(mask, 24), [20]);
    final parsed = codec.parse(codec.nack(5, mask).bytes) as NackPacket;
    expect(parsed.missingMask, mask);
    expect(parsed.bytes.length, 10);
  });

  test('legacy 16-bit nack packets still parse', () {
    final bytes = Uint8List.fromList([
      kMp1Magic0,
      kMp1Magic1,
      kMp1Version,
      0x03, // kind nack
      1,
      0,
      0x04,
      0x00,
    ]);
    final parsed = codec.parse(bytes) as NackPacket;
    expect(parsed.missingMask, 0x04);
  });

  test('truncated packets throw instead of crashing', () {
    expect(() => codec.parse(Uint8List.fromList([1, 2, 3])), throwsA(isA<Mp1Exception>()));
    expect(
      () => codec.parse(Uint8List.fromList([kMp1Magic0, kMp1Magic1, kMp1Version, 0, 0, 0])),
      throwsA(isA<Mp1Exception>()),
    );
  });

  test('oversized packets are rejected', () {
    final huge = Uint8List(kMaxDatagramPayload + 4);
    huge[0] = kMp1Magic0;
    huge[1] = kMp1Magic1;
    huge[2] = kMp1Version;
    expect(() => codec.parse(huge), throwsA(isA<Mp1Exception>()));
  });

  test('pack/unpack 2bpp and 4bpp', () {
    final idx = List<int>.generate(16, (i) => i % 4);
    final packed = packIndices(idx, 2);
    expect(unpackIndices(packed, 16, 2), idx);
    final idx4 = List<int>.generate(16, (i) => i % 16);
    expect(unpackIndices(packIndices(idx4, 4), 16, 4), idx4);
  });
}
