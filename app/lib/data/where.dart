import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../l10n.dart';

import 'game_db.dart';
import 'live_state.dart';
import 'shroud.dart';

/// Cold zones (assets/cold.png, built by tools/build_map.py from the game's temperature grid):
/// one pixel per 16 m, i.e. two map pixels (sized from the image).
class ColdMap {
  ColdMap._(this.values) : size = math.sqrt(values.length).round();
  final Uint8List values;

  /// Pixels across (half the map grid: 16 m a pixel).
  final int size;

  static Future<ColdMap> load() async {
    final data = await rootBundle.load('assets/cold.png');
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
    return ColdMap._(out);
  }

  /// Whether a map pixel lies in a cold zone.
  bool isCold(double x, double y) {
    final k = World.mapPx / size; // map pixels per cold pixel
    final ix = (x / k).floor(), iy = (y / k).floor();
    if (ix < 0 || iy < 0 || ix >= size || iy >= size) return false;
    return values[iy * size + ix] > 128;
  }

  /// RGBA overlay PNG (640 x 640): cold zones in pale blue.
  Uint8List overlay() {
    final rgba = Uint8List(size * size * 4);
    for (var i = 0; i < values.length; i++) {
      if (values[i] > 128) {
        rgba[i * 4] = 120;
        rgba[i * 4 + 1] = 190;
        rgba[i * 4 + 2] = 255;
        rgba[i * 4 + 3] = 70;
      }
    }
    return encodePng(rgba, size, size);
  }
}

/// The Shroud and cold maps, loaded once for the map and the shopping list.
class Terrain {
  Terrain(this.shroud, this.cold);
  final ShroudMap shroud;
  final ColdMap cold;
  static final Future<Terrain> instance = () async {
    final s = ShroudMap.load(), c = ColdMap.load();
    return Terrain(await s, await c);
  }();
}

/// A place to get an item: a gather cell, a chest, a fixed loot spot or a fishing spot.
class Spot {
  Spot({
    required this.x,
    required this.y,
    required this.kind,
    this.count = 0,
    this.areaLevel = 0,
    this.poi,
    this.mixed = false,
    this.zone,
    this.share,
  });
  final double x, y;

  /// A random container that gives one of several items.
  final bool mixed;

  /// A zone pin (kind 'zone'): the region, at one of its Ancient Spires or passages.
  final String? zone;

  /// Fishing spots: the item's share of the fish caught there (%).
  final double? share;

  /// gather, chest, unique, fish or zone.
  final String kind;
  final int count, areaLevel;
  final Poi? poi;
}

/// A spot with what it takes to get there: distance from a base, area level, Shroud, cold.
class RankedSpot {
  RankedSpot(
    this.spot, {
    required this.distanceM,
    this.base,
    this.shroudLevel,
    required this.shroudBlocked,
    required this.cold,
    required this.coldProtected,
    required this.levelGap,
    required this.score,
    this.rarity,
    this.odds,
    this.dropsLow = false,
    this.underwater = false,
    this.shroudHint = false,
  });
  final Spot spot;

  /// The item's hint says it's found underwater.
  final bool underwater;

  /// A zone pin for an item whose hint places it in the Shroud ("Kindlewastes Shroud").
  final bool shroudHint;
  final double distanceM;
  final String? base;

  /// Shroud level at the spot (null outside), and whether it is above your Flame level.
  final int? shroudLevel;
  final bool shroudBlocked;

  /// In a cold zone, and whether your Flame level already stops freezing.
  final bool cold, coldProtected;

  /// Area level minus your level (positive = tougher enemies).
  final int levelGap;
  final double score;

  /// Chests: the item's rarity and that rarity's drop odds there (%), and whether the area level
  /// is well below yours, so a level-scaled item would drop weak.
  final String? rarity;
  final double? odds;
  final bool dropsLow;

  /// 0 fine, 1 take care (Shroud you can enter, cold, tougher area), 2 blocked or much tougher.
  int get risk =>
      shroudBlocked || levelGap > 8
          ? 2
          : (shroudLevel != null ||
              (cold && !coldProtected) ||
              underwater ||
              shroudHint ||
              levelGap > 3)
          ? 1
          : 0;

