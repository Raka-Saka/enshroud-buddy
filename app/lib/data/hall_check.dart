import 'game_db.dart';
import 'live_state.dart';
import 'survival.dart';

/// How a line of the check reads: fine, worth fixing first, or just to know.
enum CheckMark { ok, warn, info }

class CheckLine {
  const CheckLine(this.mark, this.title, this.detail);
  final CheckMark mark;
  final String title, detail;
}

/// Before going into a Hollow Hall: what is inside (tools/build_db.py hall_brief, from the objects placed
/// there), and with a live save, the hall's level against yours and your gear's, the tools its rooms ask for,
/// the damage its Hollow take more and less of (the wiki's enemy pages), healing in the bag, and Shroud time
/// where the Fell are.
class HallCheck {
  HallCheck(this.db, this.hall, this.state);
  final GameDb db;
  final Hall hall;
  final LiveState? state;

  /// The game's damage names (items' "dm") as a player reads them.
  static const damageNames = {
    'physicalCut': 'cutting',
    'physicalPierce': 'piercing',
    'physicalBlunt': 'blunt',
    'magicalFire': 'fire',
    'magicalIce': 'ice',
    'magicalLightning': 'shock',
    'magicalFog': 'shroud',
    'poison': 'poison',
  };

  static const _armour = [
    'Armour_Head',
    'Armour_UpperBody',
    'Armour_Arms',
    'Armour_LowerBody',
    'Armour_Feet',
  ];
  static const _weapons = [
    'MeleeWeapon',
    'MidRangeWeapon',
    'RangeWeapon',
    'Spell',
  ];

  int _n(String k) => hall.contents[k] ?? 0;

  static String _list(List<String> l) =>
      l.length < 2
          ? l.join()
          : '${l.sublist(0, l.length - 1).join(', ')} and ${l.last}';

  /// "282 Hollow (7 elite), 66 beasts, 16 rune barriers, 48 climbing walls, 34 traps".
  String get contents {
    final parts = [
      if (_n('hollow') > 0)
        '${_n('hollow')} Hollow${_n('elite') > 0 ? ' (${_n('elite')} elite)' : ''}',
      if (_n('fell') > 0) '${_n('fell')} Fell',
      if (_n('beasts') > 0) '${_n('beasts')} beasts',
      if (_n('raisers') > 0) '${_n('raisers')} bone piles',
      if (_n('doors') > 0) '${_n('doors')} rune barriers',
      if (_n('traps') > 0) '${_n('traps')} traps',
    ];
    return parts.join(' · ');
  }

  Item? _item(Owned o) => db.items[o.itemId];

  /// Items in use and carried, with their stats.
  Iterable<(Item, Owned)> _have(Iterable<Owned> list) sync* {
    for (final o in list) {
      if (o.cosmetic) continue;
      final it = _item(o);
      if (it?.stats != null) yield (it!, o);
    }
  }

