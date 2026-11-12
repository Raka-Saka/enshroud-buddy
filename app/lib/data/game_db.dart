import 'dart:math' as math;
import 'dart:typed_data';

import '../l10n.dart';

/// The map grid and the world's size, from game.json "world" (tools/world.py reads them from the game's own
/// map textures). Set when the game data loads; the defaults are this game version's.
class World {
  /// Map grid side in pixels (the save's fog of war), and the world's side in metres.
  static double mapPx = 1280, sizeM = 10240;

  /// Map pixels per cell of the gather and region grids (the game's 128 m tiles), and cells across.
  static double cellPx = 16;
  static int grid = 80;

  static double get mPerPx => sizeM / mapPx;

  static void load(Map<String, dynamic>? j) {
    if (j == null) return;
    mapPx = (j['map_px'] as num?)?.toDouble() ?? mapPx;
    sizeM = (j['size_m'] as num?)?.toDouble() ?? sizeM;
    cellPx = (j['cell_px'] as num?)?.toDouble() ?? cellPx;
    grid = (j['grid'] as num?)?.toInt() ?? grid;
  }
}

/// Offline game data built by tools/build_db.py from the game's own files.
class Item {
  Item(this.id, Map<String, dynamic> j)
    : name = j['n'],
      category = j['c'],
      rarity = j['r'],
      description = j['d'],
      lore = j['l'],
      hint = j['h'],
      maxStack = j['s'] ?? 1,
      stats = j['st'] == null ? null : ItemStats(j['st']),
      chestKinds = List<String>.from(j['lc'] ?? const []),
      fixedPlacements = j['fx'] ?? 0,
      gatherCells = j['gn'] ?? 0,
      gatherMixed = j['gm'] == 1,
      regions = List<String>.from(j['rz'] ?? const []),
      underwater = j['uw'] == 1,
      inShroud = j['sh'] == 1,
      everywhere = j['ew'];

  final String id, name, category, rarity;
  final String? description, lore, hint;
  final int maxStack;
  final ItemStats? stats;

  /// Chest kinds whose loot pool can roll this item ("Gold chest", ...).
  final List<String> chestKinds;

  /// How many fixed world placements hold this item (unique loot).
  final int fixedPlacements;

  /// How many 128 m map cells it can be gathered in, and a hint for terrain basics ("Fell any tree").
  final int gatherCells;
  final String? everywhere;

  /// Its only mapped spots are random containers that give one of several items (ancient ore carts).
  final bool gatherMixed;

  /// Regions its hint names ("Cinder's Cradle"), and whether the hint says underwater.
  final List<String> regions;
  final bool underwater;

  /// The hint places it in the Shroud ("Kindlewastes Shroud").
  final bool inShroud;

  /// Found nearly everywhere (Twigs, Stone, Plant Fiber, Wood Logs): no need to plan where.
  bool get isCommon => everywhere != null || gatherCells >= 1000;
}

/// Loot setting of a chest kind: rarity odds (%) and its item pool.
class LootSetting {
  LootSetting(Map<String, dynamic> j)
    : odds = [for (final o in j['o']) (o as num).toDouble()],
      poolSize = j['n'],
      categories = Map<String, int>.from(j['c']),
      examples = List<String>.from(j['ex']),
      pool = List<String>.from(j['pool'] ?? const []);
  final List<double> odds;
  final int poolSize;
  final Map<String, int> categories;
  final List<String> examples;

  /// Every item this chest kind can roll.
  final List<String> pool;
  static const rarities = Rarity.order;
}

/// The game's rarities, lowest first: loot odds are listed in this order. Named once here; an item with a
/// rarity not in it ranks lowest.
class Rarity {
  static const order = ['Common', 'Uncommon', 'Rare', 'Epic', 'Legendary'];
  static int rank(String? r) {
    final i = order.indexOf(r ?? '');
    return i < 0 ? 0 : i;
  }
}

/// What the game shows on an item card: slot, level range, values, perks.
class ItemStats {
  ItemStats(Map<String, dynamic> j)
    : slot = j['sl'],
      levels = (j['lv'] as List?)?.cast<int>(),
      values = [
        for (final v in j['v'] ?? const []) (v[0] as String, v[1] as String),
      ],
      perks = List<String>.from(j['pk'] ?? const []),
      armor = List<String>.from(j['ar'] ?? const []),
      damage = List<String>.from(j['dm'] ?? const []),
      comfort = j['cf'] ?? 0,
      alignment = j['al'],
      weaponType = j['wt'];

