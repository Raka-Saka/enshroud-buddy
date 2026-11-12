import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n.dart';
import '../labels.dart';
import 'game_db.dart';
import 'live_state.dart';

/// Skill points: what the level and knowledge give, what the learned nodes cost.
class SkillPoints {
  SkillPoints(GameDb db, LiveState s) {
    final b = db.balancing;
    // points come with each level gained, so level 1 gives none (checked against the game: level 39, 37 from
    // knowledge and 110 spent leave 3, (39 - 1) x 2 + 37 - 110)
    fromLevel = (s.level - 1).clamp(0, 1 << 20) * (b?.skillPointsPerLevel ?? 0);
    fromKnowledge = 0;
    for (final (k, n) in b?.skillPointUnlocks ?? const <(String, int)>[]) {
      if (s.knowledge.contains(k)) fromKnowledge += n;
    }
    spent = 0;
    s.skills.forEach(
      (id, rank) =>
          spent += (db.skillById[id]?.cost ?? 0) * (rank < 1 ? 1 : rank),
    );
  }
  late final int fromLevel;
  late int fromKnowledge, spent;
  int get total => fromLevel + fromKnowledge;
  int get free => total - spent;
}

/// Points per archetype and per class among learned nodes.
class BuildProfile {
  BuildProfile(GameDb db, Map<String, int> learned) {
    learned.forEach((id, rank) {
      final k = db.skillById[id];
      if (k == null || k.type == 'Root') return;
      final pts = k.cost * (rank < 1 ? 1 : rank);
      archetypes[k.archetype] = (archetypes[k.archetype] ?? 0) + pts;
      if (k.cls != 'Neutral') classes[k.cls] = (classes[k.cls] ?? 0) + pts;
    });
  }
  final archetypes = <String, int>{};
  final classes = <String, int>{};

  String? get mainClass =>
      classes.isEmpty
          ? null
          : classes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

  List<MapEntry<String, int>> get topArchetypes =>
      archetypes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
}