  List<CheckLine> lines() {
    final s = state;
    final out = <CheckLine>[];
    final lv = hall.level;
    if (s != null && s.level > 0) {
      out.add(
        CheckLine(
          s.level >= lv ? CheckMark.ok : CheckMark.warn,
          'Level',
          'You are level ${s.level}; its enemies are level $lv.',
        ),
      );
      // armour worn and the best weapon carried per slot
      final armour = [
        for (final (it, o) in _have(s.equipment))
          if (_armour.contains(it.stats!.slot) && o.level != null) (it, o),
      ];
      final best = <String, (Item, Owned)>{};
      for (final (it, o) in _have([...s.equipment, ...s.carried])) {
        final sl = it.stats!.slot;
        if (!_weapons.contains(sl) || o.level == null) continue;
        if (it.stats!.weaponType == 'Utility') continue;
        if ((best[sl]?.$2.level ?? -1) < o.level!) best[sl!] = (it, o);
      }
      final pieces = [...armour, ...best.values];
      if (pieces.isNotEmpty) {
        final low = [
          for (final p in pieces)
            if (p.$2.level! < lv) p,
        ]..sort((a, b) => a.$2.level!.compareTo(b.$2.level!));
        final lo = pieces
            .map((p) => p.$2.level!)
            .reduce((a, b) => a < b ? a : b);
        final hi = pieces
            .map((p) => p.$2.level!)
            .reduce((a, b) => a > b ? a : b);
        out.add(
          CheckLine(
            low.isEmpty ? CheckMark.ok : CheckMark.warn,
            'Gear',
            low.isEmpty
                ? 'Worn armour and weapons are level $lo to $hi, all at or above $lv.'
                : '${low.length} of ${pieces.length} pieces under level $lv: '
                    '${low.take(3).map((p) => '${p.$1.name} ${p.$2.level}').join(', ')}'
                    '${low.length > 3 ? '…' : ''}.',
          ),
        );
      }
      // damage: what the Hollow take more of, and whether anything carried deals it
      final dmg = db.halls?.damage;
      if (dmg != null && _n('hollow') > 0) {
        final mine = <String, Item>{};
        for (final (it, _) in _have([...s.equipment, ...s.carried])) {
          final sl = it.stats!.slot;
          if (!_weapons.contains(sl) && sl != 'Arrow') continue;
          for (final d in it.stats!.damage) {
            mine.putIfAbsent(d.split('=').first, () => it);
          }
        }
        String names(List<String> l) =>
            _list([for (final d in l) damageNames[d] ?? d]);
        final hits = [
          for (final d in dmg.weak)
            if (mine.containsKey(d)) d,
        ];
        final wasted = [
          for (final d in mine.keys)
            if (dmg.strong.contains(d)) d,
        ];
        final what = [
          if (dmg.weak.isNotEmpty) 'Hollow take more from ${names(dmg.weak)}',
          if (dmg.strong.isNotEmpty) 'resist ${names(dmg.strong)}',
        ].join(' and ');
        final have =
            hits.isNotEmpty
                ? 'You carry ${_list([for (final d in hits) mine[d]!.name])}.'
                : 'Nothing you carry deals ${names(dmg.weak)}.';
        final off =
            wasted.isEmpty
                ? ''
                : ' ${_list([for (final d in wasted) mine[d]!.name])} '
                    'deal${wasted.length == 1 ? 's' : ''} ${names(wasted)}, which they resist.';
        out.add(
          CheckLine(
            hits.isNotEmpty ? CheckMark.ok : CheckMark.warn,
            'Damage',
            '$what. $have$off (wiki: ${_list(dmg.from)})',
          ),
        );
      }
      bool wears(String slot) =>
          _have(s.equipment).any((p) => p.$1.stats!.slot == slot);
      if (_n('hook') > 0) {
        out.add(
          CheckLine(
            wears('HookShot') ? CheckMark.ok : CheckMark.warn,
            'Grappling hook',
            '${_n('hook')} grapple points. '
                '${wears('HookShot') ? 'You have one on.' : 'You have none on.'}',
          ),
        );
      }
      if (_n('glide') > 0) {
        out.add(
          CheckLine(
            wears('Glider') ? CheckMark.ok : CheckMark.warn,
            'Glider',
            '${_n('glide')} updrafts and glider barriers. '
                '${wears('Glider') ? 'You have one on.' : 'You have none on.'}',
          ),
        );
      }
      if (_n('fell') > 0) {
        out.add(
          CheckLine(
            CheckMark.info,
            'Shroud',
            '${_n('fell')} Fell inside, the Shroud\'s creatures. '
                'Your time in the Shroud: ${Survival.format(Survival(db, s).shroudSeconds)}.',
          ),
        );
      }
      // healing: consumables that restore health and aren't a timed food buff
      final heal = <String, int>{};
      for (final (it, o) in _have(s.carried)) {
        final st = it.stats!;
        if (st.slot != 'Consumable') continue;
        final labels = st.values.map((v) => v.$1);
        if (labels.contains('Duration')) continue;
        if (!labels.any((l) => l == 'Health' || l.startsWith('Healing'))) {
          continue;
        }
        heal[it.name] = (heal[it.name] ?? 0) + o.count;
      }
      out.add(
        CheckLine(
          heal.isEmpty ? CheckMark.warn : CheckMark.ok,
          'Healing',
          heal.isEmpty
              ? 'No potions or bandages in the bag.'
              : (heal.entries.toList()..sort((a, b) => b.value - a.value))
                  .map((e) => '${e.key} ×${e.value}')
                  .join(', '),
        ),
      );
    } else {
      out.add(
        CheckLine(
          CheckMark.info,
          'Level',
          'Its enemies are level $lv. Connect the PC agent to check your gear.',
        ),
      );
    }
    if (_n('raisers') > 0) {
      out.add(
        CheckLine(
          CheckMark.info,
          'Bone piles',
          '${_n('raisers')} piles raise more Hollow until broken: break them first.',
        ),
      );
    }
    if (_n('traps') > 0) {
      final kinds = [
        if (_n('fire') > 0) '${_n('fire')} fire',
        if (_n('shock') > 0) '${_n('shock')} shock',
      ];
      out.add(
        CheckLine(
          CheckMark.info,
          'Traps',
          '${_n('traps')} traps${kinds.isEmpty ? '' : ', ${kinds.join(' and ')}'}.',
        ),
      );
    }
    return out;
  }
}