  /// "1.4 km from Copper Camp · area level 22 · Shroud 3 · cold".
  String describe() => [
    if (spot.zone != null) tr('somewhere in {zone}', {'zone': gt(spot.zone!)}),
    if (base != null)
      base == 'you'
          ? tr('{distance} from you', {'distance': distanceText(distanceM)})
          : tr('{distance} from {base}', {
            'distance': distanceText(distanceM),
            'base': base,
          }),
    if (spot.areaLevel > 0)
      levelGap > 3
          ? tr('area level {n} (+{gap})', {
            'n': spot.areaLevel,
            'gap': levelGap,
          })
          : tr('area level {n}', {'n': spot.areaLevel}),
    if (shroudLevel != null)
      shroudBlocked
          ? tr('Shroud {n}: above your Flame', {'n': shroudLevel})
          : tr('Shroud {n}: timer runs', {'n': shroudLevel}),
    if (cold)
      coldProtected
          ? tr('cold (your Flame stops freezing)')
          : tr('cold: frost resistance'),
    if (spot.share != null)
      tr('fishing spot · {share}% of fish', {
        'share': spot.share!.toStringAsFixed(spot.share! < 10 ? 1 : 0),
      }),
    if (spot.count > 1)
      spot.mixed
          ? tr('{n} random containers', {'n': spot.count})
          : tr('{n} spots', {'n': spot.count}),
    if (spot.mixed && spot.count <= 1) tr('random container'),
    if (odds != null)
      tr('{rarity} {odds}%', {
        'rarity': gtn(rarity),
        'odds': odds!.toStringAsFixed(odds! < 10 ? 1 : 0),
      }),
    if (dropsLow) tr('drops at level {n}', {'n': spot.areaLevel}),
    if (underwater) tr('underwater: oxygen'),
    if (shroudHint && shroudLevel == null)
      spot.mixed ? tr('veins in the Shroud') : tr('in the Shroud'),
  ].join(' · ');
}

/// The eight compass points, as shown.
String _compass(int i) => switch (i) {
  0 => tr('north'),
  1 => tr('north-east'),
  2 => tr('east'),
  3 => tr('south-east'),
  4 => tr('south'),
  5 => tr('south-west'),
  6 => tr('west'),
  _ => tr('north-west'),
};

/// A compass point for a map direction (dx east, dy south, in map pixels).
/// "35 m", "340 m", "1.4 km": to 5 m up close, 10 m under a kilometre. Every distance in the app.
String distanceText(double m) =>
    m >= 1000
        ? tr('{n} km', {'n': (m / 1000).toStringAsFixed(1)})
        : m < 100
        ? tr('{n} m', {'n': (m / 5).round() * 5})
        : tr('{n} m', {'n': (m / 10).round() * 10});

String compassOf(double dx, double dy) {
  final deg = (math.atan2(dx, -dy) * 180 / math.pi) % 360;
  return _compass(((deg + 22.5) ~/ 45) % 8);
}

/// The base whose build box the player stands in, if any.
Base? baseAt(LiveState? state, PlayerPos p) {
  for (final b in state?.bases ?? const <Base>[]) {
    if (b.size.length == 3 &&
        (p.x - b.mapX).abs() * World.mPerPx * 2 <= b.size[0] / 2 &&
        (p.y - b.mapY).abs() * World.mPerPx * 2 <= b.size[2] / 2) {
      return b;
    }
  }
  return null;
}

/// The live position in words, relative to the nearest named place:
/// "107 m south-west of Flame Sanctum" and "1144 m up · 30 m above it".
class Whereabouts {
  factory Whereabouts(GameDb db, LiveState? state, PlayerPos p) {
    final base = baseAt(state, p);
    if (base != null) {
      return Whereabouts._(p, tr('In {base}', {'base': base.label}), null);
    }
    Poi? best;
    var bestD = double.infinity;
    for (final q in db.poi) {
      if (q.cat != 'label') continue;
      final dx = q.x - p.x, dy = q.y - p.y;
      final d = dx * dx + dy * dy;
      if (d < bestD) (best, bestD) = (q, d);
    }
    if (best == null) return Whereabouts._(p, tr('Live position'), null);
    final m = math.sqrt(bestD) * World.mPerPx;
    final text =
        m < 20
            ? tr('At {place}', {'place': gt(best.title)})
            : tr('{distance} {direction} of {place}', {
              'distance': _distance(m),
              'direction': compassOf(p.x - best.x, p.y - best.y),
              'place': gt(best.title),
            });
    return Whereabouts._(p, text, best);
  }

