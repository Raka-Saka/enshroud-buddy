import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Estimated Shroud level per fog-map pixel (assets/shroud_levels.png, built by tools/build_map.py):
/// 0 = no Shroud, otherwise level + 1.
class ShroudMap {
  ShroudMap._(this.levels) : size = math.sqrt(levels.length).round();
  final Uint8List levels; // one per map pixel

  /// Pixels across (the map grid).
  final int size;

  static Future<ShroudMap> load() async {
    final data = await rootBundle.load('assets/shroud_levels.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final image = (await codec.getNextFrame()).image;
    final rgba =
        (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
    final out = Uint8List(image.width * image.height);
    for (var i = 0; i < out.length; i++) {
      out[i] = rgba[i * 4];
    }
    return ShroudMap._(out);
  }

  /// Shroud level at a fog-map pixel, or null outside the Shroud.
  int? levelAt(double x, double y) {
    final ix = x.floor(), iy = y.floor();
    if (ix < 0 || iy < 0 || ix >= size || iy >= size) return null;
    final v = levels[iy * size + ix];
    return v == 0 ? null : v - 1;
  }

  /// RGBA overlay PNG: zones you can enter in violet, zones above [passage] in red.
  Uint8List overlay(int passage) {
    final rgba = Uint8List(size * size * 4);
    for (var i = 0; i < levels.length; i++) {
      final v = levels[i];
      if (v == 0) continue;
      final above = v - 1 > passage;
      rgba[i * 4] = above ? 0xE0 : 0x9A;
      rgba[i * 4 + 1] = above ? 0x30 : 0x5C;
      rgba[i * 4 + 2] = above ? 0x30 : 0xD6;
      rgba[i * 4 + 3] = above ? 0x9C : 0x70;
    }
    return encodePng(rgba, size, size);
  }
}

/// Minimal PNG encoder (RGBA, filter 0) so overlays need no extra package.
Uint8List encodePng(Uint8List rgba, int w, int h) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    raw.add(Uint8List.sublistView(rgba, y * w * 4, (y + 1) * w * 4));
  }
  final out =
      BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final t = type.codeUnits;
    out.add(_u32(data.length));
    out.add(t);
    out.add(data);
    out.add(_u32(_crc32([...t, ...data])));
  }

  chunk('IHDR', [..._u32(w), ..._u32(h), 8, 6, 0, 0, 0]);
  final pixels = raw.takeBytes();
  chunk(
    'IDAT',
    kIsWeb ? _stored(pixels) : ZLibEncoder(level: 6).convert(pixels),
  );
  chunk('IEND', const []);
  return out.takeBytes();
}

/// zlib data in stored (uncompressed) blocks: a browser has no ZLibEncoder, and these images only live in
/// memory.
Uint8List _stored(Uint8List data) {
  final out = BytesBuilder()..add(const [0x78, 0x01]);
  var a = 1, b = 0;
  for (final v in data) {
    a = (a + v) % 65521;
    b = (b + a) % 65521;
  }
  for (var i = 0; i == 0 || i < data.length; i += 65535) {
    final n = (data.length - i).clamp(0, 65535);
    out
      ..addByte(i + n >= data.length ? 1 : 0)
      ..add([n & 0xFF, n >> 8, ~n & 0xFF, (~n >> 8) & 0xFF])
      ..add(Uint8List.sublistView(data, i, i + n));
  }
  out.add(_u32((b << 16) | a));
  return out.takeBytes();
}

List<int> _u32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
