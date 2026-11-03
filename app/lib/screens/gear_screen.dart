import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../data/item_icons.dart';
import '../theme.dart';
import 'item_screen.dart';
import 'widgets.dart';

/// One owned piece of gear and where it is.
class _Owned {
  _Owned(this.item, this.o, this.where);
  final Item item;
  final Owned o;
  final String where;
}

/// Everything I own per equipment slot, and the best food I could eat.
class GearScreen extends StatelessWidget {
  const GearScreen({super.key, required this.db});
  final GameDb db;

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
    'Spell',
    'Arrow',
  ];
  static const foodStats = [
    'Health',
    'Stamina',
    'Mana',
    'Ranged Damage',
    'Melee Damage',
    'Magic Damage',
    'Dagger Damage',
    'Health Regeneration',
    'Stamina Regeneration',
    'Mana Regeneration',
    'Maximum Oxygen',
    'Frost Resistance',
  ];

  @override
  Widget build(BuildContext context) {
    final s = LiveScope.of(context).state;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Gear & food')),
        body: const Center(child: Text('No live data from the PC agent yet.')),
      );
    }
    final labels = s.labels((id) => db.items[id]?.name ?? id);
    final owned = <_Owned>[];
    void add(Iterable<Owned> list, String where) {
      for (final o in list) {
        final it = db.items[o.itemId];
        if (it?.stats != null) owned.add(_Owned(it!, o, where));
      }
    }

    add(s.equipment, 'Equipped');
    add(s.cosmetics, 'Cosmetic');
    add(s.carried, 'Bag');
    for (final c in s.containers) {
      add(c.items, labels[c.index]);
    }

    // the usual slots in their order, then any other slot something is worn in (glider, backpack, hook...)
    final shown =
        [
          ...slots,
          for (final g in owned)
            if (g.where == 'Equipped' && !slots.contains(g.item.stats!.slot))
              g.item.stats!.slot!,
        ].toSet().toList();
    final bySlot = <String, List<_Owned>>{};
    for (final g in owned) {
      if (shown.contains(g.item.stats!.slot)) {
        (bySlot[g.item.stats!.slot!] ??= []).add(g);
      }
    }
    for (final list in bySlot.values) {
      list.sort((a, b) {
        if ((a.where == 'Equipped') != (b.where == 'Equipped'))
          return a.where == 'Equipped' ? -1 : 1;
        final l = (b.o.level ?? 0).compareTo(a.o.level ?? 0);
        return l != 0
            ? l
            : (Rarity.rank(
              b.item.rarity,
            )).compareTo(Rarity.rank(a.item.rarity));
      });
    }

    final food = [
      for (final g in owned)
        if (g.item.stats!.slot == 'Consumable') g,
    ];
    final bestFood = <String, List<_Owned>>{};
    for (final stat in foodStats) {
      final seen = <String>{};
      final ranked = [
        for (final f in food)
          if (f.item.stats!.value(stat) > 0 && seen.add(f.item.id)) f,
      ]..sort(
        (a, b) =>
            b.item.stats!.value(stat).compareTo(a.item.stats!.value(stat)),
      );
      if (ranked.isNotEmpty) bestFood[stat] = ranked.take(3).toList();
    }

    void open(Item it) => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ItemScreen(db: db, item: it)),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Gear & food')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SectionTitle('Best food you own'),
          if (bestFood.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No food with buffs in your bag or chests.'),
            ),
          for (final e in bestFood.entries)
            ListTile(
              dense: true,
              title: Text(
                e.key,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final f in e.value)
                    ActionChip(
                      label: Text(
                        '${f.item.name} +${f.item.stats!.value(e.key)}',
                      ),
                      onPressed: () => open(f.item),
                    ),
                ],
              ),
            ),
          for (final slot in shown)
            if (bySlot[slot] case final list?) ...[
              SectionTitle(
                '${ItemStats.slotLabels[slot] ?? slot} · ${list.length}',
              ),
              for (final g in list)
                ListTile(
                  dense: true,
                  leading: ItemIcon(
                    g.item,
                    fallback: Icons.shield_outlined,
                    ring: g.where == 'Equipped' ? Palette.flame : null,
                  ),
                  title: Text(
                    '${g.item.name}${g.o.level != null ? ' · L${g.o.level}' : ''}',
                  ),
                  subtitle: Text(
                    [
                      g.where,
                      ...g.item.stats!.values
                          .take(3)
                          .map((v) => '${v.$1} ${v.$2}'),
                    ].join(' · '),
                    style: const TextStyle(color: Palette.ash, fontSize: 12),
                  ),
                  trailing: Text(
                    g.item.rarity,
                    style: TextStyle(
                      color: Palette.rarity(g.item.rarity),
                      fontSize: 12,
                    ),
                  ),
                  onTap: () => open(g.item),
                ),
            ],
        ],
      ),
    );
  }
}
