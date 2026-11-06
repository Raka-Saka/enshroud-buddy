import 'dart:math' as math;

import '../l10n.dart';

import 'game_db.dart';
import 'hall_check.dart';
import 'live_state.dart';
import 'planner.dart';
import 'tasks.dart';
import 'where.dart';

/// The plan cut down for the PC's overlay (POST /tracker, tools/overlay.py): the goals, the next few tasks
/// with what makes them "next" (here, close by), how far along lore and unique loot are, and a place to go,
/// which the overlay marks when the guide has no target of its own: the first thing to gather for the plan,
/// else the nearest lore page or unique piece still missing. Null without a save.
Map<String, Object?>? trackerOf(
  GameDb db,
  LiveState? state,
  List<Goal> goals,
  Terrain? terrain,
  PlayerPos? here,
) {
  if (state == null) return null;
  final done = _completion(db, state, here);
  if (goals.isEmpty) {
    return {
      'title': '',
      'open': 0,
      'lines': const [],
      'done': done.counts,
      'target': done.nearest,
    };
  }
  final where = WhereToGet(db, state, terrain, here: here);
  final plan = TaskPlan(db, state, goals, where);
  final next = nextUp(plan, here);
  final names = [for (final g in goals) db.shownName(g.itemId)];
  Map<String, Object?>? target;
  for (final n in next) {
    final t = n.task;
    if (t.kind != TaskKind.gather || t.spots.isEmpty) continue;
    var best = t.spots.first;
    if (here != null) {
      double d(RankedSpot r) =>
          math.pow(r.spot.x - here.x, 2) + math.pow(r.spot.y - here.y, 2) * 1.0;
      for (final r in t.spots) {
        if (d(r) < d(best)) best = r;
      }
    }
    target = {
      'title': t.title,
      'x': best.spot.x,
      'y': best.spot.y,
      'h': best.spot.poi?.height,
    };
    break;
  }
  return {
    'title':
        names.length == 2
            ? tr('{a} and {b}', {'a': names[0], 'b': names[1]})
            : names.length < 2
            ? names.join()
            : tr('{items} +{n}', {
              'items': names.take(2).join(', '),
              'n': names.length - 2,
            }),
    'open': next.length,
    'lines': [
      for (final n in next.take(5))
        {'t': n.task.title, if (n.note != null) 'n': n.note},
    ],
    'done': done.counts,
    'target': target ?? done.nearest,
  };
}

/// Lore pages found and unique loot had, against all there are (the Home screen's and the map's counts), and
/// the nearest place outside the Hollow Halls with something still missing.
({List<Map<String, Object?>> counts, Map<String, Object?>? nearest})
_completion(GameDb db, LiveState state, PlayerPos? here) {
  final k = state.knowledge;
  final pages = [for (final d in db.lore) ...d.pages];
  final finds = HallFinds(db, state);
  final uniques = <String>{}, had = <String>{};
  Poi? best;
  var bestD = double.infinity;
  for (final p in db.poi) {
    for (final id in p.loot) {
      final n = db.items[id]?.name ?? id;
      uniques.add(n);
      if (finds.hasItem(id) == true) had.add(n);
    }
    if (here == null || p.inside || finds.had(p) != false) continue;
    final d = math.pow(p.x - here.x, 2) + math.pow(p.y - here.y, 2) * 1.0;
    if (d < bestD) (bestD, best) = (d, p);
  }
  Map<String, Object?>? nearest;
  if (best case final p?) {
    final missing = [
      for (final id in p.loot)
        if (finds.hasItem(id) == false) gt(db.items[id]?.name ?? id),
    ];
    nearest = {
      'title':
          p.cat == 'lore'
              ? tr('Lore: {title}', {'title': gt(p.title)})
              : missing.take(2).join(', '),
      'x': p.x,
      'y': p.y,
      'h': p.height,
    };
  }
  return (
    counts: [
      {
        'label': tr('Lore'),
        'have': pages.where((p) => p.done?.likely(k) ?? false).length,
        'of': pages.length,
      },
      {
        'label': tr('Unique loot'),
        'have': had.length,
        'of': uniques.length,
      },
    ],
    nearest: nearest,
  );
}
