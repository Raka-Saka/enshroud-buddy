import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n.dart';
import 'game_db.dart';
import 'guide.dart';
import 'hall_check.dart';
import 'live_state.dart';

/// What a hunt is after: what the save tracks (lore, unique loot, Shroud Roots, Elixir Wells, Ancient Obelisks),
/// and places it doesn't (Flame Shrines, Sanctums), which count as done once visited, remembered per world.
enum HuntKind { lore, uniques, both, roots, wells, obelisks, shrines, sanctums }

/// A hunt: the guide leads to the nearest place still holding what's hunted (a lore page, unique loot, a
/// Shroud Root to clear...), anywhere or in one region, and on to the next nearest once it's had. "Had" is the save saying so, or, as the game saves only now and
/// then, having been there (closer than [Guide.arrived]) and walked on ([leftM] away): that place is then
/// left out of this hunt. Places inside the Hollow Halls are left out (their maps are separate).
///
/// The PC runs the same hunt (tools/hunt.py, POST /hunt) from the list of places sent to it, so it goes on
/// with the phone asleep in a pocket; while it does, the phone follows what it says (GET /pos, "hunt").
class Hunt extends ChangeNotifier {
  HuntKind? kind;

  /// Only places in this region (GameDb.regionAt), or anywhere.
  String? region;

  /// Places the save can't tell about (Flame Shrines, Sanctums) visited in earlier hunts, per world: "x,y".
  final _visited = <String>{};
  String? _visitedWorld;

  /// Sends the places left to the PC (LiveState.setHunt); null stops its hunt.
  void Function(Map<String, Object?>? places)? send;
  String? _sent;

  /// The place being led to, and how many are left (counting it).
  Poi? current;
  int left = 0;

  /// Places this hunt is done with without the save knowing yet: visited or skipped.
  final _passed = <Poi>{};
  bool _reached = false;
  NavTarget? _target;

  /// Metres away from a reached place that count as having moved on.
  static const leftM = 30.0;

  /// Another place takes over only when it's this much nearer (metres and share), so the target doesn't
  /// flip back and forth while you walk.
  static const switchM = 150.0, switchShare = 0.5;

  bool get on => kind != null;

  void start(
    HuntKind k,
    GameDb db,
    LiveState? s,
    PlayerPos? p, {
    String? region,
  }) {
    kind = k;
    this.region = region;
    _passed.clear();
    current = null;
    _sent = null;
    update(db, s, p);
  }

  void stop() {
    if (kind == null) return;
    kind = null;
    current = null;
    _passed.clear();
    _sent = null;
    send?.call(null);
    if (identical(navTarget.value, _target)) navTarget.value = null;
    _target = null;
    notifyListeners();
  }

  /// Leave the current place out and go to the next.
  void skip(GameDb db, LiveState? s, PlayerPos? p, {Map<String, dynamic>? pc}) {
    if (current case final c?) _passed.add(c);
    current = null;
    update(db, s, p, pc: pc);
  }

  /// Another target picked by hand (a place's sheet, the map) ends the hunt.
  void targetChanged() {
    if (on && !identical(navTarget.value, _target)) {
      _target = null;
      stop();
    }
  }

  static bool wanted(HuntKind k, Poi p) => switch (k) {
    HuntKind.lore => p.cat == 'lore' && p.lore != null,
    HuntKind.uniques => p.cat != 'lore' && p.loot.isNotEmpty,
    HuntKind.both => HallFinds.collectible(p),
    HuntKind.roots => p.cat == 'label' && p.kind == 'Shroud Root',
    HuntKind.wells => p.cat == 'label' && p.title == 'Elixir Well',
    HuntKind.obelisks => p.cat == 'label' && p.title == 'Ancient Obelisk',
    HuntKind.shrines => p.cat == 'label' && p.kind == 'Flame Shrine',
    HuntKind.sanctums =>
      p.cat == 'label' &&
          (p.title == 'Night Sanctum' || p.title == 'Flame Sanctum'),
  };

  /// Whether the save can say a place of this hunt is done (else: visited counts).
  static bool tracked(Poi p) => p.cat != 'label' || p.done != null;

  /// Done by the save, or visited before when the save can't tell; null without a save.
  bool? _done(GameDb db, LiveState? s, HallFinds finds, Poi p) {
    if (!tracked(p)) return _visited.contains(_key(p.x, p.y));
    if (s == null) return null;
    return p.cat == 'label' ? db.poiDone(p, s.knowledge) : finds.had(p);
  }

  /// How many places of a kind are left, here or anywhere (the Plan tab's choices).
  int count(GameDb db, LiveState? s, HuntKind k, String? region) {
    _loadVisited(s);
    final finds = HallFinds(db, s);
    return db.poi
        .where(
          (p) =>
              !p.inside &&
              wanted(k, p) &&
              (region == null || db.regionAt(p.x, p.y) == region) &&
              _done(db, s, finds, p) != true,
        )
        .length;
  }

  /// Visited places (shrines, sanctums) for this world; earlier worlds' are kept under their own name.
  void _loadVisited(LiveState? s) {
    final w = s?.world;
    if (w == null || w == _visitedWorld) return;
    _visitedWorld = w;
    _visited.clear();
    SharedPreferences.getInstance().then((prefs) {
      if (_visitedWorld != w) return;
      _visited.addAll(prefs.getStringList('hunt_visited:$w') ?? const []);
      notifyListeners();
    });
  }