  final String? slot;
  final List<int>? levels;
  final List<(String, String)> values;
  final List<String> perks, armor, damage;
  final int comfort;

  /// Warrior, Ranger or Mage; null for neutral items.
  final String? alignment;

  /// Bow, Staff, Wand, Dagger, Sword, ... or Utility (grenades, torches); null for non-weapons.
  final String? weaponType;

  static const weaponClass = {
    'Bow': 'Ranger',
    'Dagger': 'Ranger',
    'Staff': 'Mage',
    'Wand': 'Mage',
    'Shield': 'Warrior',
    'Greatsword': 'Warrior',
    'Two-handed axe': 'Warrior',
    'Hammer': 'Warrior',
    'Sword': 'Warrior',
    'Axe': 'Warrior',
    'Mace': 'Warrior',
  };

  /// The class this item suits: its alignment, else its weapon type's class.
  String? get suits => alignment ?? weaponClass[weaponType];

  /// A numeric value by label ("Health", "Stamina", ...), 0 when absent.
  int value(String label) {
    for (final (l, v) in values) {
      if (l == label) return int.tryParse(v.replaceAll('%', '')) ?? 0;
    }
    return 0;
  }

  static const slotLabels = {
    'Armour_Head': 'Head',
    'Armour_UpperBody': 'Chest',
    'Armour_Arms': 'Hands',
    'Armour_LowerBody': 'Legs',
    'Armour_Feet': 'Feet',
    'Armour_Ring': 'Ring',
    'Backpack': 'Backpack',
    'Glider': 'Glider',
    'HookShot': 'Grappling hook',
    'Spell': 'Spell',
    'MeleeWeapon': 'Melee weapon',
    'MidRangeWeapon': 'Staff / wand',
    'RangeWeapon': 'Bow',
    'Shield': 'Shield',
    'Arrow': 'Arrows',
    'Consumable': 'Consumable',
    'Tool': 'Tool',
  };
  String get slotLabel => slotLabels[slot] ?? (slot ?? '');

  /// What it does for its wearer, by name: its perks (a skill, "Fatal Precision", or a stat, "Health ×2")
  /// and values ("Mana Regeneration 12%"), each with what the card shows after the name ("×2", "12%", or
  /// both). Not the item's level, nor furniture comfort.
  late final Map<String, String> effects = () {
    final out = <String, String>{};
    for (final p in perks) {
      final m = RegExp(r'^(.*?)\s*×(\d+)$').firstMatch(p);
      // a perk the game left unnamed shows its id: "Perk_Damage_Cut" reads "Damage Cut"
      final n = (m?[1] ?? p).replaceFirst('Perk_', '').replaceAll('_', ' ');
      out[n.trim()] = m == null ? '' : '×${m[2]}';
    }
    for (final (l, v) in values) {
      final n = l.trim();
      if (n == 'Item Level' || n.startsWith('Comfort')) continue;
      out[n] = [if (out[n]?.isNotEmpty ?? false) out[n]!, v].join(' · ');
    }
    return out;
  }();

  /// Ranks items giving [effect], strongest first: a perk's ×n (one when plain), then its value's number.
  (int, double) strength(String effect) {
    final shown = effects[effect] ?? '';
    final times = RegExp(r'×(\d+)').firstMatch(shown);
    final number = RegExp(
      r'(\d+(?:\.\d+)?)',
    ).firstMatch(shown.replaceFirst(RegExp(r'×\d+( · )?'), ''));
    return (
      times == null ? 1 : int.parse(times[1]!),
      number == null ? 0 : double.parse(number[1]!),
    );
  }
}

class Workshop {
  Workshop(this.id, Map<String, dynamic> j)
    : name = j['n'],
      kind = j['k'],
      itemId = j['it'];

  final String id, name;

  /// The placeable item for a station or prop; null for artisans.
  final String? itemId;

  /// station, npc (artisan) or prop (station upgrade).
  final String kind;
}

class ItemStack {
  ItemStack(List<dynamic> j) : ref = j[0], count = j[1];

  /// An item id, or `cat:<id>` for "any item of this category".
  final String ref;
  final int count;
  bool get isCategory => ref.startsWith('cat:');
}

/// The numbers runtime unlock conditions compare against: Flame strength, player level, the highest
/// altar level and how many altars there are.
class UnlockContext {
  const UnlockContext({
    required this.flame,
    required this.level,
    required this.altar,
    required this.altars,
    this.placed = const {},
  });
  final int flame, level, altar, altars;