/// Cheapest way through the tree from what is learned (or any Spark) to a target node.
List<Skill> pathTo(GameDb db, Set<String> learned, String target) {
  final dist = <String, int>{};
  final prev = <String, String>{};
  final queue = SplayTreeSet<(int, String)>(
    (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
  );
  for (final k in db.skills) {
    if (learned.contains(k.id) || k.type == 'Root') {
      dist[k.id] = 0;
      queue.add((0, k.id));
    }
  }
  while (queue.isNotEmpty) {
    final (d, id) = queue.first;
    queue.remove(queue.first);
    if (id == target) break;
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
  final path = <Skill>[];
  var cur = target;
  while (!learned.contains(cur) && db.skillById[cur]?.type != 'Root') {
    final k = db.skillById[cur];
    if (k == null) break;
    path.insert(0, k);
    final p = prev[cur];
    if (p == null) break;
    cur = p;
  }
  return path;
}

/// Skill nodes I plan to take, kept on the phone.
class SkillPlan extends ChangeNotifier {
  final Set<String> targets = {};

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        'skill_plan',
      );
      if (raw != null) targets.addAll(List<String>.from(jsonDecode(raw)));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> toggle(String id) async {
    targets.contains(id) ? targets.remove(id) : targets.add(id);
    await _save();
  }

  /// Replace the whole plan (a projection adopted as the plan).
  Future<void> replace(Iterable<String> ids) async {
    targets
      ..clear()
      ..addAll(ids);
    await _save();
  }

  Future<void> _save() async {
    await (await SharedPreferences.getInstance()).setString(
      'skill_plan',
      jsonEncode(targets.toList()),
    );
    notifyListeners();
  }

  /// Every node needed for all targets, in order, without duplicates.
  List<Skill> nodes(GameDb db, Set<String> learned) {
    final seen = <String>{};
    final out = <Skill>[];
    for (final t in targets) {
      for (final k in pathTo(db, {...learned, ...seen}, t)) {
        if (seen.add(k.id)) out.add(k);
      }
    }
    return out;
  }
}

/// What a build values, read from the learned skills plus the skill plan: class shares,
/// weapon types and stat weights. Planned skills count 1.5x: they are where the build is going.
class BuildTarget {
  BuildTarget(
    GameDb db,
    Map<String, int> learned,
    List<Skill> planned, {
    String? onlyClass,
  }) {
    void add(Skill k, double pts) {
      if (k.type == 'Root') return;
      skills.add(k.name);
      if (k.cls != 'Neutral') classes[k.cls] = (classes[k.cls] ?? 0) + pts;
      final text = '${k.name} ${_effect(k.description)}'.toLowerCase();
      _skillWords.forEach((trait, words) {
        if (words.any(text.contains))
          traits[trait] = (traits[trait] ?? 0) + pts;
      });
    }

    learned.forEach((id, rank) {
      final k = db.skillById[id];
      if (k != null) add(k, (k.cost * (rank < 1 ? 1 : rank)).toDouble());
    });
    for (final k in planned) {
      add(k, k.cost * 1.5);
    }
    learnedCount = learned.length;
    plannedCount = planned.length;
    if (onlyClass != null) {
      classes
        ..clear()
        ..[onlyClass] = 1;
    }
    final total = classes.values.fold(0.0, (a, b) => a + b);
    if (total > 0) classes.updateAll((_, v) => v / total);
    // everyone needs some Health, Stamina and Time in the Shroud
    for (final (t, w) in const [
      ('health', 2.0),
      ('stamina', 1.0),
      ('shroud', 1.0),
    ]) {
      traits[t] = (traits[t] ?? 0) + w;
    }
    for (final MapEntry(key: wt, value: from) in _weaponTraits.entries) {
      var w = (classes[ItemStats.weaponClass[wt]] ?? 0) * 10;
      for (final (t, f) in from) {
        w += (traits[t] ?? 0) * f;
      }
      weapons[wt] = w;
    }
  }

  /// Class shares of the build's points (sum 1), weapon types and traits by weight.
  final classes = <String, double>{};
  final weapons = <String, double>{};
  final traits = <String, double>{};

  /// Names of the build's skills: gear perks with these names strengthen it.
  final skills = <String>{};
  late final int learnedCount, plannedCount;

  double get mainShare => classes.values.fold(0.0, (a, b) => a > b ? a : b);
  double get maxWeapon => weapons.values.fold(0.0, (a, b) => a > b ? a : b);
  late final double maxWeight = traits.values.fold(
    1.0,
    (a, b) => a > b ? a : b,
  );

  /// 0..1: how well a weapon type fits, relative to the build's favourite.
  double weaponFit(String type) =>
      maxWeapon == 0 ? 0.5 : (weapons[type] ?? 0) / maxWeapon;

  /// 0..1: how well an item's class fits, relative to the main class; neutral items 0.5.
  double classFit(String? cls) =>
      cls == null || mainShare == 0 ? 0.5 : (classes[cls] ?? 0) / mainShare;

  /// Favourite weapon types and the top traits, for display.
  List<String> get topWeapons => [
    for (final e
        in (weapons.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value))))
      if (e.value >= maxWeapon * 0.6) e.key,
  ];
  List<String> get topTraits => [
    for (final e in (traits.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(6))
      traitName(e.key),
  ];

  final _weights = <String, double>{};

  /// How much the build values a stat or perk label ("Ranged Critical Strike Chance", "Mana Leech").
  double weight(String label) => _weights.putIfAbsent(label, () {
    final l = label.toLowerCase().trim();
    if (_skipLabel.any(l.contains)) return 0;
    if (l.contains('resistance') && !l.contains('shroud')) return 0;
    var w = 0.0;
    _labelWords.forEach((trait, words) {
      if (words.any(l.contains)) w += traits[trait] ?? 0;
    });
    return w;
  });

  /// A skill's effect without the glossary paragraphs ("Parry\nYou can block...", "Cost: 10 Mana").
  static String _effect(String? d) {
    final out = <String>[];
    for (final para in (d ?? '').split('\n\n')) {
      final first = para.trim().split('\n').first.trim();
      if (out.isNotEmpty &&
          first.split(' ').length <= 4 &&
          !first.endsWith('.')) {
        break;
      }
      out.add(para);
    }
    return out.join(' ');
  }

  /// A trait's name, for display.
  static String traitName(String key) => switch (key) {
    'bow' => tr('Bows'),
    'dagger' => tr('Daggers'),
    'wand' => tr('Wands'),
    'staff' => tr('Staves'),
    'one-handed' => tr('One-handed'),
    'two-handed' => tr('Two-handed'),
    'melee' => tr('Melee'),
    'ranged' => tr('Ranged'),
    'magic' => tr('Magic'),
    'critical' => tr('Critical strikes'),
    'backstab' => tr('Backstab'),
    'sneak' => tr('Sneak attacks'),
    'merciless' => tr('Merciless attacks'),
    'skillshot' => tr('Skillshots'),
    'parry' => tr('Parry'),
    'mana' => tr('Mana'),
    'stamina' => tr('Stamina'),
    'health' => tr('Health'),
    'fire' => tr('Fire'),
    'ice' => tr('Ice'),
    'shock' => tr('Shock'),
    'shroud' => tr('Shroud time'),
    _ => key,
  };

  /// Words in a skill's effect that mark a trait.
  static const _skillWords = {
    'bow': ['bow'],
    'dagger': ['dagger'],
    'wand': ['wand'],
    'staff': ['staff', 'staves'],
    'one-handed': ['one-handed'],
    'two-handed': ['two-handed', 'greatsword', 'hammer'],
    'melee': ['melee', 'strength'],
    'ranged': ['ranged', 'dexterity', 'arrow'],
    'magic': ['magic', 'intelligence', 'spell'],
    'critical': ['critical strike'],
    'backstab': ['backstab'],
    'sneak': ['sneak'],
    'merciless': ['merciless'],
    'skillshot': ['skillshot'],
    'parry': ['parry', 'block'],
    'mana': ['mana', 'spirit'],
    'stamina': ['stamina', 'endurance'],
    'health': ['health', 'constitution'],
    'fire': ['fire damage'],
    'ice': ['ice damage'],
    'shock': ['shock damage'],
    'shroud': ['in the shroud'],
  };

  /// Words in a gear or food stat label that a trait raises.
  static const _labelWords = {
    'bow': ['bow'],
    'dagger': ['dagger'],
    'wand': ['wand'],
    'staff': ['staff'],
    'one-handed': ['one-handed'],
    'two-handed': ['two-handed', 'greatsword'],
    'melee': ['melee'],
    'ranged': ['ranged', 'skillshot'],
    'magic': ['magic'],
    'critical': ['critical'],
    'backstab': ['backstab'],
    'sneak': ['sneak'],
    'merciless': ['merciless'],
    'skillshot': ['skillshot'],
    'parry': ['parry', 'block'],
    'mana': ['mana'],
    'stamina': ['stamina'],
    'health': ['health', 'life leech'],
    'fire': ['fire'],
    'ice': ['ice'],
    'shock': ['shock'],
    'shroud': ['shroud'],
  };

  /// Labels that are costs, delays or about enemy kinds, not something to stack.
  static const _skipLabel = [
    'damage against',
    'cost',
    'delay',
    'charge time',
    'item level',
    'duration',
    'comfort',
    'enemies',
  ];

  /// Which traits favour each weapon type (on top of its class share).
  static const _weaponTraits = {
    'Bow': [('bow', 1.0), ('ranged', 0.5)],
    'Dagger': [('dagger', 1.0), ('backstab', 0.5), ('sneak', 0.3)],
    'Wand': [('wand', 1.0), ('magic', 0.5)],
    'Staff': [('staff', 1.0), ('magic', 0.5)],
    'Sword': [('one-handed', 1.0), ('melee', 0.5)],
    'Axe': [('one-handed', 1.0), ('melee', 0.5)],
    'Mace': [('one-handed', 1.0), ('melee', 0.5)],
    'Greatsword': [('two-handed', 1.0), ('melee', 0.5)],
    'Hammer': [('two-handed', 1.0), ('melee', 0.5)],
    'Two-handed axe': [('two-handed', 1.0), ('melee', 0.5)],
    'Shield': [('parry', 0.7), ('one-handed', 0.3)],
  };
}

