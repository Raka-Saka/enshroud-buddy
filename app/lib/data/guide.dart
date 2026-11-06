import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';

import 'game_db.dart';
import 'live_state.dart';
import 'where.dart' show compassOf, distanceText;
import 'background.dart';

/// Ground height from the game's own map (assets/height.png, written by tools/build_map.py): one value per
/// map pixel (World.mPerPx metres), in steps of about 16 m, so a few metres off at best (fitted: median 5 m).
class HeightMap {
  HeightMap._(this.values, this.perStep, this.offset)
    : size = math.sqrt(values.length).round();
  final Uint8List values;
  final double perStep, offset;

  /// Pixels across (the map grid).
  final int size;

  static Future<HeightMap?> load() async {
    try {
      final fit =
          jsonDecode(await rootBundle.loadString('assets/height.json'))
              as Map<String, dynamic>;
      final data = await rootBundle.load('assets/height.png');
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
      return HeightMap._(
        out,
        (fit['m_per_step'] as num).toDouble(),
        (fit['offset_m'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  static final Future<HeightMap?> instance = load();

  @visibleForTesting
  HeightMap.test(this.values, this.perStep, this.offset)
    : size = math.sqrt(values.length).round();

  /// Metres above the game's zero at a map pixel, between texel centres.
  double at(double x, double y) {
    final u = (x - 0.5).clamp(0.0, size - 1.001),
        v = (y - 0.5).clamp(0.0, size - 1.001);
    final u0 = u.floor(), v0 = v.floor();
    final fu = u - u0, fv = v - v0;
    double h(int i, int j) => values[j * size + i].toDouble();
    final raw =
        h(u0, v0) * (1 - fu) * (1 - fv) +
        h(u0 + 1, v0) * fu * (1 - fv) +
        h(u0, v0 + 1) * (1 - fu) * fv +
        h(u0 + 1, v0 + 1) * fu * fv;
    return raw * perStep + offset;
  }
}

/// Where the guide leads: a map place, a shopping spot or a pin.
class NavTarget {
  const NavTarget(this.title, this.x, this.y, {this.height});
  NavTarget.poi(Poi p) : this(p.title, p.x, p.y, height: p.height);
  final String title;
  final double x, y;

  /// Metres, when the place has one; otherwise the ground there.
  final double? height;
}

/// The place the guide is leading to, if any (set from a place's sheet, cleared on the map).
final navTarget = ValueNotifier<NavTarget?>(null);

/// The equipped glider and what it costs: speed and stamina from the item, Airborne's saving from the
/// skill tree, how far it carries per metre of height from the player's own glides once measured.
class Glider {
  Glider({
    required this.name,
    required this.speed,
    required this.drain,
    required this.saving,
    required this.ratio,
    required this.measured,
  });
  final String name;

  /// Metres a second, stamina a second (before Airborne), Airborne's saving (0..1).
  final double speed, drain, saving;

  /// Metres across per metre of height lost.
  final double ratio;

  /// Whether [ratio] comes from the player's own glides rather than an estimate.
  final bool measured;

  /// Before any glide is measured: 3 m per metre for the first glider, scaled by Range.
  static const _baseRatio = 3.0;

  static Glider? of(GameDb db, LiveState? s, PlayerPos? p) {
    final worn = s?.equipment.map((o) => db.items[o.itemId]);
    final item = worn?.firstWhere(
      (i) => i?.stats?.slot == 'Glider',
      orElse: () => null,
    );
    if (item == null) return null;
    double stat(String label) {
      for (final (k, v) in item.stats!.values) {
        if (k == label) return double.tryParse(v.replaceAll('%', '')) ?? 0;
      }
      return 0;
    }

    var saving = 0.0;
    for (final k in db.skills) {
      if (k.name != 'Airborne') continue;
      final rank = s?.skills[k.id] ?? 0;
      final per = RegExp(r'(\d+)%').firstMatch(k.perLevel ?? '');
      if (per != null) saving = rank * int.parse(per[1]!) / 100;
    }
    final range = stat('Range');
    final glide = p?.glide;
    return Glider(
      name: item.name,
      speed: glide?.speed ?? stat('Speed'),
      drain: stat('Stamina per Second'),
      saving: saving.clamp(0.0, 0.9),
      ratio: glide?.ratio ?? _baseRatio * (range > 0 ? range / 100 : 1),
      measured: glide != null,
    );
  }
}

/// Can the player glide to the target from where they are? Follows the ground along the straight line
/// (the game's height map), keeping a margin for turbulence and the map's coarse steps.
class GlideCheck {
  GlideCheck._({
    required this.reaches,
    required this.carriesM,
    required this.walkM,
    required this.seconds,
    required this.stamina,
    required this.climbFirst,
    required this.spareM,
    required this.measured,
  });

  /// Metres of clearance kept over the ground, and the share of the ratio kept for turbulence.
  static const clearance = 8.0, turbulence = 0.85;

  /// The camera sits about this far above the character's feet.
  static const cameraHeight = 3.0;

  /// Clearance kept [d] metres out: a little at the jump, the full margin from 100 m on.
  static double margin(double d) => math.min(clearance, 2 + d / 16);

  final bool reaches, measured;

  /// Metres across the glide covers, and what is left to walk.
  final double carriesM, walkM;
  final double seconds, stamina;

  /// Metres more height that would carry it all the way (0 when it already does, null when no height
  /// would, e.g. the target is up a cliff that blocks the line).
  final double? climbFirst;

  /// Metres above the target's ground on arrival (negative when it falls short).
  final double spareM;

  static GlideCheck? of(PlayerPos p, NavTarget t, HeightMap hm, Glider g) =>
      from(p.x, p.y, p.height - cameraHeight, t.x, t.y, hm, g);

  /// From map point ([x], [y]) with the feet at [start] metres, to ([tx], [ty]).
  static GlideCheck? from(
    double x,
    double y,
    double start,
    double tx,
    double ty,
    HeightMap hm,
    Glider g,
  ) {
    final dx = tx - x, dy = ty - y;
    final px = World.mPerPx;
    final distM = math.sqrt(dx * dx + dy * dy) * px;
    if (distM < 40 || g.ratio <= 0 || g.speed <= 0) return null;
    final ratio = g.ratio * turbulence;
    // land on the ground there: a spire's platform (130 m up) is climbed, a dungeon is below ground
    final targetH = hm.at(tx, ty);
    final steps = (distM / px).ceil(); // one map pixel a step
    double? landsAt;
    var need =
        targetH +
        distM / ratio; // start height that arrives level with the target
    for (var i = 1; i <= steps; i++) {
      final d = math.min(i * px, distM);
      final f = d / distM;
      final ground = hm.at(x + dx * f, y + dy * f);
      // the last stretch is the landing: only the target's own height counts there
      if (d < distM - 16) {
        need = math.max(need, ground + margin(d) + d / ratio);
        if (landsAt == null && start - d / ratio < ground + margin(d))
          landsAt = d;
      }
    }
    final spare = start - distM / ratio - targetH;
    final reaches = landsAt == null && spare >= -1;
    final carries = reaches ? distM : (landsAt ?? distM);
    final secs = carries / g.speed;
    return GlideCheck._(
      reaches: reaches,
      carriesM: carries,
      walkM: distM - carries,
      seconds: secs,
      stamina: secs * g.drain * (1 - g.saving),
      climbFirst: math.max(0, need - start),
      spareM: spare,
      measured: g.measured,
    );
  }

  /// "Glide all the way: 34 s, about 140 stamina" / "Glide 620 m, then walk 280 m · 40 m higher would do it".
  String describe() {
    final cost = tr('{s} s, about {stamina} stamina', {
      's': seconds.round(),
      'stamina': (stamina / 5).round() * 5,
    });
    final est = measured ? '' : ' ${tr('(estimate until you glide a bit)')}';
    if (reaches)
      return '${tr('Glide all the way: {cost}', {'cost': cost})}$est';
    if (carriesM < 30) {
      final drop =
          (climbFirst ?? 0) > 0
              ? tr('No drop to glide from here: {n} m higher would do it', {
                'n': climbFirst!.round(),
              })
              : tr('No drop to glide from here');
      return '$drop$est';
    }
    final more =
        (climbFirst ?? 0) > 0
            ? ' · ${tr('{n} m higher would do it', {'n': climbFirst!.round()})}'
            : '';
    final go = tr('Glide {glide} ({cost}), then walk {walk}', {
      'glide': distanceText(carriesM),
      'cost': cost,
      'walk': distanceText(walkM),
    });
    return '$go$more$est';
  }

  /// In the air: what the glide does if you head straight for the target now.
  String describeAloft() {
    if (reaches) {
      return spareM >= 30
          ? tr('Head straight there: you make it with {n} m to spare', {
            'n': (spareM / 5).round() * 5,
          })
          : tr('Head straight there: you just make it');
    }
    final more =
        (climbFirst ?? 0) > 0
            ? ' · ${tr('{n} m more height (an updraft) would do it', {'n': climbFirst!.round()})}'
            : '';
    final short = tr(
      'Head straight there: you come down {distance} short, then walk',
      {'distance': distanceText(walkM)},
    );
    return '$short$more';
  }
}

/// Where the glide comes down if it keeps its course: the first point where the glide line (with the
/// turbulence margin) meets the ground.
class Landing {
  const Landing(this.x, this.y, this.distanceM, this.seconds);
  final double x, y, distanceM, seconds;

  static Landing? of(PlayerPos p, HeightMap hm, Glider g) {
    if (p.mode != Motion.air ||
        p.course == null ||
        p.speed < 3 ||
        g.ratio <= 0) {
      return null;
    }
    final ratio = g.ratio * GlideCheck.turbulence;
    final speed = p.speed >= 5 ? p.speed : g.speed;
    final start = p.height - GlideCheck.cameraHeight;
    final a = p.course! * math.pi / 180;
    final ux = math.sin(a), uy = -math.cos(a); // y grows south
    final px = World.mPerPx;
    var d = px;
    for (; d < 6000; d += px) {
      if (start - d / ratio <= hm.at(p.x + ux * d / px, p.y + uy * d / px)) {
        break;
      }
    }
    return Landing(p.x + ux * d / px, p.y + uy * d / px, d, d / speed);
  }
}

/// On foot, when the glide from here falls short: higher ground nearby to climb first, from which the
/// glide carries all the way, when that beats walking there (or gliding from here and walking the rest)
/// by half a minute and 15%. The walk is costed along the straight line, a metre up as 8 m on the flat
/// (Naismith's rule); cliffs on the way aren't seen, the height map's 8 m pixels are too coarse.
class LaunchPlan {
  LaunchPlan._(
    this.x,
    this.y,
    this.walkM,
    this.climbM,
    this.glide,
    this.seconds,
    this.savedS,
  );

  /// The launch spot on the map.
  final double x, y;

  /// Metres to walk there, and metres up (negative: down to a drop).
  final double walkM, climbM;
  final GlideCheck glide;

  /// Seconds the whole way takes, and how many it saves over the best plan without it.
  final double seconds, savedS;

  static const climbCost = 8.0, defaultWalk = 6.0;

  /// Metres around the player searched for a launch spot.
  static const reachM = 1200.0;

  /// Time allowed for checking launch spots (off the UI thread, see [later]).
  static const budgetMs = 150;

  /// [of] on a background isolate: it searches 1.2 km of map and can take 100 ms.
  static Future<LaunchPlan?> later(
    PlayerPos p,
    NavTarget t,
    HeightMap hm,
    Glider g,
  ) => background(() => of(p, t, hm, g));

  static double walkTime(double m, double up, double speed) =>
      (m + math.max(0, up) * climbCost) / speed;

  static double _dist(double x0, double y0, double x1, double y1) =>
      math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)) * World.mPerPx;

  static LaunchPlan? of(PlayerPos p, NavTarget t, HeightMap hm, Glider g) {
    if (p.airborne || g.ratio <= 0 || g.speed <= 0) return null;
    final walk = p.walkSpeed ?? defaultWalk;
    final feet = p.height - GlideCheck.cameraHeight;
    final targetH = hm.at(t.x, t.y);
    final distM = _dist(p.x, p.y, t.x, t.y);
    if (distM < 200) return null;
    // the plans to beat: walk all the way, or glide from here and walk the rest
    var best = walkTime(distM, targetH - feet, walk);
    final ratio = g.ratio * GlideCheck.turbulence;
    final here = GlideCheck.of(p, t, hm, g);
    if (here != null && here.reaches) return null;
    if (here != null && here.carriesM >= 30) {
      final down = feet - here.carriesM / ratio;
      best = math.min(
        best,
        here.seconds + walkTime(here.walkM, targetH - down, walk),
      );
    }
    final worth = best - math.max(30, best * 0.15);
    final r = (math.min(reachM, math.max(320, distM)) / World.mPerPx).round();
    final cands =
        <(double, double, double, double)>[]; // (seconds, x, y, ground)
    // every pixel: a flat top can't be glided from, only its very edge
    for (var j = -r; j <= r; j++) {
      for (var i = -r; i <= r; i++) {
        if (i * i + j * j > r * r) continue;
        final x = p.x + i, y = p.y + j;
        if (x < 1 || y < 1 || x > hm.size - 2 || y > hm.size - 2) {
          continue;
        }
        final h = hm.at(x, y);
        final glideM = _dist(x, y, t.x, t.y);
        if (h < targetH + glideM / ratio)
          continue; // too low even over flat ground
        final secs =
            walkTime(_dist(p.x, p.y, x, y), h - feet, walk) + glideM / g.speed;
        if (secs < worth) cands.add((secs, x, y, h));
      }
    }
    cands.sort((a, b) => a.$1.compareTo(b.$1));
    // the quickest that really carries (ridges on the way are checked); a few tens of ms at most
    final clock = Stopwatch()..start();
    for (final (secs, x, y, h) in cands) {
      if (clock.elapsedMilliseconds > budgetMs) break;
      final chk = GlideCheck.from(x, y, h, t.x, t.y, hm, g);
      if (chk == null || !chk.reaches) continue;
      return LaunchPlan._(
        x,
        y,
        _dist(p.x, p.y, x, y),
        h - feet,
        chk,
        secs,
        best - secs,
      );
    }
    return null;
  }

  /// "Climb 95 m to high ground 420 m north-east, then glide 1.6 km · about 2 min quicker".
  String describe(PlayerPos p) {
    final dir = compassOf(x - p.x, y - p.y);
    final go =
        climbM >= 10
            ? tr('Climb {n} m to high ground {distance} {direction}', {
              'n': (climbM / 5).round() * 5,
              'distance': distanceText(walkM),
              'direction': dir,
            })
            : tr('Walk {distance} {direction} to the drop', {
              'distance': distanceText(walkM),
              'direction': dir,
            });
    final saved =
        savedS >= 90
            ? tr('{n} min', {'n': (savedS / 60).round()})
            : tr('{n} s', {'n': (savedS / 10).round() * 10});
    return tr('{go}, then glide {glide} · about {saved} quicker', {
      'go': go,
      'glide': distanceText(glide.carriesM),
      'saved': saved,
    });
  }
}

/// "568 m up · 65 m under the surface · 40 m below you": a point's height, which the map alone doesn't show
/// (a cave, a cellar, the sea floor or a floating island). [ground] from the [HeightMap], the top surface
/// with islands, so a few metres off and more on cliffs; [me] the live position, when there is one.
String heightNote(double h, double? ground, PlayerPos? me) {
  final parts = [
    tr('{n} m up', {'n': h.round()}),
  ];
  if (ground != null) {
    final d = (h - ground).round();
    if (d < -15) {
      parts.add(tr('{n} m under the surface', {'n': -d}));
    } else if (d > 15) {
      parts.add(tr('{n} m above the ground', {'n': d}));
    }
  }
  if (me != null) {
    final c = (h - (me.height - GlideCheck.cameraHeight)).round();
    parts.add(
      c.abs() < 4
          ? tr('level with you')
          : c > 0
          ? tr('{n} m above you', {'n': c.abs()})
          : tr('{n} m below you', {'n': c.abs()}),
    );
  }
  return parts.join(' · ');
}

/// Directions to the target from the live position: how far, which way to turn, how much up or down.
class Guide {
  Guide._(
    this.distanceM,
    this.turn,
    this.climb,
    this.glide,
    this.mode,
    this.landing,
  );
  final double distanceM;

  /// Degrees to turn, -180..180 (negative = left): from where you fly in the air, from where the camera
  /// looks on foot.
  final double turn;

  /// Metres the target is above (+) or below (-) the character's feet.
  final double climb;
  final GlideCheck? glide;
  final Motion? mode;

  /// Where the current glide comes down, in the air.
  final Landing? landing;

  factory Guide(PlayerPos p, NavTarget t, HeightMap? hm, Glider? g) {
    final dx = t.x - p.x, dy = t.y - p.y;
    final dist = math.sqrt(dx * dx + dy * dy) * World.mPerPx;
    final bearing = math.atan2(dx, -dy) * 180 / math.pi;
    final turn = ((bearing - p.travel + 540) % 360) - 180;
    final targetH = t.height ?? hm?.at(t.x, t.y);
    final climb =
        targetH == null ? 0.0 : targetH - (p.height - GlideCheck.cameraHeight);
    return Guide._(
      dist,
      turn,
      climb,
      hm == null || g == null ? null : GlideCheck.of(p, t, hm, g),
      p.mode,
      hm == null || g == null ? null : Landing.of(p, hm, g),
    );
  }

  bool get arrived => distanceM < 15;
  bool get airborne => mode == Motion.air || mode == Motion.fall;

  /// "340 m · bear left" ...
  String get headline {
    if (arrived) return tr("You're there");
    return '${distanceText(distanceM)} · $turnText';
  }

  String get turnText {
    final a = turn.abs();
    final left = turn < 0;
    if (a < 15) return tr('straight ahead');
    if (a < 60) return left ? tr('bear left') : tr('bear right');
    if (a < 135) return left ? tr('turn left') : tr('turn right');
    return tr('behind you');
  }

  /// "60 m above you" / "level with you".
  String get heightText {
    final c = climb.round();
    if (c.abs() < 4) return tr('Level with you');
    return c > 0
        ? tr('{n} m above you', {'n': c.abs()})
        : tr('{n} m below you', {'n': c.abs()});
  }

  /// "On foot", "Gliding", "Falling"; null from an older agent.
  String? get modeText => switch (mode) {
    Motion.foot => tr('On foot'),
    Motion.air => tr('Gliding'),
    Motion.fall => tr('Falling'),
    null => null,
  };

  /// The glide line for the card: from here on foot, straight on in the air, a warning when falling.
  String? get glideText {
    if (mode == Motion.fall) return tr('Falling: open the glider');
    final g = glide;
    if (g == null) return null;
    return mode == Motion.air ? g.describeAloft() : g.describe();
  }
}
