import 'dart:collection';

import 'build.dart';
import 'game_db.dart';

/// A build direction: the weapons it fights with and how much each axis matters.
class BuildGoal {
  const BuildGoal(this.name, this.blurb, this.weapons, this.weights);
  final String name, blurb;

  /// Weapon types the build uses; empty = no weapon focus (utility build).
  final List<String> weapons;
  final Map<String, double> weights;
}

/// One step of a projected path: a skill and the rank it reaches.
class ProjectedStep {
  ProjectedStep(this.skill, this.rank);
  final Skill skill;
  final int rank;
}

/// Where a build goes with a point budget: the skills to take, in order, and how each axis grows.
///
/// A skill's worth is its cost (the game prices stronger skills higher) times the goal's weight
/// for each axis it feeds, times how often it applies (Skill.factor); skills tied to weapons the
/// goal doesn't use are worth nothing. An axis
/// fills up as you invest, and each point in it is then worth up to half less, which keeps the
/// projection from pouring everything into one axis. Paths through cheap connector nodes count
/// what the whole path brings per point.
class Projection {
  Projection(
    this.db,
    Map<String, int> learned,
    this.goal,
    this.budget, {
    this.flameLevel = 0,
  }) {
    for (final e in learned.entries) {
      if (db.skillById.containsKey(e.key))
        _rank[e.key] = e.value < 1 ? 1 : e.value;
    }
    for (final k in db.skills) {
      if (_suits(k)) {
        for (final a in k.axes) {
          axisMax[a] = (axisMax[a] ?? 0) + _power(k) * _ranks(k);
        }
      }
    }
    before.addAll(_totals());
    _plan();
    after.addAll(_totals());
  }

  final GameDb db;
  final BuildGoal goal;
  final int budget, flameLevel;
  final steps = <ProjectedStep>[];
  int spent = 0;

  /// Points per axis before and after, and the most the tree offers this goal.
  final before = <String, double>{}, after = <String, double>{};
  final axisMax = <String, double>{};
  final _rank = <String, int>{};

  static const axes = [
    'damage',
    'area',
    'survival',
    'sustain',
    'gathering',
    'building',
    'exploration',
    'passives',
  ];
  static const axisNames = {
    'damage': 'Damage',
    'area': 'Area damage',
    'survival': 'Survivability',
    'sustain': 'Mana & stamina',
    'gathering': 'Gathering',
    'building': 'Building',
    'exploration': 'Exploration',
    'passives': 'Passive buffs',
  };

  static const _melee1h = ['Sword', 'Axe', 'Mace'];
  static const _melee2h = ['Greatsword', 'Hammer', 'Two-handed axe'];
  static const goals = [
    BuildGoal(
      'Archer',
      'Bow damage, crits and arrows',
      ['Bow'],
      {
        'damage': 3,
        'area': 1.5,
        'survival': 1,
        'sustain': 1.5,
        'exploration': 0.5,
        'passives': 0.5,
      },
    ),
    BuildGoal(
      'Assassin',
      'Daggers, backstabs and sneak attacks',
      ['Dagger'],
      {
        'damage': 3,
        'area': 0.5,
        'survival': 1.2,
        'sustain': 1.2,
        'exploration': 0.5,
        'passives': 0.5,
      },
    ),
    BuildGoal(
      'Ranger',
      'Bow at range, daggers up close',
      ['Bow', 'Dagger'],
      {
        'damage': 3,
        'area': 1,
        'survival': 1,
        'sustain': 1.5,
        'exploration': 0.5,
        'passives': 0.5,
      },
    ),
    BuildGoal(
      'Wand mage',
      'Fast wand casting and mana',
      ['Wand'],
      {
        'damage': 3,
        'area': 1.5,
        'survival': 1,
        'sustain': 1.5,
        'exploration': 0.3,
        'passives': 0.5,
      },
    ),
    BuildGoal(
      'Staff caster and healer',
      'Staff blasts, auras and heals',
      ['Staff'],
      {
        'damage': 2,
        'area': 2,
        'survival': 2,
        'sustain': 1.5,
        'exploration': 0.3,
        'passives': 0.5,
      },
    ),
    BuildGoal(
      'Knight',
      'One-handed weapon and shield, hard to kill',
      [..._melee1h, 'Shield'],
      {
        'damage': 2,
        'area': 0.5,
        'survival': 3,
        'sustain': 1,
        'exploration': 0.3,
        'passives': 0.5,
      },
    ),
    BuildGoal(
      'Barbarian',
      'Two-handed weapons, big hits and sweeps',
      _melee2h,
      {
        'damage': 3,
        'area': 2,
        'survival': 1.5,
        'sustain': 1,
        'exploration': 0.3,
        'passives': 0.5,
      },
    ),
    BuildGoal(
      'Battlemage',
      'Melee and wand together',
      [..._melee1h, 'Wand'],
      {
        'damage': 2.5,
        'area': 1.5,
        'survival': 2,
        'sustain': 1.5,
        'exploration': 0.3,
        'passives': 0.5,
      },
    ),
    BuildGoal(
      'Spellbow',
      'Bow damage with staff and wand magic',
      ['Bow', 'Wand', 'Staff'],
      {
        'damage': 3,
        'area': 2,
        'survival': 1,
        'sustain': 1.5,
        'exploration': 0.3,
        'passives': 0.5,
      },
    ),
    BuildGoal(
      'Explorer and builder',
      'Gathering, building, travel and passive buffs',
      [],
      {
        'gathering': 3,
        'building': 2,
        'exploration': 3,
        'passives': 2,
        'survival': 1,
        'sustain': 1,
      },
    ),
  ];

