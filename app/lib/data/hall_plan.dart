import 'dart:math' as math;
import 'dart:typed_data';

import 'shroud.dart' show encodePng;

/// A Hollow Hall's rooms as a floor plan, from the objects placed in them (HallLayout's points): on a grid of
/// 2 m cells, every cell with an object, closed over gaps (spread [reach] cells on square windows, then
/// shrunk by [back]), so rooms and corridors read as floor instead of scattered dots. A PNG over the hall's
/// box: without a floor, the top floor's height shades it (higher is lighter) in the hall's colour; with
/// one, the rooms within a few metres of it are bright, nearer floors dim, the rest faint.
class HallPlan {
  HallPlan(this.png, this.x0, this.y0, this.x1, this.y1);
  final Uint8List png;

  /// The image's corners in map px.
  final double x0, y0, x1, y1;

  /// Map px per cell: 2 m.
  static const cell = 0.25;

  /// Cells a room spreads over gaps, and shrinks back after: objects up to about 28 m apart join up.
  static const reach = 7, back = 6;

  /// Metres off the floor that count as on it, and as near it.
  static const onFloor = 6, nearFloor = 16;

  /// [points] as HallLayout's (x, y in tenths of a map px, height in metres, hall), stride 4; [box] the
  /// hall's (x0, y0, x1, y1) in map px; [floor] the player's height or null. Colours as ARGB: [color] the
  /// hall's (outlines; the fill without a floor), [ground] the low end of that fill, [on], [near] and [far]
  /// the floors with one.
  static HallPlan build(
    Int32List points,
    int hall,
    List<double> box,
    double? floor, {
    required int color,
    required int ground,
    required int on,
    required int near,
    required int far,
  }) {
    const pad = reach + 1;
    final w = ((box[2] - box[0]) / cell).ceil() + 2 * pad;
    final h = ((box[3] - box[1]) / cell).ceil() + 2 * pad;
    final gx0 = box[0] - pad * cell, gy0 = box[1] - pad * cell;
    // layers, most faint first: everything; then near the floor, and on it
    final layers = [
      for (var i = 0; i < (floor == null ? 1 : 3); i++) Uint8List(w * h),
    ];
    final top = Int16List(w * h)..fillRange(0, w * h, -1);
    var lo = 1 << 14, hi = -1;
    for (var i = 0; i + 3 < points.length; i += 4) {
      if (points[i + 3] != hall) continue;
      final cx = ((points[i] / 10 - gx0) / cell).floor();
      final cy = ((points[i + 1] / 10 - gy0) / cell).floor();
      if (cx < 0 || cy < 0 || cx >= w || cy >= h) continue;
      final at = cy * w + cx, z = points[i + 2];
      layers[0][at] = 1;
      if (floor != null) {
        final d = (z - floor).abs();
        if (d <= nearFloor) layers[1][at] = 1;
        if (d <= onFloor) layers[2][at] = 1;
      }
      if (z > top[at]) top[at] = z;
      lo = math.min(lo, z);
      hi = math.max(hi, z);
    }
    final filled = [for (final l in layers) _close(l, w, h)];
    final height = floor == null ? _spreadMax(top, w, h) : null;

    final rgba = Uint8List(w * h * 4);
    void put(int at, int argb, double alpha) {
      final a = ((argb >> 24 & 0xFF) * alpha).round();
      rgba[at * 4] = argb >> 16 & 0xFF;
      rgba[at * 4 + 1] = argb >> 8 & 0xFF;
      rgba[at * 4 + 2] = argb & 0xFF;
      rgba[at * 4 + 3] = a;
    }

    bool edge(Uint8List m, int x, int y) =>
        x == 0 ||
        y == 0 ||
        x == w - 1 ||
        y == h - 1 ||
        m[y * w + x - 1] == 0 ||
        m[y * w + x + 1] == 0 ||
        m[(y - 1) * w + x] == 0 ||
        m[(y + 1) * w + x] == 0;

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final at = y * w + x;
        if (floor == null) {
          if (filled[0][at] == 0) continue;
          final t =
              hi > lo ? ((height![at] - lo) / (hi - lo)).clamp(0.0, 1.0) : 1.0;
          put(
            at,
            edge(filled[0], x, y) ? color : _mix(ground, color, 0.35 + 0.5 * t),
            edge(filled[0], x, y) ? 0.95 : 0.85,
          );
        } else if (filled[2][at] != 0) {
          put(at, edge(filled[2], x, y) ? color : on, 0.9);
        } else if (filled[1][at] != 0) {
          put(at, near, 0.32);
        } else if (filled[0][at] != 0) {
          put(at, far, 0.14);
        }
      }
    }
    return HallPlan(
      encodePng(rgba, w, h),
      gx0,
      gy0,
      gx0 + w * cell,
      gy0 + h * cell,
    );
  }

  static int _mix(int a, int b, double t) {
    int ch(int s) =>
        ((a >> s & 0xFF) + ((b >> s & 0xFF) - (a >> s & 0xFF)) * t).round();
    return 0xFF000000 | ch(16) << 16 | ch(8) << 8 | ch(0);
  }

  /// Closing on square windows: any object within [reach] cells, then all within [back] of that.
  static Uint8List _close(Uint8List m, int w, int h) =>
      _window(_window(m, w, h, reach, any: true), w, h, back, any: false);

  /// Per cell, whether any (or every) cell of the (2r+1)² square around it is set: rows, then columns,
  /// each with running counts.
  static Uint8List _window(
    Uint8List m,
    int w,
    int h,
    int r, {
    required bool any,
  }) {
    final full = 2 * r + 1;
    bool keep(int n) => any ? n > 0 : n == full;
    final rows = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      var n = 0;
      for (var x = -r; x < w; x++) {
        final add = x + r, drop = x - r - 1;
        if (add < w && m[y * w + add] != 0) n++;
        if (drop >= 0 && m[y * w + drop] != 0) n--;
        if (x >= 0 && keep(n)) rows[y * w + x] = 1;
      }
    }
    final out = Uint8List(w * h);
    for (var x = 0; x < w; x++) {
      var n = 0;
      for (var y = -r; y < h; y++) {
        final add = y + r, drop = y - r - 1;
        if (add < h && rows[add * w + x] != 0) n++;
        if (drop >= 0 && rows[drop * w + x] != 0) n--;
        if (y >= 0 && keep(n)) out[y * w + x] = 1;
      }
    }
    return out;
  }

  /// The highest height within [reach] cells, so filled gaps take their room's floor.
  static Int16List _spreadMax(Int16List v, int w, int h) {
    final rows = Int16List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var m = -1;
        for (
          var d = math.max(0, x - reach);
          d <= math.min(w - 1, x + reach);
          d++
        ) {
          m = math.max(m, v[y * w + d]);
        }
        rows[y * w + x] = m;
      }
    }
    final out = Int16List(w * h);
    for (var x = 0; x < w; x++) {
      for (var y = 0; y < h; y++) {
        var m = -1;
        for (
          var d = math.max(0, y - reach);
          d <= math.min(h - 1, y + reach);
          d++
        ) {
          m = math.max(m, rows[d * w + x]);
        }
        out[y * w + x] = m;
      }
    }
    return out;
  }
}