  /// Objects placed in the world by item id: stations put out for artisans.
  final Map<String, int> placed;

  bool test(String kind, String op, int v) {
    final x = switch (kind) {
      'flame' => flame,
      'level' => level,
      'altar' => altar,
      _ => altars,
    };
    return switch (op) {
      '<' => x < v,
      '=' => x == v,
      _ => x > v,
    };
  }
}

/// What unlocks a recipe: an AND/OR tree whose leaves are knowledge flags from the save, or number
/// conditions (Flame strength > 5, player level < 10, ...).
class Unlock {
  Unlock(Map<String, dynamic> j)
    : op = j['op'],
      text = j['t'],
      knowledge = j['k'],
      itemId = j['i'],
      npc = j['n'],
      placed = List<String>.from(j['pl'] ?? const []),
      sheltered = j['sh'] == 1,
      runtime =
          j['rt'] == null
              ? null
              : (
                j['rt'][0] as String,
                j['rt'][1] as String,
                (j['rt'][2] as num).toInt(),
              ),
      children = [for (final c in j['c'] ?? const []) Unlock(c)];

  final String? op, text, knowledge, itemId;

  /// An artisan condition: the artisan's item id (in the world's knowledge once rescued), item ids of
  /// stations placed for them, and whether it asks that they're sheltered (tools/build_db.py Unlocks).
  final String? npc;
  final List<String> placed;
  final bool sheltered;

  /// A number condition: (flame | level | altar | altars, > | < | =, value).
  final (String, String, int)? runtime;
  final List<Unlock> children;
  bool get isLeaf => op == null;

  /// true / false when the save can tell, null when it can't (a number condition without a [ctx], an
  /// artisan sheltered with none of their stations out).
  bool? met(Set<String> known, [UnlockContext? ctx]) {
    if (isLeaf) {
      if (runtime case (final k, final o, final v)) {
        return ctx?.test(k, o, v);
      }
      if (npc != null || placed.isNotEmpty) {
        // not rescued yet: nothing for them can be done
        if (npc != null && !known.contains(npc)) return false;
        if (placed.isEmpty) return npc != null && !sheltered ? true : null;
        if (ctx == null) return null;
        // a station of theirs placed: they live in a base (sheltered); the station asked for is out
        if (placed.any((i) => (ctx.placed[i] ?? 0) > 0)) return true;
        return sheltered ? null : false;
      }
      return knowledge == null ? null : known.contains(knowledge);
    }
    final r = children.map((c) => c.met(known, ctx)).toList();
    if (op == 'OR')
      return r.contains(true) ? true : (r.contains(null) ? null : false);
    return r.contains(false) ? false : (r.contains(null) ? null : true);
  }

  Iterable<Unlock> get leaves =>
      isLeaf ? [this] : children.expand((c) => c.leaves);

  /// Completed for progress counts: met, or unknown with every checkable flag set (and every artisan
  /// asked about rescued).
  bool likely(Set<String> known, [UnlockContext? ctx]) =>
      met(known, ctx) ??
      leaves.every(
        (l) =>
            (l.knowledge == null || known.contains(l.knowledge)) &&
            (l.npc == null || known.contains(l.npc)),
      );
}

class Recipe {
  Recipe(Map<String, dynamic> j)
    : id = j['id'],
      unlock = j['u'] == null ? null : Unlock(j['u']),
      workshopId = j['w'],
      inputs = [for (final i in j['i']) ItemStack(i)],
      outputs = [for (final o in j['o']) ItemStack(o)],
      props = List<String>.from(j['p']),
      seconds = (j['t'] as num).toDouble();

  final String id, workshopId;
  final Unlock? unlock;
  final List<ItemStack> inputs, outputs;
  final List<String> props;
  final double seconds;
}

class SetEntry {
  SetEntry(Map<String, dynamic> j)
    : itemId = j['i'],
      hints = List<String>.from(j['h']),
      done = j['d'] == null ? null : Unlock(j['d']);
  final String itemId;
  final List<String> hints;

  /// Completion condition, checked against the save's knowledge.
  final Unlock? done;
}

class ItemSet {
  ItemSet(Map<String, dynamic> j)
    : category = j['c'] ?? 'Other',
      name = j['n'],
      entries = [for (final e in j['e']) SetEntry(e)];
  final String category, name;
  final List<SetEntry> entries;
}