/// One gear option for a slot: an item I own (with where it is) or one to find.
class GearOption {
  GearOption(
    this.item,
    this.score,
    this.why, {
    this.owned,
    this.where,
    this.level,
    this.current = false,
  });
  final Item item;
  final double score;

  /// What makes it fit: weapon type, class, best stat, perks named after the build's skills.
  final List<String> why;
  final Owned? owned;

  /// Where it is: 'Worn', 'Bag' or a chest's label (English: compared); [place] is the text to show.
  final String? where;

  String? get place => switch (where) {
    'Worn' => tr('Worn'),
    'Bag' => tr('Bag'),
    final w? => shownLabel(w),
    null => null,
  };

  /// The level it's rated at: an owned item's own level, or the level one to find comes at.
  final int? level;

  /// What I use in the slot now: worn, or for weapons the best one I carry.
  final bool current;
}

/// A food for the build, and whether I can eat it now.
class FoodOption {
  FoodOption(this.item, this.score, this.why, this.have, this.canCook);
  final Item item;
  final double score;
  final List<String> why;

  /// How many I own (bag and chests); whether an unlocked recipe can be made from stock.
  final int have;
  final bool canCook;
  bool get ready => have > 0 || canCook;
}

/// Ranks gear and food for a build target: weapon type, class, stats and perks, level, rarity.
class GearAdvisor {
  GearAdvisor(this.db, this.state, this.target) {
    for (final it in db.items.values) {
      final st = it.stats;
      if (st == null) continue;
      for (final (label, v) in st.values) {
        final key = '${st.slot}|$label';
        final n = _num(v);
        if (n > (_max[key] ?? 0)) _max[key] = n;
      }
    }
  }
  final GameDb db;
  final LiveState state;
  final BuildTarget target;