  Whereabouts._(this.pos, this.text, this.place);
  final PlayerPos pos;

  /// "107 m south-west of Flame Sanctum", "At Flame Shrine", "In Lakeside Keep".
  final String text;

  /// The place it is measured from (null inside a base).
  final Poi? place;

  /// "1144 m up · 30 m above it".
  String get height {
    final h = place?.height;
    final up = tr('{n} m up', {'n': pos.height.round()});
    if (h == null) return up;
    final diff = (pos.height - h).round();
    if (diff.abs() < 3) return '$up · ${tr('level with it')}';
    return '$up · ${diff > 0 ? tr('{n} m above it', {'n': diff.abs()}) : tr('{n} m below it', {'n': diff.abs()})}';
  }

  static String _distance(double m) => distanceText(m);
}

/// Where to get an item, best places first, for this character.
class WhereToGet {
  WhereToGet(this.db, this.state, this.terrain, {this.here});
  final GameDb db;
  final LiveState? state;
  final Terrain? terrain;

  /// Where the player stands right now (live from the game): distances count from here too.
  final PlayerPos? here;

  int get flame => state?.flameLevel ?? 0;
  int get level => state?.level ?? 0;
  bool get coldProtected => flame >= (db.balancing?.noFreezeFlameLevel ?? 99);

  /// Every candidate place: gather cells, fixed loot spots, chests whose pool holds the item, the bosses
  /// dropping a trophy head.
  List<Spot> spots(String itemId) {
    final item = db.items[itemId];
    final regions = item?.regions ?? const <String>[];
    var out = _spots(itemId);
    // random containers give one of several items: keep those in the regions the hint names
    if (regions.isNotEmpty && (item?.gatherMixed ?? false)) {
      out = [
        for (final s in out)
          if (s.kind != 'gather' || regions.contains(db.regionAt(s.x, s.y))) s,
      ];
    }
    // nothing mapped: a pin per region the hint names, at its Ancient Spires and passages
    if (out.isEmpty) {
      for (final r in regions) {
        for (final (x, y, title)
            in db.regionAnchors[r] ?? const <(double, double, String)>[]) {
          out.add(
            Spot(
              x: x,
              y: y,
              kind: 'zone',
              zone: r,
              poi: Poi({
                'c': 'spot',
                'k': tr('Zone: {zone}', {'zone': gt(r)}),
                't': title,
                'x': x,
                'y': y,
                'i': itemId,
              }),
            ),
          );
        }
      }
    }
    return out;
  }

  List<Spot> _spots(String itemId) => [
    for (final c in db.gather[itemId] ?? const <GatherCell>[])
      Spot(
        x: c.x,
        y: c.y,
        kind: 'gather',
        count: c.count,
        areaLevel: c.areaLevel,
        mixed: db.items[itemId]?.gatherMixed ?? false,
      ),
    for (final p in db.uniqueSpots(itemId))
      Spot(x: p.x, y: p.y, kind: 'unique', areaLevel: p.areaLevel, poi: p),
    for (final p in db.bossSpots(itemId))
      Spot(x: p.x, y: p.y, kind: 'boss', areaLevel: p.areaLevel, poi: p),
    for (final p in db.poi)
      if (p.lootSetting != null &&
          (db.loot[p.lootSetting]?.pool.contains(itemId) ?? false))
        Spot(x: p.x, y: p.y, kind: 'chest', areaLevel: p.areaLevel, poi: p)
      else if (db.fish[p.fishTable]?.fish.where((f) => f.id == itemId)
          case final f? when f.isNotEmpty)
        Spot(
          x: p.x,
          y: p.y,
          kind: 'fish',
          areaLevel: p.areaLevel,
          poi: p,
          share: f.first.share,
        ),
  ];