class Page {
  Page(Map<String, dynamic> j)
    : title = j['n'],
      text = j['t'],
      done = j['d'] == null ? null : Unlock(j['d']);
  final String? title;
  final String text;

  /// Lore: found. Quest step: completed.
  final Unlock? done;
}

/// A point on the world map (1280 px fog-map grid): place label, lore note or loot chest.
class Poi {
  Poi(Map<String, dynamic> j)
    : cat = j['c'],
      kind = j['k'],
      title = j['t'],
      x = (j['x'] as num).toDouble(),
      y = (j['y'] as num).toDouble(),
      height = (j['h'] as num?)?.toDouble(),
      done = j['d'] == null ? null : Unlock(j['d']),
      lore = (j['l'] as List?)?.cast<int>(),
      lootSetting = j['ls'],
      fixed = List<String>.from(j['sp'] ?? const []),
      itemId = j['i'],
      candidates = j['n'] ?? 0,
      areaLevel = j['lv'] ?? 0,
      inside = j['in'] == 1,
      fishTable = j['ft'],
      head = j['hd'],
      hall = j['hl'];

  /// label, lore, chest, fish (a fishing spot)...

  final String cat;
  final String? kind;
  final String title;
  final double x, y;

  /// Height in metres (null for an area of loot and older data).
  final double? height;

  /// Labels: completed (camp cleared, shrine lit...).
  final Unlock? done;

  /// Lore notes: [doc index, page index] into GameDb.lore.
  final List<int>? lore;

  /// Chests: loot setting id; fixed unique items placed in this chest.
  final String? lootSetting;
  final List<String> fixed;

  /// cat == 'special': an item in one of [candidates] chests around here.
  final String? itemId;
  final int candidates;

  /// Chests: the area level loot drops at (0 = scales with the player).
  final int areaLevel;

  /// Inside the Hollow Halls (the game keeps their insides in the world's far north-west corner); [height]
  /// is then set for every kind of point.
  final bool inside;

  /// Fishing spots: their table in GameDb.fish.
  final String? fishTable;

  /// Inside the Hollow Halls: which hall (HallLayout.halls).
  final int? hall;

  /// A trophy boss's spawn point (kind 'Boss'): the head item it drops; [done] is having had one.
  final String? head;

  bool get isUnique => fixed.isNotEmpty || cat == 'special';

  /// The unique loot here: what a chest always holds, or a special point's item.
  List<String> get loot =>
      cat == 'special' ? [if (itemId != null) itemId!] : fixed;
}

/// What a fishing spot gives (keen::fishing::FishSpawnTableResource): fish as a share of the fish caught,
/// with the time of day they bite ('' all day), and the chances of trash and a wet boot instead.
class FishTable {
  FishTable(Map<String, dynamic> j)
    : trash = (j['tr'] as num).toDouble(),
      boot = (j['bt'] as num).toDouble(),
      fish = [
        for (final f in j['f'] as List)
          (
            id: f[0] as String,
            share: (f[1] as num).toDouble(),
            time: f[2] as String,
          ),
      ];
  final double trash, boot;
  final List<({String id, double share, String time})> fish;
}

/// The Hollow Halls' layout (tools/build_db.py hall_layout, assign_halls): placed objects inside them, which
/// draw the rooms and corridors. [points] holds x, y (tenths of a map pixel), height (metres) and the hall
/// (index into [halls], -1 unknown) for each.
class HallLayout {
  HallLayout(Map<String, dynamic> j)
    : x0 = (j['b'][0] as num).toDouble(),
      y0 = (j['b'][1] as num).toDouble(),
      x1 = (j['b'][2] as num).toDouble(),
      y1 = (j['b'][3] as num).toDouble(),
      stride = j['h'] == null ? 3 : 4,
      points = Int32List.fromList((j['p'] as List).cast<int>()),
      halls = [for (final h in j['h'] ?? const []) Hall(h)],
      damage = j['dmg'] == null ? null : HallDamage(j['dmg']);
  final double x0, y0, x1, y1;

  /// What the Hollow take more and less damage from (the wiki's enemy pages); null when unknown.
  final HallDamage? damage;

  /// Values per point: 4 (x, y, height, hall), or 3 in data from before halls were told apart.
  final int stride;
  final Int32List points;
  final List<Hall> halls;

  bool contains(double x, double y) => x >= x0 && x <= x1 && y >= y0 && y <= y1;