  /// Best value of each stat per slot, to compare items on one scale.
  final _max = <String, double>{};

  static double _num(String v) =>
      double.tryParse(RegExp(r'-?\d+(\.\d+)?').stringMatch(v) ?? '') ?? 0;

  static const slots = [
    'Armour_Head',
    'Armour_UpperBody',
    'Armour_Arms',
    'Armour_LowerBody',
    'Armour_Feet',
    'Armour_Ring',
    'MeleeWeapon',
    'MidRangeWeapon',
    'RangeWeapon',
    'Shield',
  ];

  int get playerLevel => state.level == 0 ? 30 : state.level;

  /// What an item's stats bring the build: weight x value against the slot's best, per stat.
  double _gain(ItemStats st, {Set<String> covered = const {}}) {
    var g = 0.0;
    for (final (label, v) in st.values) {
      final w = target.weight(label);
      final m = _max['${st.slot}|$label'] ?? 0;
      if (w == 0 || m <= 0) continue;
      g +=
          w *
          (_num(v) / m).clamp(0.0, 1.0) *
          (covered.contains(label) ? 0.4 : 1);
    }
    return g / target.maxWeight;
  }

  /// The stat that adds most for the build, if it adds a fair amount.
  String? _bestStat(ItemStats st) {
    var best = 0.0;
    String? label;
    for (final (l, v) in st.values) {
      final m = _max['${st.slot}|$l'] ?? 0;
      if (m <= 0) continue;
      final c = target.weight(l) * (_num(v) / m).clamp(0.0, 1.0);
      if (c > best) (best, label) = (c, l.trim());
    }
    return best / target.maxWeight > 0.3 ? label : null;
  }

  /// The level an item to find comes at: a fixed-level item at its level, one that scales with where it drops
  /// at the player's level, within its range.
  int findLevel(ItemStats st) {
    final r = st.levels;
    if (r == null) return 0;
    return r[0] >= r[1] ? r[1] : playerLevel.clamp(r[0], r[1]);
  }

  (double, List<String>) rate(Item it, {int? level}) {
    final st = it.stats!;
    final why = <String>[];
    final lv = level ?? findLevel(st);
    final fit = lv == 0 ? 0.5 : (lv >= playerLevel ? 1.0 : lv / playerLevel);
    var s = fit * 25 + (Rarity.rank(it.rarity)) * 5;
    final wt = st.weaponType;
    final cf = target.classFit(st.suits);
    if (wt != null) {
      final wf = target.weaponFit(wt);
      s += wf * 35 + cf * 10;
      if (wf >= 0.6) why.add(weaponLabel(wt));
    } else {
      s += cf * 30;
      if (st.suits != null && cf >= 0.6) why.add(classLabel(st.suits!));
    }
    s += 15 * _gain(st).clamp(0.0, 2.0);
    if (_bestStat(st) case final l?) why.add(gt(l));
    for (final p in st.perks) {
      final name = p.replaceAll(RegExp(r' ×\d+$'), '');
      if (target.skills.contains(name)) {
        s += 5;
        if (!why.contains(gt(name))) why.add(gt(name));
      } else {
        s += 3 * target.weight(name) / target.maxWeight;
      }
    }
    return (s, why);
  }

  /// Whether gear is worth suggesting for this build at all.
  bool suits(Item it) {
    final st = it.stats!;
    if (st.weaponType == 'Utility') return false;
    return st.weaponType != null
        ? target.weaponFit(st.weaponType!) >= 0.4
        : target.classFit(st.suits) >= 0.4;
  }

  /// How many of a slot are worn at once (rings: as many as the panel has).
  int _wornAtOnce(String slot) =>
      slot == 'Armour_Ring'
          ? state.equipment
              .where((o) => db.items[o.itemId]?.stats?.slot == slot)
              .length
              .clamp(1, 99)
          : 1;

