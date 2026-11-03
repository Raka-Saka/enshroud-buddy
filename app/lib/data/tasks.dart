import 'dart:math' as math;

import 'game_db.dart';
import 'live_state.dart';
import 'planner.dart';
import 'survival.dart';
import 'where.dart';

enum TaskKind { unlock, station, prepare, gather, fetch, craft }

/// Something still missing for an unlock: a knowledge step, an item to pick up, a Flame level.
class UnlockStep {
  UnlockStep(
    this.text, {
    this.itemId,
    this.checkable = true,
    this.spots = const [],
  });
  final String text;
  final String? itemId;

  /// False when the save can't tell (runtime state such as "Seedbed craftable").
  final bool checkable;
  final List<RankedSpot> spots;
}

/// One thing to do, in the order the plan needs it.
class Task {
  Task(
    this.kind,
    this.title, {
    this.detail,
    this.itemId,
    this.count = 0,
    this.spots = const [],
    this.steps = const [],
    this.ready = false,
    this.station,
  });
  final TaskKind kind;
  final String title;
  final String? detail;

  /// The item gathered, fetched, crafted or unlocked; for a station, its placeable.
  final String? itemId;
  final int count;

  /// Places to get it, best first (gather tasks).
  final List<RankedSpot> spots;

  /// What an unlock still needs.
  final List<UnlockStep> steps;

  /// Already in hand: a fetch whose items are all in the bag.
  final bool ready;

  /// Craft tasks: the station's placeable item, to tell whether it stands where you are.
  final String? station;
}

/// The shopping list turned into tasks: unlock recipes, build stations, gather, take from storage,
/// then craft, intermediates before what they go into.
class TaskPlan {
  TaskPlan(this.db, this.state, List<Goal> goals, this.where) {
    planner = Planner(db, state);
    trees = planner.planAll(goals);

    // crafts, children first; the same recipe in two places is merged at its first (deepest) position
    final crafts = <String, (Recipe, int)>{};
    void walk(PlanStep s) {
      for (final c in s.children) {
        walk(c);
      }
      if (s.crafted) {
        final prev = crafts[s.recipe!.id];
        crafts[s.recipe!.id] = (s.recipe!, (prev?.$2 ?? 0) + s.batches);
      }
    }

    for (final t in trees) {
      walk(t);
    }

    // 1. unlocks
    for (final (r, _) in crafts.values) {
      if (planner.unlocked(r)) continue;
      final out = r.outputs.first.ref;
      final missing = r.unlock == null ? null : _missing(r.unlock!);
      tasks.add(
        Task(
          TaskKind.unlock,
          'Unlock ${db.nameOf(out)}',
          itemId: out,
          detail:
              missing == null
                  ? 'The game data has no unlock condition for this recipe: usually an artisan or a quest.'
                  : missing.isEmpty
                  ? 'Everything the save can check is done; the rest is runtime state.'
                  : null,
          steps: missing ?? const [],
        ),
      );
    }

    // 2. stations and station upgrades that aren't built anywhere
    final seen = <String>{};
    for (final (r, _) in crafts.values) {
      final w = db.workshops[r.workshopId];
      for (final ws in [w, for (final p in r.props) db.workshops[p]]) {
        final item = ws?.itemId;
        // artisans aren't built; rescuing them is part of the unlock
        if (ws == null ||
            item == null ||
            ws.kind == 'npc' ||
            !seen.add(ws.id)) {
          continue;
        }
        if ((state?.placed[item] ?? 0) > 0) continue;
        final users = [
          for (final (r2, _) in crafts.values)
            if (r2.workshopId == ws.id || r2.props.contains(ws.id))
              db.nameOf(r2.outputs.first.ref),
        ];
        tasks.add(
          Task(
            TaskKind.station,
            ws.kind == 'prop'
                ? 'Add ${_a(ws.name)} to your ${w?.name ?? 'station'}'
                : 'Build ${_a(ws.name)}',
            itemId: item,
            detail: 'Needed for ${users.take(4).join(', ')}',
          ),
        );
      }
    }

    // 3. gather or find what nobody owns and no recipe makes
    final gather =
        planner.toGather.entries.toList()..sort((a, b) {
          final ca = db.items[a.key]?.isCommon ?? false;
          final cb = db.items[b.key]?.isCommon ?? false;
          return ca != cb
              ? (ca ? 1 : -1)
              : db.nameOf(a.key).compareTo(db.nameOf(b.key));
        });
    for (final g in gather) {
      final it = db.items[g.key];
      final gear = it?.stats?.slot != null && it?.stats?.slot != 'Consumable';
      tasks.add(
        Task(
          TaskKind.gather,
          '${gear ? 'Find' : 'Gather'} ${g.value} × ${db.nameOf(g.key)}',
          itemId: g.key.startsWith('cat:') ? null : g.key,
          count: g.value,
          detail:
              it == null
                  ? 'Any item of this kind'
                  : it.everywhere ??
                      (it.isCommon ? 'Found almost everywhere' : null) ??
                      it.hint,
          spots:
              g.key.startsWith('cat:') || it?.everywhere != null
                  ? const []
                  : where.best(g.key, count: it!.isCommon ? 1 : 3),
        ),
      );
    }

    // 3b. prepare for where the best places are: the Shroud, the cold, the water
    _prepare();

    // 4. take from storage what the plan uses
    for (final e in planner.taken.entries) {
      final places = state?.whereIs(e.key, db.nameOf) ?? const <StoredIn>[];
      final inBag = places
          .where((p) => p.label == 'Bag')
          .fold(0, (a, p) => a + p.count);
      tasks.add(
        Task(
          TaskKind.fetch,
          'Take ${e.value} × ${db.nameOf(e.key)}',
          itemId: e.key,
          count: e.value,
          detail: _byBase(places.where((p) => p.label != 'Equipped')),
          ready: inBag >= e.value,
        ),
      );
    }

    // 5. craft, in order
    for (final (r, batches) in crafts.values) {
      final out = r.outputs.first;
      final w = db.workshops[r.workshopId];
      tasks.add(
        Task(
          TaskKind.craft,
          'Craft ${out.count * batches} × ${db.nameOf(out.ref)}',
          itemId: out.ref,
          count: out.count * batches,
          station: w?.kind == 'npc' ? null : w?.itemId,
          detail: [
            if (w != null)
              w.kind == 'npc'
                  ? 'at the ${w.name} (artisan)'
                  : 'at ${_a(w.name)}${_stationBases(w.itemId)}',
            if (batches > 1) '$batches batches',
            if (!planner.unlocked(r)) 'locked',
          ].join(' · '),
        ),
      );
    }
  }