  /// The hall of the layout point nearest to (x, y) at [height] (height counts double), or null.
  int? hallAt(double x, double y, double height) {
    if (stride < 4 || !contains(x, y)) return null;
    var best = double.infinity;
    int? k;
    for (var i = 0; i + 3 < points.length; i += 4) {
      final dx = (points[i] / 10 - x) * World.mPerPx;
      final dy = (points[i + 1] / 10 - y) * World.mPerPx;
      final dh = points[i + 2] - height;
      final d = dx * dx + dy * dy + 4 * dh * dh;
      if (d < best) (best, k) = (d, points[i + 3]);
    }
    return k == null || k < 0 ? null : k;
  }

  /// The hall a world entrance leads into: the one whose entrance is nearest to (x, y).
  int? entranceAt(double x, double y) {
    int? k;
    var best = double.infinity;
    for (var i = 0; i < halls.length; i++) {
      final d = math.pow(halls[i].x - x, 2) + math.pow(halls[i].y - y, 2);
      if (d < best) (best, k) = (d.toDouble(), i);
    }
    return best < 25 ? k : null;
  }
}

/// One of the Hollow Halls: where its entrance stands in the world, its level, and the box its inside fills
/// in the far corner.
class Hall {
  Hall(Map<String, dynamic> j)
    : x = (j['x'] as num).toDouble(),
      y = (j['y'] as num).toDouble(),
      level = j['lv'] as int,
      region = j['n'],
      x0 = (j['b'][0] as num).toDouble(),
      y0 = (j['b'][1] as num).toDouble(),
      x1 = (j['b'][2] as num).toDouble(),
      y1 = (j['b'][3] as num).toDouble(),
      contents = Map<String, int>.from(j['in'] ?? const {});
  final double x, y;
  final int level;

  /// How many of each kind of thing it holds: hollow, fell, beasts, elite, raisers (bone piles), hook (grapple
  /// points), climb, doors (rune barriers), glide (updrafts and glider barriers), traps, fire, shock.
  final Map<String, int> contents;

  /// The region its entrance's biome names (Springlands...); null in older data.
  final String? region;
  final double x0, y0, x1, y1;
}

/// Damage types (the game's names: physicalBlunt, magicalIce...) a faction takes more of and resists, and
/// the enemies that says it.
class HallDamage {
  HallDamage(Map<String, dynamic> j)
    : weak = List<String>.from(j['weak'] ?? const []),
      strong = List<String>.from(j['strong'] ?? const []),
      from = List<String>.from(j['from'] ?? const []);
  final List<String> weak, strong, from;
}

/// The game's BalancingTable: Shroud time, Flame levels, cold and oxygen.
class Balancing {
  Balancing(Map<String, dynamic> j)
    : flameMax = j['flame_level_max'],
      fogBase = j['fog_base_s'],
      fogPerFlame = j['fog_per_flame_s'],
      oxygen = j['oxygen_s'],
      noFreezeFlameLevel = j['no_freeze_flame_level'],
      skillPointsPerLevel = j['skill_points_per_level'] ?? 2,
      skillPointUnlocks = [
        for (final u in j['skill_point_unlocks'] ?? const [])
          ((u as String).split(':')[0], int.parse(u.split(':')[1])),
      ],
      altarsPerFlame = [for (final a in j['altars_per_flame']) int.parse('$a')],
      zonePerAltar = [
        for (final z in j['buildzone_per_altar'] ?? const []) int.parse('$z'),
      ],
      playerLevelMax = j['player_level_max'];
  final int flameMax, fogBase, fogPerFlame, oxygen, noFreezeFlameLevel;

  /// Side of the build zone in metres by altar level (index 0 = none), and the highest player level.
  final List<int> zonePerAltar;
  final int? playerLevelMax;
  String zoneAt(int altar) =>
      zonePerAltar.isEmpty
          ? '?'
          : tr('{n} m', {
            'n': zonePerAltar[altar.clamp(0, zonePerAltar.length - 1)],
          });
  final int skillPointsPerLevel;

  /// (knowledge id, points): skill points granted by discoveries.
  final List<(String, int)> skillPointUnlocks;
  final List<int> altarsPerFlame;
  int altarsAt(int flame) =>
      altarsPerFlame[flame.clamp(0, altarsPerFlame.length - 1)];
}

