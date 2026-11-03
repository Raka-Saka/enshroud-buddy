import 'dart:math' as math;

import 'game_db.dart';
import 'where.dart';

/// One stop of a farming run: a place and what to get there.
class FarmStop {
  FarmStop(this.spot, this.items);
  final RankedSpot spot;

  /// Item ids to get here, with how many.
  final Map<String, int> items;

  double get x => spot.spot.x;
  double get y => spot.spot.y;
}

/// A farming run for a shopping list: the best place for each item (shared when one place has several),
/// in the order that walks the least, starting where you are.
class FarmRoute {
  FarmRoute(this.stops, this.skipped);

  final List<FarmStop> stops;

  /// Items with no place you can reach yet (Shroud above your Flame, far too tough).
  final List<String> skipped;

  /// Places closer than this count as one stop (metres).
  static const shareM = 60.0;

  static FarmRoute plan(
    WhereToGet where,
    Map<String, int> need, {
    required double fromX,
    required double fromY,
  }) {
    final stops = <FarmStop>[];
    final skipped = <String>[];
    double metres(double x0, double y0, double x1, double y1) =>
        math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2)) * World.mPerPx;
    // items with the fewest good places first, so the rest can join their stops
    final ranked = {
      for (final id in need.keys)
        id: where.best(id, count: 4).where((r) => r.risk < 2).toList(),
    };
    final order =
        need.keys.toList()
          ..sort((a, b) => ranked[a]!.length.compareTo(ranked[b]!.length));
    for (final id in order) {
      final options = ranked[id]!;
      if (options.isEmpty) {
        skipped.add(id);
        continue;
      }
      // a stop already planned within reach, if its place is nearly as good as the best one
      FarmStop? join;
      for (final r in options) {
        if (r.score > options.first.score + 1) break;
        for (final s in stops) {
          if (metres(s.x, s.y, r.spot.x, r.spot.y) <= shareM) join = s;
        }
        if (join != null) break;
      }
      if (join != null) {
        join.items[id] = need[id]!;
      } else {
        stops.add(FarmStop(options.first, {id: need[id]!}));
      }
    }
    return FarmRoute(_order(stops, fromX, fromY), skipped);
  }

  /// Nearest stop next, then 2-opt swaps while they shorten the walk.
  static List<FarmStop> _order(List<FarmStop> stops, double x, double y) {
    final left = [...stops];
    final out = <FarmStop>[];
    var cx = x, cy = y;
    while (left.isNotEmpty) {
      left.sort(
        (a, b) => (math.pow(a.x - cx, 2) + math.pow(a.y - cy, 2)).compareTo(
          math.pow(b.x - cx, 2) + math.pow(b.y - cy, 2),
        ),
      );
      final s = left.removeAt(0);
      out.add(s);
      (cx, cy) = (s.x, s.y);
    }
    double d(int i, int j) {
      final (ax, ay) = i < 0 ? (x, y) : (out[i].x, out[i].y);
      final (bx, by) = (out[j].x, out[j].y);
      return math.sqrt(math.pow(bx - ax, 2) + math.pow(by - ay, 2));
    }

    var better = true;
    while (better) {
      better = false;
      for (var i = 0; i < out.length - 1; i++) {
        for (var j = i + 1; j < out.length; j++) {
          // reverse out[i..j]: the legs into i and out of j change
          final before = d(i - 1, i) + (j + 1 < out.length ? d(j, j + 1) : 0);
          final after = d(i - 1, j) + (j + 1 < out.length ? d(i, j + 1) : 0);
          if (after + 1e-9 < before) {
            final seg = out.sublist(i, j + 1).reversed.toList();
            out.replaceRange(i, j + 1, seg);
            better = true;
          }
        }
      }
    }
    return out;
  }

  /// The walk in metres from the start through every stop.
  double lengthFrom(double x, double y) {
    var total = 0.0;
    for (final s in stops) {
      total +=
          math.sqrt(math.pow(s.x - x, 2) + math.pow(s.y - y, 2)) * World.mPerPx;
      (x, y) = (s.x, s.y);
    }
    return total;
  }
}