  final GameDb db;
  final LiveState? state;
  final WhereToGet where;
  late final Planner planner;
  late final List<PlanStep> trees;
  final tasks = <Task>[];

  Iterable<Task> of(TaskKind k) => tasks.where((t) => t.kind == k);

  /// One Prepare task per hazard the best places share, naming the items and what to bring.
  void _prepare() {
    final s = state;
    if (s == null) return;
    final shroud = <String>{}, cold = <String>{}, water = <String>{};
    void look(String name, RankedSpot? r) {
      if (r == null) return;
      if ((r.shroudLevel != null && !r.shroudBlocked) || r.shroudHint) {
        shroud.add(name);
      }
      if (r.cold && !r.coldProtected) cold.add(name);
      if (r.underwater) water.add(name);
    }

    for (final t in of(TaskKind.gather)) {
      look(db.nameOf(t.itemId ?? ''), t.spots.firstOrNull);
    }
    for (final t in of(TaskKind.unlock)) {
      for (final st in t.steps) {
        if (st.itemId != null)
          look(db.nameOf(st.itemId!), st.spots.firstOrNull);
      }
    }
    final sv = Survival(db, s);
    String food(List<String> labels) {
      final best = sv.bestFood(labels);
      if (best.isNotEmpty) {
        return 'Bring ${best.map((f) => '${f.$1.name} (${f.$2}, ${f.$3} owned)').join(', ')}';
      }
      // nothing owned: the strongest food in the game for it, to cook or find
      (Item, String)? top;
      var topN = 0.0;
      for (final it in db.items.values) {
        if (it.stats?.slot != 'Consumable') continue;
        for (final (l, v) in it.stats!.values) {
          final n = labels.contains(l) ? Survival.seconds(v).toDouble() : 0.0;
          final double m =
              n > 0 ? n : (labels.contains(l) ? double.tryParse(v) ?? 0 : 0);
          if (m > topN) (topN, top) = (m, (it, v));
        }
      }
      return top == null
          ? 'No food for it in your bag or chests'
          : 'None owned; ${top.$1.name} gives ${top.$2}';
    }

    String mins(int secs) => Survival.format(secs);
    final at = tasks.indexWhere((t) => t.kind.index > TaskKind.prepare.index);
    final add = <Task>[
      if (shroud.isNotEmpty)
        Task(
          TaskKind.prepare,
          'Shroud: about ${mins(sv.shroudSeconds)} per trip',
          detail:
              'For ${shroud.take(4).join(', ')}. ${food(Survival.shroudLabels)}. Shroud Roots and Return Beacons on the map; Flame strength ${s.flameLevel} lets you in.',
        ),
      if (cold.isNotEmpty)
        Task(
          TaskKind.prepare,
          'Cold: frost resistance ${sv.frostResistance} from your gear',
          detail:
              'For ${cold.take(4).join(', ')}. ${food(const ['Frost Resistance'])}. Flame strength ${db.balancing?.noFreezeFlameLevel ?? '?'} stops freezing.',
        ),
      if (water.isNotEmpty)
        Task(
          TaskKind.prepare,
          'Underwater: ${mins(sv.oxygenSeconds)} of breath',
          detail:
              'For ${water.take(4).join(', ')}. ${food(const ['Maximum Oxygen'])}. Air bubbles are on the map (Water chip).',
        ),
    ];
    tasks.insertAll(at < 0 ? tasks.length : at, add);
  }