  /// Per slot: what I use now (worn; for weapons, the best one I carry), then owned items that rate higher
  /// and are no lower in level, even upgraded, best first. Lower-level items stay out: they are no upgrade.
  Map<String, List<GearOption>> owned() {
    final labels = state.labels((id) => db.items[id]?.name ?? id);
    final all = <String, List<GearOption>>{};
    void add(Iterable<Owned> list, String where, {bool current = false}) {
      for (final o in list) {
        final it = db.items[o.itemId];
        final slot = it?.stats?.slot;
        if (slot == null ||
            !slots.contains(slot) ||
            it!.stats!.weaponType == 'Utility')
          continue;
        final (score, why) = rate(it, level: o.level);
        (all[slot] ??= []).add(
          GearOption(
            it,
            score,
            why,
            owned: o,
            where: where,
            level: o.level,
            current: current,
          ),
        );
      }
    }

    add(state.equipment, 'Worn', current: true);
    add(state.carried, 'Bag');
    for (final c in state.containers) {
      add(c.items, labels[c.index]);
    }
    final out = <String, List<GearOption>>{};
    all.forEach((slot, list) {
      list.sort((a, b) => b.score.compareTo(a.score));
      var now = [
        for (final g in list)
          if (g.current) g,
      ];
      if (now.isEmpty) {
        // weapons aren't worn: the ones in the bag are what I fight with
        now =
            [
              for (final g in list)
                if (g.where == 'Bag') g,
            ].take(_wornAtOnce(slot)).toList();
        now = [
          for (final g in now)
            GearOption(
              g.item,
              g.score,
              g.why,
              owned: g.owned,
              where: g.where,
              level: g.level,
              current: true,
            ),
        ];
      }
      final mine = {for (final g in now) g.owned};
      // a new piece replaces the weakest one in use
      final floorLevel =
          now.isEmpty
              ? 0
              : now.map((g) => g.level ?? 0).reduce((a, b) => a < b ? a : b);
      final floorScore =
          now.isEmpty
              ? 0.0
              : now.map((g) => g.score).reduce((a, b) => a < b ? a : b);
      out[slot] =
          now.isEmpty
              // nothing in use: the best piece I own that suits the build, if any
              ? [
                for (final g in list)
                  if (suits(g.item)) g,
              ].take(1).toList()
              : [
                ...now,
                for (final g in list)
                  if (!mine.contains(g.owned) &&
                      g.score > floorScore &&
                      (g.owned?.topLevel ?? g.level ?? 0) >= floorLevel)
                    g,
              ];
    });
    out.removeWhere((_, l) => l.isEmpty);
    return out;
  }

  /// Whether an item can be had now: an unlocked recipe makes it, or it drops (in a chest or at a fixed spot)
  /// at the player's level or below. Recipes still locked and loot that only comes higher are for later.
  bool reachable(Item it) {
    if ((db.madeBy[it.id] ?? const <Recipe>[]).any(
      (r) => state.recipesUnlocked.contains(r.id),
    )) {
      return true;
    }
    if (it.chestKinds.isEmpty && it.fixedPlacements == 0) return false;
    final r = it.stats?.levels;
    return r == null || r[0] <= playerLevel;
  }

  bool _onlyAtFixedSpots(Item it) =>
      it.fixedPlacements > 0 &&
      it.chestKinds.isEmpty &&
      !(db.madeBy[it.id]?.isNotEmpty ?? false);

  /// The best items for a slot in the whole game, for the build, that can be had now.
  List<GearOption> targets(String slot, {int count = 3}) =>
      _ranked(slot).take(count).toList();

  List<GearOption> _ranked(String slot) {
    final list = <GearOption>[];
    for (final it in db.items.values) {
      final st = it.stats;
      if (st?.slot != slot || !suits(it) || !reachable(it)) continue;
      final (score, why) = rate(it);
      list.add(GearOption(it, score, why, level: findLevel(st!)));
    }
    list.sort((a, b) => b.score.compareTo(a.score));
    final seen = <String>{};
    return [
      for (final g in list)
        if (seen.add(g.item.name)) g,
    ];
  }