  void _visit(Poi p) {
    final key = _key(p.x, p.y);
    if (tracked(p) || !_visited.add(key)) return;
    final w = _visitedWorld;
    if (w == null) return;
    // added to what's stored, in case the stored list hasn't been read yet
    SharedPreferences.getInstance().then((prefs) {
      final had = prefs.getStringList('hunt_visited:$w') ?? const [];
      prefs.setStringList('hunt_visited:$w', {...had, key}.toList());
    });
  }

  /// Visited shrines and sanctums of this world, forgotten (to hunt them again).
  int get visitedCount => _visited.length;
  void forgetVisited() {
    _visited.clear();
    final w = _visitedWorld;
    if (w != null) {
      SharedPreferences.getInstance().then(
        (prefs) => prefs.remove('hunt_visited:$w'),
      );
    }
    notifyListeners();
  }

  static double _metres(Poi a, PlayerPos p) =>
      math.sqrt(math.pow(a.x - p.x, 2) + math.pow(a.y - p.y, 2)) * World.mPerPx;

  static String _key(num x, num y) =>
      '${x.toStringAsFixed(1)},${y.toStringAsFixed(1)}';

  /// After the position or the save changed: move on when the place is had or was visited, pick the
  /// nearest left, point the guide at it. With [pc], the PC's hunt ({"cur": [x, y], "passed": [[x, y]...]}),
  /// what it picked and visited is taken instead.
  void update(
    GameDb db,
    LiveState? s,
    PlayerPos? p, {
    Map<String, dynamic>? pc,
  }) {
    final k = kind;
    if (k == null) return;
    _loadVisited(s);
    final finds = HallFinds(db, s);
    if (pc != null) {
      final byKey = {for (final poi in db.poi) _key(poi.x, poi.y): poi};
      for (final k in (pc['passed'] as List? ?? const [])) {
        if (byKey[_key(k[0] as num, k[1] as num)] case final poi?) {
          _passed.add(poi);
          _visit(poi);
        }
      }
      current = switch (pc['cur']) {
        [final num x, final num y] => byKey[_key(x, y)],
        _ => null,
      };
    }
    if (current case final c? when p != null && pc == null) {
      final d = _metres(c, p);
      if (d < 15) _reached = true;
      if (_reached && d > leftM) {
        _passed.add(c);
        _visit(c);
        current = null;
      }
    }
    if (current case final c? when _done(db, s, finds, c) == true) {
      current = null;
    }
    final open = [
      for (final poi in db.poi)
        if (!poi.inside &&
            wanted(k, poi) &&
            (region == null || db.regionAt(poi.x, poi.y) == region) &&
            !_passed.contains(poi) &&
            _done(db, s, finds, poi) != true)
          poi,
    ];
    left = open.length;
    final sig = '$kind $region ${open.length}';
    if (sig != _sent && send != null) {
      send!({
        if (_sent == null) 'new': true,
        'm': World.mPerPx,
        'places': [
          for (final poi in open)
            [poi.x, poi.y, poi.height, _title(db, poi, finds)],
        ],
      });
      _sent = sig;
    }
    Poi? best;
    if (pc != null) {
      best = current != null && open.contains(current) ? current : null;
    } else if (p != null) {
      var bestD = double.infinity;
      for (final poi in open) {
        final d = _metres(poi, p);
        if (d < bestD) (bestD, best) = (d, poi);
      }
      if (current case final c? when best != null && best != c) {
        final now = _metres(c, p);
        if (now - bestD < switchM || bestD > now * switchShare) best = c;
      }
    } else {
      best = current != null && open.contains(current) ? current : null;
    }
    if (best != current) _reached = false;
    current = best;
    if (current case final c?) {
      if (_target == null || _target!.x != c.x || _target!.y != c.y) {
        _target = NavTarget(_title(db, c, finds), c.x, c.y, height: c.height);
        navTarget.value = _target;
      }
    } else if (open.isEmpty && (p != null || pc != null)) {
      stop();
      return;
    }
    notifyListeners();
  }

  String _title(GameDb db, Poi p, HallFinds finds) {
    if (p.cat == 'lore') return tr('Lore: {title}', {'title': gt(p.title)});
    if (p.cat == 'label') return gt(p.title);
    final missing = [
      for (final id in p.loot)
        if (finds.hasItem(id) != true) gt(db.items[id]?.name ?? id),
    ];
    return missing.isEmpty ? gt(p.title) : missing.take(2).join(', ');
  }

  String label(HuntKind k) => switch (k) {
    HuntKind.lore => tr('Lore'),
    HuntKind.uniques => tr('Unique loot'),
    HuntKind.both => tr('Lore and unique loot'),
    HuntKind.roots => tr('Shroud Roots'),
    HuntKind.wells => tr('Elixir Wells'),
    HuntKind.obelisks => tr('Ancient Obelisks'),
    HuntKind.shrines => tr('Flame Shrines'),
    HuntKind.sanctums => tr('Sanctums'),
  };
}

/// The app's one hunt (driven from main.dart, shown on the Plan tab and the map's guide card).
final hunt = Hunt();
