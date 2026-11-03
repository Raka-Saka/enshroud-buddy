import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../data/survival.dart';
import '../data/item_icons.dart';
import '../nav.dart';
import '../theme.dart';
import 'base_view_screen.dart';
import 'build_screen.dart';
import 'farm_screen.dart';
import 'item_screen.dart';
import 'map_screen.dart';
import 'survival_screen.dart';
import 'widgets.dart';

/// The character: build, gear, what they carry and store, and their bases.
class CharacterScreen extends StatefulWidget {
  const CharacterScreen({super.key, required this.db});
  final GameDb db;

  @override
  State<CharacterScreen> createState() => _CharacterScreenState();
}

class _CharacterScreenState extends State<CharacterScreen>
    with SingleTickerProviderStateMixin {
  late final tabs = TabController(
    length: 4,
    vsync: this,
    initialIndex: characterTab.value,
  );

  @override
  void initState() {
    super.initState();
    characterTab.addListener(_follow);
    tabs.addListener(() => characterTab.value = tabs.index);
  }

  @override
  void dispose() {
    characterTab.removeListener(_follow);
    tabs.dispose();
    super.dispose();
  }

  void _follow() {
    if (tabs.index != characterTab.value) tabs.animateTo(characterTab.value);
  }

  @override
  Widget build(BuildContext context) {
    final live = LiveScope.of(context);
    final s = live.state;
    return Scaffold(
      appBar: AppBar(
        title: Text(s?.character ?? 'Character'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: LiveBadge(live: live)),
          ),
        ],
        bottom: TabBar(
          controller: tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Build'),
            Tab(text: 'Gear'),
            Tab(text: 'Inventory'),
            Tab(text: 'Bases'),
          ],
        ),
      ),
      body: TabBarView(
        controller: tabs,
        children: [
          BuildScreen(db: widget.db, embedded: true),
          BuildScreen(db: widget.db, part: BuildPart.gear, embedded: true),
          _Inventory(db: widget.db),
          _Bases(db: widget.db),
        ],
      ),
    );
  }
}

/// Worn, bag, every chest and rack, and other holders, with one search over all of it.
class _Inventory extends StatefulWidget {
  const _Inventory({required this.db});
  final GameDb db;

  @override
  State<_Inventory> createState() => _InventoryState();
}

class _InventoryState extends State<_Inventory> {
  String q = '';

  String name(String id) => widget.db.items[id]?.name ?? id;

  @override
  Widget build(BuildContext context) {
    final s = LiveScope.of(context).state;
    if (s == null) {
      return const Center(
        child: EmptyState(
          icon: Icons.inventory_2_outlined,
          title: 'No live data yet',
          message:
              'Your bag and chests appear after the PC agent reads a save.',
        ),
      );
    }
    final needle = q.trim().toLowerCase();
    bool match(Owned o) =>
        needle.isEmpty || name(o.itemId).toLowerCase().contains(needle);
    final labels = s.labels(name);
    final chests = [
      for (final c in s.containers)
        if (c.kind != null && c.items.any(match)) c,
    ];
    final others = [
      for (final c in s.containers)
        if (c.kind == null && c.items.any(match)) c,
    ];
    // both lists the character carries (tools/state.py: "bag" and "pouch")
    final bag = s.carried.where(match).toList();
    return RefreshIndicator(
      onRefresh: LiveScope.of(context).refresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              onChanged: (v) => setState(() => q = v),
              decoration: const InputDecoration(
                hintText: 'Find in my gear, bag and chests',
                prefixIcon: Icon(Icons.search, color: Palette.flame),
              ),
            ),
          ),
          if (s.equipment.any(match)) ...[
            const SectionTitle('Equipped'),
            for (final o in s.equipment.where(match))
              _OwnedTile(db: widget.db, o: o),
          ],
          if (s.cosmetics.any(match)) ...[
            const SectionTitle('Cosmetic (look only)'),
            for (final o in s.cosmetics.where(match))
              _OwnedTile(db: widget.db, o: o),
          ],
          SectionTitle('Bag · ${bag.length}'),
          for (final o in bag) _OwnedTile(db: widget.db, o: o),
          for (final (base, list) in _byBase(s, chests)) ...[
            SectionTitle('$base · ${list.length}'),
            for (final c in list)
              _ContainerTile(
                db: widget.db,
                c: c,
                label: labels[c.index],
                match: match,
                open: needle.isNotEmpty,
              ),
          ],
          if (others.isNotEmpty) ...[
            SectionTitle('Animals & other storage · ${others.length}'),
            for (final c in others)
              _ContainerTile(
                db: widget.db,
                c: c,
                label: labels[c.index],
                match: match,
                open: needle.isNotEmpty,
              ),
          ],
        ],
      ),
    );
  }
}

/// Chests per base, bases in their save order, then those whose base isn't known.
List<(String, List<Storage>)> _byBase(LiveState s, List<Storage> chests) {
  final out = <(String, List<Storage>)>[];
  for (final b in s.bases) {
    final list = [
      for (final c in chests)
        if (c.baseId == b.id) c,
    ];
    if (list.isNotEmpty) out.add(('Chests · ${b.label}', list));
  }
  final rest = [
    for (final c in chests)
      if (s.baseName(c.baseId) == null) c,
  ];
  if (rest.isNotEmpty) out.add(('Chests · base not known', rest));
  return out;
}