  /// Items to find for a slot: they rate above everything listed for it in [owned], come at no lower a
  /// level than what's in use, and aren't owned already at that level. A piece that only lies at fixed spots
  /// and is owned is left out: that spot has been looted.
  List<GearOption> upgrades(
    String slot,
    Map<String, List<GearOption>> owned, {
    int count = 3,
  }) {
    final mine = owned[slot] ?? const <GearOption>[];
    final now = mine.where((g) => g.current);
    final floorLevel =
        now.isEmpty
            ? 0
            : now.map((g) => g.level ?? 0).reduce((a, b) => a < b ? a : b);
    final best =
        mine.isEmpty
            ? 0.0
            : mine.map((g) => g.score).reduce((a, b) => a > b ? a : b);
    final ownedAt = <String, int>{};
    for (final o in [
      ...state.equipment,
      ...state.carried,
      for (final c in state.containers) ...c.items,
    ]) {
      final lv = o.topLevel ?? 0;
      if (lv > (ownedAt[o.itemId] ?? -1)) ownedAt[o.itemId] = lv;
    }
    return [
      for (final t in _ranked(slot))
        if (t.score > best &&
            (t.level ?? 0) >= floorLevel &&
            (ownedAt[t.item.id] ?? -1) < (t.level ?? 0) &&
            !(ownedAt.containsKey(t.item.id) && _onlyAtFixedSpots(t.item)))
          t,
    ].take(count).toList();
  }

  /// Food slots: 3, plus one with Dessert Stomach.
  int get foodSlots =>
      3 +
      (state.skills.keys.any(
            (id) => db.skillById[id]?.name == 'Dessert Stomach',
          )
          ? 1
          : 0);

  /// Whether an unlocked recipe for the item can be made now from bag and chests, at a built station.
  bool canMake(Item it) {
    for (final r in db.madeBy[it.id] ?? const <Recipe>[]) {
      if (!state.recipesUnlocked.contains(r.id)) continue;
      final station = db.workshops[r.workshopId]?.itemId;
      if (station != null && (state.placed[station] ?? 0) == 0) continue;
      final enough = r.inputs.every(
        (i) => db.expand(i).fold(0, (n, id) => n + state.owned(id)) >= i.count,
      );
      if (enough) return true;
    }
    return false;
  }

  /// Every buff food (it has a Duration), scored for the build, best first.
  List<FoodOption> food() {
    final out = <FoodOption>[];
    for (final it in db.items.values) {
      final st = it.stats;
      if (st?.slot != 'Consumable' ||
          !st!.values.any((v) => v.$1 == 'Duration') ||
          st.values.any((v) => v.$1 == 'Mana Cost'))
        continue;
      final g = _gain(st);
      if (g <= 0) continue;
      final why = [
        for (final (label, v) in st.values)
          if (target.weight(label) > 0)
            tr('{stat} +{value}', {'stat': gt(label.trim()), 'value': v}),
      ];
      out.add(FoodOption(it, g, why, state.owned(it.id), canMake(it)));
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  /// What to eat now: the best food I have or can cook, preferring different stats.
  List<FoodOption> meal(List<FoodOption> all) {
    final ready = all.where((f) => f.ready).toList();
    final picked = <FoodOption>[];
    final covered = <String>{};
    while (picked.length < foodSlots && ready.isNotEmpty) {
      ready.sort(
        (a, b) => _gain(
          b.item.stats!,
          covered: covered,
        ).compareTo(_gain(a.item.stats!, covered: covered)),
      );
      final f = ready.removeAt(0);
      picked.add(f);
      covered.addAll(f.item.stats!.values.map((v) => v.$1));
    }
    return picked;
  }

  /// How to get an item: craft (unlocked?), a fixed spot, or chest kinds.
  List<String> howToGet(Item it) => [
    for (final r in db.madeBy[it.id] ?? const <Recipe>[])
      state.recipesUnlocked.contains(r.id)
          ? tr('Craft at {station}', {
            'station': gtn(db.workshops[r.workshopId]?.name) ?? '?',
          })
          : tr('Craft at {station} (locked)', {
            'station': gtn(db.workshops[r.workshopId]?.name) ?? '?',
          }),
    if (it.fixedPlacements > 0)
      trn(
        it.fixedPlacements,
        'Unique loot: {n} spot on the map',
        'Unique loot: {n} spots on the map',
      ),
    if (db.bossSpots(it.id).map((p) => p.title).toSet() case final b
        when b.isNotEmpty)
      tr('Drops from: {bosses}', {'bosses': b.map(gt).join(', ')}),
    if (it.chestKinds.isNotEmpty)
      tr('Random loot: {kinds}', {
        'kinds': it.chestKinds.take(3).map(gt).join(', '),
      }),
  ];
}