/// Where the skill tree sits in the game's layout: the centre is the Root nodes' centroid, the extent
/// covers every node, and each archetype's label goes at the mean angle of its skills (tools/build_db.py
/// names the archetypes by 30-degree sector).
class SkillLayout {
  SkillLayout(List<Skill> skills) {
    final roots = skills.where((k) => k.type == 'Root').toList();
    final src = roots.isNotEmpty ? roots : skills;
    final n = src.isEmpty ? 1 : src.length;
    centre = (
      src.fold(0.0, (a, k) => a + k.x) / n,
      src.fold(0.0, (a, k) => a + k.y) / n,
    );
    var lo = double.infinity, hi = -double.infinity;
    for (final k in skills) {
      lo = math.min(lo, math.min(k.x - centre.$1, k.y - centre.$2));
      hi = math.max(hi, math.max(k.x - centre.$1, k.y - centre.$2));
    }
    // square around the centre with a margin for the labels and frames
    half = skills.isEmpty ? 2500 : math.max(-lo, hi) + 300;
    final sums = <String, (double, double)>{};
    for (final k in skills) {
      if (k.archetype == 'Centre' || k.archetype == 'Other') continue;
      final a = math.atan2(k.y - centre.$2, k.x - centre.$1);
      final s = sums[k.archetype] ?? (0.0, 0.0);
      sums[k.archetype] = (s.$1 + math.cos(a), s.$2 + math.sin(a));
    }
    labels = [
      for (final e in sums.entries) (e.key, math.atan2(e.value.$2, e.value.$1)),
    ];
  }

  /// Game units: the centre, and half the side of the square that holds the tree.
  late final (double, double) centre;
  late final double half;

  /// (archetype, angle in radians from the centre).
  late final List<(String, double)> labels;

  /// A game position as a fraction (0..1) of the square.
  (double, double) unit(double x, double y) => (
    (x - centre.$1 + half) / (2 * half),
    (y - centre.$2 + half) / (2 * half),
  );
}

class Skill {
  Skill(Map<String, dynamic> j)
    : id = j['id'],
      name = j['n'],
      description = j['d'],
      perLevel = j['pl'],
      type = j['ty'],
      cls = j['cl'] ?? 'Neutral',
      maxLevel = j['mx'] ?? 0,
      cost = j['c'] ?? 1,
      x = (j['x'] as num).toDouble(),
      y = (j['y'] as num).toDouble(),
      links = List<String>.from(j['lk'] ?? const []),
      archetype = j['ar'] ?? 'Other',
      icon = j['ic'],
      guessed = j['g'] == 1,
      axes = List<String>.from(j['fx'] ?? const []),
      weapons = List<String>.from(j['wp'] ?? const []),
      factor = (j['cf'] as num?)?.toDouble() ?? 1;
  final String id, name, type, cls, archetype;

  /// Effect text with the game's numbers filled in (5/10/15% = ranks 1/2/3).
  final String? description, perLevel;
  final int maxLevel, cost;

  /// The numbers' order in the text is a best guess (two values fitted a placeholder equally).
  final bool guessed;

  /// What the skill does (damage, area, survival, sustain, gathering, building, exploration, passives)
  /// and the weapon types it needs; empty weapons = works with anything.
  final List<String> axes, weapons;

  /// How often the effect applies: 0.4 for one enemy kind, throwables or fists; 0.6 for one element.
  final double factor;

  /// Position in the game's skill tree layout (about 1700..6500, centre 4000,4000).
  final double x, y;
  final List<String> links;

  /// Base name of the game's icon (assets/skilltree/icon_<icon>_unlocked.png), if it has one.
  final String? icon;
}

class Doc {
  Doc(Map<String, dynamic> j)
    : name = j['n'],
      category = j['c'] ?? 'Other',
      pages = [for (final p in j['p']) Page(p)],
      main = j['m'] ?? false,
      rewards = List<String>.from(j['rw'] ?? const []);
  final String name, category;
  final List<Page> pages;
  final bool main;
  final List<String> rewards;
}

/// A 128 m map cell (World.cellPx pixels of the map grid) where an item can be picked up or mined.
class GatherCell {
  GatherCell(this.cx, this.cy, this.count, this.areaLevel);
  final int cx, cy;

  /// How many spots in the cell, and the area level there.
  final int count, areaLevel;
  double get x => (cx + 0.5) * World.cellPx;
  double get y => (cy + 0.5) * World.cellPx;
}