  /// "Bag 5 · Lakeside Keep: Large Magic Chest #6 28, Huge Magic Chest #2 4".
  static String _byBase(Iterable<StoredIn> places) {
    final groups = <String?, List<String>>{};
    for (final p in places) {
      (groups[p.label == 'Bag' ? 'Bag' : p.base] ??= []).add(
        p.label == 'Bag' ? '${p.count}' : '${p.label} ${p.count}',
      );
    }
    return [
      for (final e in groups.entries)
        e.key == 'Bag'
            ? 'Bag ${e.value.first}'
            : '${e.key ?? 'base not known'}: ${e.value.join(', ')}',
    ].join(' · ');
  }

  /// " (Lakeside Keep)" when the save says which bases have the station.
  String _stationBases(String? stationItem) {
    if (stationItem == null || state == null) return '';
    final at = state!.basesWith(stationItem);
    return at.isEmpty ? '' : ' (${at.map((b) => b.label).join(', ')})';
  }

  static String _a(String noun) =>
      '${'aeiouAEIOU'.contains(noun.isEmpty ? 'x' : noun[0]) ? 'an' : 'a'} $noun';

  bool _met(Unlock l) {
    final text = l.text ?? '';
    if (l.knowledge != null &&
        (state?.knowledge.contains(l.knowledge) ?? false)) {
      return true;
    }
    if (l.itemId != null && (state?.owned(l.itemId!) ?? 0) > 0) return true;
    if (l.runtime != null)
      return l.met(const {}, state?.unlockContext) ?? false;
    if (text.startsWith('Build 0 ')) return true;
    return false;
  }

  /// The unmet leaves on the cheapest way through an unlock tree (fewest missing steps per OR).
  List<UnlockStep> _missing(Unlock u) {
    if (u.isLeaf) {
      if (_met(u)) return const [];
      final text = u.text ?? '';
      final checkable =
          u.knowledge != null || u.itemId != null || u.runtime != null;
      return [
        UnlockStep(
          text.isEmpty ? 'An unnamed condition' : text,
          itemId: u.itemId,
          checkable: checkable,
          spots: u.itemId == null ? const [] : where.best(u.itemId!, count: 2),
        ),
      ];
    }
    final parts = [for (final c in u.children) _missing(c)];
    if (u.op == 'OR') {
      parts.sort((a, b) => a.length.compareTo(b.length));
      return parts.firstOrNull ?? const [];
    }
    return [for (final p in parts) ...p];
  }
}

/// A task as it stands where the player is right now, and why it moved up ("Here: Large Magic Chest #3").
class NextUp {
  NextUp(this.task, this.note, this.rank);
  final Task task;
  final String? note;

  /// 0 can be done right here, 1 close by or at a station here, 2 the plan's own order.
  final int rank;
  bool get here => rank < 2;
}

/// Open tasks, the ones you can do where you stand first: take from a chest in the base you're in, craft
/// at a station there, gather at a spot within 400 m. Otherwise the plan's order.
List<NextUp> nextUp(TaskPlan plan, PlayerPos? here) {
  final s = plan.state;
  final base = here == null ? null : baseAt(s, here);
  final out = <NextUp>[];
  for (final t in plan.tasks) {
    if (t.ready) continue;
    String? note;
    var rank = 2;
    if (base != null &&
        s != null &&
        t.kind == TaskKind.fetch &&
        t.itemId != null) {
      final chests = [
        for (final p in s.whereIs(t.itemId!, plan.db.nameOf))
          if (p.base == base.label) p.label,
      ];
      if (chests.isNotEmpty) {
        rank = 0;
        note = 'Here: ${chests.take(2).join(', ')}';
      }
    } else if (base != null &&
        s != null &&
        t.kind == TaskKind.craft &&
        t.station != null &&
        s.basesWith(t.station!).contains(base)) {
      rank = 1;
      note = 'The station is here';
    } else if (here != null &&
        t.kind == TaskKind.gather &&
        t.spots.isNotEmpty) {
      RankedSpot? near;
      var best = double.infinity;
      for (final r in t.spots) {
        final d =
            math.sqrt(
              math.pow(r.spot.x - here.x, 2) + math.pow(r.spot.y - here.y, 2),
            ) *
            8;
        if (d < best) (best, near) = (d, r);
      }
      if (near != null && best < 400) {
        rank = 1;
        note =
            best < 30
                ? 'Right here'
                : '${distanceText(best)} ${compassOf(near.spot.x - here.x, near.spot.y - here.y)} of you';
      }
    }
    out.add(NextUp(t, note, rank));
  }
  final order = [for (var i = 0; i < out.length; i++) i]..sort(
    (a, b) =>
        out[a].rank != out[b].rank
            ? out[a].rank.compareTo(out[b].rank)
            : a.compareTo(b),
  );
  return [for (final i in order) out[i]];
}