/// Something to collect in a Hollow Hall: a journal page lying there, or an item a chest there always holds.
class Find {
  const Find(
    this.poi,
    this.name, {
    required this.lore,
    this.have,
    this.places = 1,
  });
  final Poi poi;
  final String name;
  final bool lore;

  /// Chests in the hall that hold the same item (the first is [poi]).
  final int places;

  /// Whether the character has it: the page read, or the item in gear, bag or a chest, or its recipe known
  /// (a block found unlocks its recipe). Null without a save.
  final bool? have;
}

/// What each Hollow Hall holds to collect, against what the character has.
class HallFinds {
  HallFinds(this.db, this.state);
  final GameDb db;
  final LiveState? state;

  static final _names = Expando<Set<String>>();

  /// Names of every item the character has: in the game's collection (every item ever had), a set entry
  /// collected, owned anywhere, or with a known recipe. An item counts by name, whatever its level.
  Set<String> get _have =>
      _names[state!] ??= {
        for (final id in state!.itemsKnown) db.items[id]?.name ?? '',
        for (final set in db.sets)
          for (final e in set.entries)
            if (e.done?.likely(state!.knowledge) ?? false)
              db.items[e.itemId]?.name ?? '',
        for (final o in [
          ...state!.equipment,
          ...state!.cosmetics,
          ...state!.carried,
          for (final c in state!.containers) ...c.items,
        ])
          db.items[o.itemId]?.name ?? '',
        for (final it in db.items.values)
          if ((db.madeBy[it.id] ?? const <Recipe>[]).any(
            (r) => state!.recipesUnlocked.contains(r.id),
          ))
            it.name,
      };

  /// Whether a place holds something to collect: a linked journal page, or unique loot (a chest's fixed
  /// loot, or a special point's item).
  static bool collectible(Poi p) =>
      (p.cat == 'lore' && p.lore != null) || p.loot.isNotEmpty;

  /// For a collectible place: whether all it holds is had (null without a save, or for other places).
  bool? had(Poi p) {
    if (state == null || !collectible(p)) return null;
    if (p.cat == 'lore') return db.poiDone(p, state!.knowledge);
    return p.loot.every((id) => _have.contains(db.items[id]?.name));
  }

  /// One hall's finds, journal pages first, missing before had; an item in several chests once.
  List<Find> of(int hall) {
    final out = <Find>[];
    final items = <String, (Poi, int)>{};
    for (final p in db.poi) {
      if (!p.inside || p.hall != hall || !collectible(p)) continue;
      if (p.cat == 'lore') {
        out.add(Find(p, p.title, lore: true, have: had(p)));
      } else {
        for (final id in p.loot) {
          final n = db.items[id]?.name ?? id;
          final seen = items[n];
          items[n] = (seen?.$1 ?? p, (seen?.$2 ?? 0) + 1);
        }
      }
    }
    items.forEach(
      (n, v) => out.add(
        Find(
          v.$1,
          n,
          lore: false,
          places: v.$2,
          have: state == null ? null : _have.contains(n),
        ),
      ),
    );
    int rank(Find f) => (f.lore ? 0 : 2) + (f.have == true ? 1 : 0);
    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  /// Whether the character has an item (by name, any level), or null without a save.
  bool? hasItem(String id) =>
      state == null ? null : _have.contains(db.items[id]?.name);

  static final _missing = Expando<Map<int, int>>();

  /// The quests that lead into a hall (their pages name it: "Find The Revelwood Hollow Halls"), and
  /// whether each is done (null without a save).
  List<(Doc, bool?)> quests(Hall h) {
    final region = h.region;
    if (region == null) return const [];
    // "Veilwater Hollow Halls" as well as "Veilwater Basin Hollow Halls"
    final name = RegExp(
      '${RegExp.escape(region.split(' ').first)}\\b[\\w ]{0,20}Hollow Halls',
    );
    return [
      for (final q in db.quests)
        if (q.pages.any(
          (p) => name.hasMatch(p.title ?? '') || name.hasMatch(p.text),
        ))
          (
            q,
            state == null || q.pages.last.done == null
                ? null
                : q.pages.last.done!.likely(
                  state!.knowledge,
                  state!.unlockContext,
                ),
          ),
    ];
  }

  /// How many of a hall's finds are still missing (null without a save); once per save.
  int? missing(int hall) =>
      state == null
          ? null
          : (_missing[state!] ??= {})[hall] ??=
              of(hall).where((f) => f.have == false).length;
}