  RankedSpot rank(Spot s, {Item? item}) {
    // nearest base, in metres (a fog-map pixel is 8 m)
    var best = double.infinity;
    String? base;
    for (final b in state?.bases ?? const <Base>[]) {
      final d =
          math.sqrt(math.pow(b.mapX - s.x, 2) + math.pow(b.mapY - s.y, 2)) *
          World.mPerPx;
      if (d < best) (best, base) = (d, b.label);
    }
    if (here case final h?) {
      final d =
          math.sqrt(math.pow(h.x - s.x, 2) + math.pow(h.y - s.y, 2)) *
          World.mPerPx;
      if (d < best) (best, base) = (d, 'you');
    }
    final shroud = terrain?.shroud.levelAt(s.x, s.y);
    final cold = terrain?.cold.isCold(s.x, s.y) ?? false;
    final gap = s.areaLevel == 0 || level == 0 ? 0 : s.areaLevel - level;
    final blocked = shroud != null && shroud > flame;
    var score = best.isFinite ? best / 1000 : 5.0;
    if (shroud != null) score += blocked ? 100 : 1.5;
    if (cold && !coldProtected) score += 2;
    if (gap > 3) score += gap > 8 ? 20 : gap * 0.4;
    if (s.kind == 'gather') score -= math.min(math.log(s.count + 1) * 0.3, 1.2);
    if (s.mixed) score += 1; // one of several items, so a few tries
    if (s.kind == 'zone') score += 3; // a region, not a spot
    // a few casts for the spot's commonest fish, many for a rare one
    if (s.share case final f?) {
      final top = db.fish[s.poi?.fishTable]?.fish.first.share ?? f;
      score += 0.5 + 2 * (1 - (f / top).clamp(0.0, 1.0));
    }
    double? odds;
    var low = false;
    if (s.kind == 'chest') {
      score += 0.5; // a chance, not a sure thing
      final setting = db.loot[s.poi?.lootSetting];
      final ri = LootSetting.rarities.indexOf(item?.rarity ?? '');
      if (setting != null && ri >= 0) {
        odds = setting.odds[ri];
        score += odds <= 0 ? 5 : 2 * (1 - (odds / 100).clamp(0.0, 1.0));
      }
      // a level-scaled item drops at the chest's area level
      final lv = item?.stats?.levels;
      if (lv != null &&
          lv[0] != lv[1] &&
          s.areaLevel > 0 &&
          level > 0 &&
          s.areaLevel < level - 5) {
        low = true;
        score += (level - s.areaLevel) * 0.15;
      }
      // a fixed-level item mostly drops where the area level is close to its own
      if (lv != null &&
          lv[0] == lv[1] &&
          s.areaLevel > 0 &&
          (lv[1] - s.areaLevel).abs() > 10) {
        score += 2.5;
      }
    }
    return RankedSpot(
      s,
      distanceM: best.isFinite ? best : 0,
      base: base,
      shroudLevel: shroud,
      shroudBlocked: blocked,
      cold: cold,
      coldProtected: coldProtected,
      levelGap: gap,
      score: score,
      rarity: odds == null ? null : item?.rarity,
      odds: odds,
      dropsLow: low,
      underwater: item?.underwater ?? false,
      // the hint is about where it really comes from: a zone, or the veins behind random ore carts
      shroudHint: (item?.inShroud ?? false) && (s.kind == 'zone' || s.mixed),
    );
  }

  /// The best places for an item, safest and nearest first.
  List<RankedSpot> best(String itemId, {int count = 3}) {
    final item = db.items[itemId];
    final ranked = [for (final s in spots(itemId)) rank(s, item: item)]
      ..sort((a, b) => a.score.compareTo(b.score));
    return ranked.take(count).toList();
  }

  /// A map point for one ranked spot, to focus the map on it.
  Poi asPoi(String itemId, RankedSpot r) =>
      r.spot.poi ??
      Poi({
        'c': 'spot',
        'k': r.describe(),
        't': db.items[itemId]?.name ?? itemId,
        'x': r.spot.x,
        'y': r.spot.y,
        'i': itemId,
      });
}