  /// Keep going the way the build already goes: its weapons, and weights from where its points are.
  static BuildGoal fromBuild(
    GameDb db,
    Map<String, int> learned,
    BuildTarget target,
  ) {
    final pts = <String, double>{};
    var total = 0.0;
    learned.forEach((id, r) {
      final k = db.skillById[id];
      if (k == null) return;
      for (final a in k.axes) {
        pts[a] = (pts[a] ?? 0) + k.cost * (r < 1 ? 1 : r);
        total += k.cost * (r < 1 ? 1 : r);
      }
    });
    return BuildGoal(
      'Keep my direction',
      'More of what your build already does',
      target.topWeapons,
      {
        for (final a in axes)
          a: 0.3 + 3 * (total == 0 ? 0 : (pts[a] ?? 0) / total),
      },
    );
  }

  bool _suits(Skill k) =>
      k.type != 'Root' &&
      k.axes.isNotEmpty &&
      (k.weapons.isEmpty || k.weapons.any(goal.weapons.contains));

  int _ranks(Skill k) => k.maxLevel > 1 ? k.maxLevel : 1;

  /// What one rank brings: its cost, or for Flame-scaled attributes the points they give (1 per 2 Flame levels).
  double _power(Skill k) {
    if (k.type == 'Attribute' &&
        (k.description ?? '').contains('levels of the Flame')) {
      return flameLevel / 2;
    }
    return k.cost.toDouble();
  }

  Map<String, double> _totals() {
    final t = <String, double>{};
    _rank.forEach((id, r) {
      final k = db.skillById[id]!;
      if (!_suits(k)) return;
      for (final a in k.axes) {
        t[a] = (t[a] ?? 0) + _power(k) * r;
      }
    });
    return t;
  }

  /// Worth of one more rank of a skill, given how full each axis already is.
  double _value(Skill k, Map<String, double> totals) {
    if (!_suits(k)) return 0;
    var v = 0.0;
    for (final a in k.axes) {
      final filled =
          (axisMax[a] ?? 0) == 0
              ? 0.0
              : ((totals[a] ?? 0) / axisMax[a]!).clamp(0.0, 1.0);
      v += (goal.weights[a] ?? 0) * (1 - 0.5 * filled);
    }
    return v * _power(k) * k.factor;
  }

  void _plan() {
    var left = budget;
    while (left > 0) {
      final totals = _totals();
      // cheapest routes from what is learned (or a Spark) to every node
      final dist = <String, int>{};
      final prev = <String, String>{};
      final queue = SplayTreeSet<(int, String)>(
        (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
      );
      for (final k in db.skills) {
        if (_rank.containsKey(k.id) || k.type == 'Root') {
          dist[k.id] = 0;
          queue.add((0, k.id));
        }
      }
      while (queue.isNotEmpty) {
        final (d, id) = queue.first;
        queue.remove(queue.first);
        if (d > (dist[id] ?? 1 << 30)) continue;
        for (final n in db.skillById[id]?.links ?? const <String>[]) {
          final nd = d + (db.skillById[n]?.cost ?? 1);
          if (nd < (dist[n] ?? 1 << 30)) {
            dist[n] = nd;
            prev[n] = id;
            queue.add((nd, n));
          }
        }
      }
      List<Skill>? bestPath;
      Skill? bestRank;
      var bestRatio = 0.0;
      // another rank of a skill already taken
      _rank.forEach((id, r) {
        final k = db.skillById[id]!;
        if (k.maxLevel > r && k.cost <= left) {
          final ratio = _value(k, totals) / k.cost;
          if (ratio > bestRatio)
            (bestRatio, bestRank, bestPath) = (ratio, k, null);
        }
      });
      // a new skill, with the connectors on the way
      for (final k in db.skills) {
        final d = dist[k.id];
        if (_rank.containsKey(k.id) ||
            k.type == 'Root' ||
            d == null ||
            d > left ||
            d == 0) {
          continue;
        }
        if (_value(k, totals) == 0) continue;
        final path = <Skill>[];
        var cur = k.id;
        while (!_rank.containsKey(cur) && db.skillById[cur]?.type != 'Root') {
          path.insert(0, db.skillById[cur]!);
          final p = prev[cur];
          if (p == null) break;
          cur = p;
        }
        final worth = path.fold(0.0, (v, s) => v + _value(s, totals));
        final ratio = worth / d;
        if (ratio > bestRatio)
          (bestRatio, bestRank, bestPath) = (ratio, null, path);
      }
      if (bestRank != null) {
        final k = bestRank!;
        _rank[k.id] = _rank[k.id]! + 1;
        steps.add(ProjectedStep(k, _rank[k.id]!));
        left -= k.cost;
        spent += k.cost;
      } else if (bestPath != null) {
        for (final k in bestPath!) {
          _rank[k.id] = 1;
          steps.add(ProjectedStep(k, 1));
          left -= k.cost;
          spent += k.cost;
        }
      } else {
        break;
      }
    }
  }

  /// 0..1: how much of what the tree offers this goal on an axis is taken.
  double share(String axis, {bool projected = true}) {
    final m = axisMax[axis] ?? 0;
    if (m == 0) return 0;
    return (((projected ? after : before)[axis] ?? 0) / m).clamp(0.0, 1.0);
  }
}