class GameDb {
  GameDb.fromJson(Map<String, dynamic> j) : built = j['built'] {
    (j['items'] as Map<String, dynamic>).forEach(
      (id, v) => items[id] = Item(id, v),
    );
    (j['workshops'] as Map<String, dynamic>).forEach(
      (id, v) => workshops[id] = Workshop(id, v),
    );
    (j['categories'] as Map<String, dynamic>).forEach(
      (id, v) => categories[id] = List<String>.from(v),
    );
    recipes = [for (final r in j['recipes']) Recipe(r)];
    sets = [for (final s in j['sets']) ItemSet(s)];
    lore = [for (final d in j['lore']) Doc(d)];
    quests = [for (final d in j['quests']) Doc(d)];
    World.load(j['world'] as Map<String, dynamic>?);
    skills = [for (final k in j['skills'] ?? const []) Skill(k)];
    skillById = {for (final k in skills) k.id: k};
    poi = [for (final p in j['poi'] ?? const []) Poi(p)];
    balancing = j['balancing'] == null ? null : Balancing(j['balancing']);
    (j['fish'] as Map<String, dynamic>? ?? const {}).forEach(
      (k, v) => fish[k] = FishTable(v),
    );
    halls = j['halls'] == null ? null : HallLayout(j['halls']);
    (j['loot'] as Map<String, dynamic>? ?? const {}).forEach(
      (k, v) => loot[k] = LootSetting(v),
    );
    final rg = j['regions'] as Map<String, dynamic>?;
    if (rg != null) {
      regionNames = List<String>.from(rg['names']);
      regionCells = rg['cells'];
      (rg['anchors'] as Map<String, dynamic>).forEach(
        (name, list) =>
            regionAnchors[name] = [
              for (final a in list as List)
                (
                  (a[0] as num).toDouble(),
                  (a[1] as num).toDouble(),
                  a[2] as String,
                ),
            ],
      );
    }
    (j['gather'] as Map<String, dynamic>? ?? const {}).forEach((id, v) {
      final f = (v as List).cast<int>();
      gather[id] = [
        for (var i = 0; i + 3 < f.length; i += 4)
          GatherCell(f[i], f[i + 1], f[i + 2], f[i + 3]),
      ];
    });

    for (final r in recipes) {
      for (final o in r.outputs) {
        (madeBy[o.ref] ??= []).add(r);
      }
      for (final i in r.inputs) {
        for (final id in expand(i)) {
          (usedIn[id] ??= []).add(r);
        }
      }
    }
    for (final s in sets) {
      for (final e in s.entries) {
        (inSets[e.itemId] ??= []).add(s);
      }
    }
    // by name, ignoring leading quotes and punctuation ("Afro" Wig Head sorts under A)
    String key(Item i) =>
        i.name.replaceFirst(RegExp(r'^[^A-Za-z0-9]+'), '').toLowerCase();
    sortedItems =
        items.values.toList()..sort((a, b) => key(a).compareTo(key(b)));
  }

  /// When this data was built (tools/build_db.py); newer data comes from the PC agent.
  final String? built;

  final items = <String, Item>{};
  final workshops = <String, Workshop>{};
  final categories = <String, List<String>>{};
  late final List<Recipe> recipes;
  late final List<ItemSet> sets;
  late final List<Doc> lore, quests;
  late final List<Skill> skills;

  /// The skill tree's layout, from its own nodes.
  late final SkillLayout skillLayout = SkillLayout(skills);
  late final Map<String, Skill> skillById;

  /// Every effect items give (ItemStats.effects) with the items giving it: skills ("Fatal Precision") and
  /// stats ("Mana Regeneration") alike.
  late final Map<String, List<Item>> byEffect = () {
    final out = <String, List<Item>>{};
    for (final i in sortedItems) {
      for (final e in i.stats?.effects.keys ?? const <String>[]) {
        (out[e] ??= []).add(i);
      }
    }
    return out;
  }();

  /// Where each piece of unique loot lies: the chests that always hold it, and the points "in one of a few
  /// chests around here" (Poi.loot).
  late final Map<String, List<Poi>> placesOf = () {
    final out = <String, List<Poi>>{};
    for (final p in poi) {
      for (final id in p.loot) {
        (out[id] ??= []).add(p);
      }
    }
    return out;
  }();

  /// Cosmetic pieces: the items of the game's "Clothes" set collections.
  late final Set<String> clothes = {
    for (final s in sets)
      if (s.category.startsWith('Clothes'))
        for (final e in s.entries) e.itemId,
  };

  /// The kinds of loot a hunt can narrow to, in the order shown, and an item's kind.
  static const lootGroups = ['Clothes', 'Weapons', 'Armor & rings', 'Other'];
  String lootGroup(String id) =>
      clothes.contains(id)
          ? 'Clothes'
          : switch (items[id]?.category) {
            'Weapons' => 'Weapons',
            'Equipment' => 'Armor & rings',
            _ => 'Other',
          };