/// Bases with their altar level, stations built, the farm and survival.
class _Bases extends StatelessWidget {
  const _Bases({required this.db});
  final GameDb db;

  @override
  Widget build(BuildContext context) {
    final s = LiveScope.of(context).state;
    if (s == null) {
      return const Center(
        child: EmptyState(
          icon: Icons.cottage_outlined,
          title: 'No live data yet',
        ),
      );
    }
    String name(String id) => db.items[id]?.name ?? id;
    final stations =
        s.placed.entries
            .where((e) => db.workshops.values.any((w) => w.itemId == e.key))
            .map(
              (e) => e.value > 1 ? '${name(e.key)} ×${e.value}' : name(e.key),
            )
            .toList()
          ..sort();
    final b = db.balancing;
    final sizes = [
      for (final z in b?.zonePerAltar ?? const <int>[])
        if (z > 0) z,
    ];
    final zones = sizes.isEmpty ? null : '${sizes.first} to ${sizes.last} m';
    final sv = Survival(db, s);
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 32),
      children: [
        DashCard(
          title:
              b == null
                  ? 'Flame Altars'
                  : 'Flame Altars · ${s.bases.length} of ${b.altarsAt(s.flameLevel)}',
          icon: Icons.local_fire_department,
          child: Column(
            children: [
              Text(
                'Flame strength ${s.flameLevel} sets how many; an altar\'s own level sets its build zone'
                '${zones == null ? '' : ' ($zones a side)'}.',
                style: const TextStyle(color: Palette.ash, fontSize: 12.5),
              ),
              for (final base in s.bases)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(base.label),
                  // altar level under the name, so a long name keeps its room next to the buttons
                  subtitle: Text(
                    'Altar ${base.altarLevel} · ${base.zone} build zone',
                    style: const TextStyle(color: Palette.flame, fontSize: 12),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (base.pieces.isNotEmpty)
                        IconButton(
                          tooltip: 'See it in 3D',
                          icon: const Icon(Icons.view_in_ar, size: 20),
                          onPressed:
                              () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder:
                                      (_) => BaseViewScreen(db: db, base: base),
                                ),
                              ),
                        ),
                      IconButton(
                        tooltip: 'Show on the map',
                        icon: const Icon(Icons.map_outlined, size: 20),
                        onPressed:
                            () =>
                                mapFocus.value = Poi({
                                  'c': 'spot',
                                  'k':
                                      'Altar ${base.altarLevel} · build zone ${base.zone}',
                                  't': base.label,
                                  'x': base.mapX,
                                  'y': base.mapY,
                                }),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.grass, color: Palette.spring),
            title: const Text('Farm'),
            subtitle: const Text('Feeders, produce to collect, seeds'),
            trailing: const Icon(Icons.chevron_right),
            onTap:
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => FarmScreen(db: db)),
                ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.cloud_outlined, color: Palette.veil),
            title: const Text('Survival: Shroud, cold, water'),
            subtitle: Text(
              'Shroud ${Survival.format(sv.shroudSeconds)} · breath ${Survival.format(sv.oxygenSeconds)}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap:
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SurvivalScreen(db: db)),
                ),
          ),
        ),
        SectionTitle('Stations built · ${stations.length}'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final st in stations) Chip(label: Text(st))],
          ),
        ),
      ],
    );
  }
}

class _OwnedTile extends StatelessWidget {
  const _OwnedTile({required this.db, required this.o});
  final GameDb db;
  final Owned o;

  @override
  Widget build(BuildContext context) {
    final item = db.items[o.itemId];
    final extra = [
      if (o.level != null) 'Level ${o.level}',
      if (o.durability != null)
        'Durability ${o.durability![0]}/${o.durability![1]}',
    ].join(' · ');
    return ListTile(
      dense: true,
      leading: ItemIcon(item, size: 34),
      title: Text(item?.name ?? o.itemId),
      subtitle: extra.isEmpty ? null : Text(extra),
      trailing:
          o.count > 1
              ? Text(
                '×${o.count}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              )
              : null,
      onTap:
          item == null
              ? null
              : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ItemScreen(db: db, item: item),
                ),
              ),
    );
  }
}

class _ContainerTile extends StatelessWidget {
  const _ContainerTile({
    required this.db,
    required this.c,
    required this.label,
    required this.match,
    required this.open,
  });
  final GameDb db;
  final Storage c;
  final String label;
  final bool Function(Owned) match;
  final bool open;

  @override
  Widget build(BuildContext context) {
    final shown = c.items.where(match).toList();
    return Card(
      child: ExpansionTile(
        key: PageStorageKey('c${c.index}$open'),
        initiallyExpanded: open,
        leading: const Icon(Icons.inventory_2_outlined, color: Palette.flame),
        title: Text(label),
        subtitle: Text('${c.items.length} stacks'),
        children: [for (final o in shown) _OwnedTile(db: db, o: o)],
      ),
    );
  }
}