  /// Effects named after a skill of the tree: gear that gives (or strengthens) that skill.
  late final Set<String> skillNames = {for (final k in skills) k.name};
  late final List<Poi> poi;
  late final Balancing? balancing;
  final loot = <String, LootSetting>{};

  /// Fishing spots' tables by key (Poi.fishTable).
  final fish = <String, FishTable>{};

  /// The Hollow Halls' insides; null in older data.
  late final HallLayout? halls;

  /// Where items grow or lie in the world (plants, bushes, stones, ore nodes), densest cells first.
  final gather = <String, List<GatherCell>>{};

  /// Regions on the World.grid cells (80 x 80 of 128 m), from the biome in template names; anchors are each
  /// region's Ancient Spires and passages (x, y, title), for zone pins.
  List<String> regionNames = const [];
  String regionCells = '';
  final regionAnchors = <String, List<(double, double, String)>>{};

  String? regionAt(double x, double y) {
    final cx = (x / World.cellPx).floor(), cy = (y / World.cellPx).floor();
    final n = World.grid;
    if (regionCells.length != n * n || cx < 0 || cy < 0 || cx >= n || cy >= n) {
      return null;
    }
    final c = regionCells.codeUnitAt(cy * n + cx) - 48;
    return c <= 0 || c > regionNames.length ? null : regionNames[c - 1];
  }

  /// Map points holding this item as fixed loot.
  Iterable<Poi> uniqueSpots(String itemId) =>
      poi.where((p) => p.fixed.contains(itemId) || p.itemId == itemId);

  /// Trophy bosses' spawn points dropping this head.
  Iterable<Poi> bossSpots(String itemId) => poi.where((p) => p.head == itemId);

  /// Found (lore) or completed (labels), when the save can tell.
  bool poiDone(Poi p, Set<String> known) {
    if (p.lore != null)
      return lore[p.lore![0]].pages[p.lore![1]].done?.likely(known) ?? false;
    return p.done?.likely(known) ?? false;
  }

  late final List<Item> sortedItems;
  final madeBy = <String, List<Recipe>>{};
  final usedIn = <String, List<Recipe>>{};
  final inSets = <String, List<ItemSet>>{};

  /// Item ids a recipe input accepts.
  List<String> expand(ItemStack s) =>
      s.isCategory ? (categories[s.ref.substring(4)] ?? const []) : [s.ref];

  String nameOf(String ref) {
    if (ref.startsWith('cat:')) {
      final members = categories[ref.substring(4)] ?? const [];
      if (members.isEmpty) return 'Any material';
      final names = members
          .take(3)
          .map((id) => items[id]?.name ?? id)
          .join(', ');
      return members.length > 3 ? 'Any of $names…' : 'Any of $names';
    }
    return items[ref]?.name ?? ref;
  }

  /// [nameOf] as shown, in the chosen language. [nameOf] stays English for sorting and matching.
  String shownName(String ref) {
    if (ref.startsWith('cat:')) {
      final members = categories[ref.substring(4)] ?? const [];
      if (members.isEmpty) return tr('Any material');
      final names = members
          .take(3)
          .map((id) => gt(items[id]?.name ?? id))
          .join(', ');
      return members.length > 3
          ? tr('Any of {items}…', {'items': names})
          : tr('Any of {items}', {'items': names});
    }
    return gt(items[ref]?.name ?? ref);
  }

  /// Prefix matches first, then word starts, then anywhere.
  List<Item> search(String q, {String? category}) {
    q = q.trim().toLowerCase();
    final pool =
        category == null
            ? sortedItems
            : sortedItems.where((i) => i.category == category);
    if (q.isEmpty) return pool.toList();
    final ranked = <(int, Item)>[];
    for (final i in pool) {
      final n = i.name.toLowerCase();
      final at = n.indexOf(q);
      if (at < 0) continue;
      ranked.add((at == 0 ? 0 : (n[at - 1] == ' ' ? 1 : 2), i));
    }
    ranked.sort(
      (a, b) =>
          a.$1 != b.$1
              ? a.$1.compareTo(b.$1)
              : a.$2.name.length.compareTo(b.$2.name.length),
    );
    // every match: the list is lazy, and a cap here cut the Locked filter short (it filters after)
    return [for (final r in ranked) r.$2];
  }
}
