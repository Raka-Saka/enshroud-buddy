import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../data/item_icons.dart';
import '../theme.dart';
import 'item_screen.dart';

const categoryLabels = {
  'Materials': 'Materials',
  'Consumables': 'Food & potions',
  'Weapons': 'Weapons',
  'Equipment': 'Armor & rings',
  'Ammunition': 'Ammo & bait',
  'Tools': 'Tools',
  'BuildTools': 'Building',
  'Collectibles': 'Collectibles',
  'Blueprints': 'Blueprints',
  'WeaponGem': 'Gems',
  'AnimalFood': 'Animal food',
  'Instrument': 'Instruments',
  'FishingRod': 'Fishing',
  'Currency': 'Currency',
};

class ItemsScreen extends StatefulWidget {
  const ItemsScreen({
    super.key,
    required this.db,
    this.embedded = false,
    this.autofocus = false,
    this.effect,
  });
  final GameDb db;

  /// Open on the gear giving this skill or stat (a skill's "Gear with this skill").
  final String? effect;

  /// Open with the keyboard up (Home's search button).
  final bool autofocus;

  /// Inside the Codex tabs: the app bar is above, so no top safe area.
  final bool embedded;

  @override
  State<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends State<ItemsScreen> {
  final query = TextEditingController();
  String? category;

  /// A skill or stat: only the items giving it, strongest first.
  late String? effect = widget.effect;

  /// null = all, true = craftable and unlocked, false = craftable but locked.
  bool? unlocked;

  @override
  Widget build(BuildContext context) {
    final live = LiveScope.of(context).state;
    final db = widget.db;
    final q = query.text.trim().toLowerCase();
    var results =
        effect == null
            ? db.search(query.text, category: category)
            : _withEffect(db, effect!, q, live);
    // typing a skill or stat offers its gear ("fatal" -> Fatal Precision)
    final offers =
        effect == null && q.length >= 3
            ? [
              for (final e in db.byEffect.keys)
                if (e.toLowerCase().contains(q)) e,
            ]
            : <String>[];
    offers.sort(
      (a, b) =>
          db.skillNames.contains(a) != db.skillNames.contains(b)
              ? (db.skillNames.contains(a) ? -1 : 1)
              : a.compareTo(b),
    );
    if (live != null && unlocked != null) {
      results = [
        for (final i in results)
          if (widget.db.madeBy[i.id] case final rs?)
            if (rs.any((r) => live.recipesUnlocked.contains(r.id)) == unlocked)
              i,
      ];
    }
    return SafeArea(
      top: !widget.embedded,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: TextField(
              controller: query,
              autofocus: widget.autofocus,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText:
                    effect == null
                        ? 'Search ${db.items.length} items, skills, stats'
                        : 'Search gear with $effect',
                prefixIcon: const Icon(Icons.search, color: Palette.flame),
                suffixIcon:
                    query.text.isEmpty
                        ? null
                        : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(query.clear),
                        ),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InputChip(
                    avatar: const Icon(Icons.auto_awesome, size: 16),
                    label: Text(effect ?? 'Skill or stat'),
                    selected: effect != null,
                    onPressed: () => _pickEffect(db),
                    onDeleted:
                        effect == null
                            ? null
                            : () => setState(() => effect = null),
                  ),
                ),
                if (live != null)
                  for (final (value, label) in const [
                    (true, 'Unlocked'),
                    (false, 'Locked'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        avatar: Icon(
                          value ? Icons.lock_open : Icons.lock_outline,
                          size: 16,
                        ),
                        label: Text(label),
                        selected: unlocked == value,
                        onSelected:
                            (on) =>
                                setState(() => unlocked = on ? value : null),
                      ),
                    ),
                for (final e in categoryLabels.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(e.value),
                      selected: category == e.key,
                      onSelected:
                          (on) => setState(() => category = on ? e.key : null),
                    ),
                  ),
              ],
            ),
          ),
          if (offers.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final e in offers.take(12))
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        avatar: Icon(
                          db.skillNames.contains(e)
                              ? Icons.auto_awesome
                              : Icons.trending_up,
                          size: 16,
                          color: Palette.flame,
                        ),
                        label: Text('$e · ${db.byEffect[e]!.length}'),
                        onPressed:
                            () => setState(() {
                              effect = e;
                              query.clear();
                            }),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child:
                results.isEmpty
                    ? const Center(
                      child: Text(
                        'Nothing found in the Shroud',
                        style: TextStyle(color: Palette.ash),
                      ),
                    )
                    : ListView.builder(
                      itemCount: results.length,
                      itemBuilder:
                          (context, i) => ItemTile(
                            db: db,
                            item: results[i],
                            detail: effect == null ? null : _detail(results[i]),
                          ),
                    ),
          ),
        ],
      ),
    );
  }

  /// Items giving [e], in [category] and named like [q], strongest first, then the highest level. Copies
  /// with the same name, rarity, levels and effects show once (the one owned, if any).
  List<Item> _withEffect(GameDb db, String e, String q, LiveState? live) {
    final picked = <String, Item>{};
    for (final i in db.byEffect[e] ?? const <Item>[]) {
      if (category != null && i.category != category) continue;
      if (q.isNotEmpty && !i.name.toLowerCase().contains(q)) continue;
      final st = i.stats!;
      final key = '${i.name}|${i.rarity}|${st.levels}|${st.effects}';
      final had = picked[key];
      if (had == null ||
          ((live?.owned(had.id) ?? 0) == 0 && (live?.owned(i.id) ?? 0) > 0)) {
        picked[key] = i;
      }
    }
    int top(Item i) => i.stats!.levels?.last ?? 0;
    return picked.values.toList()..sort((a, b) {
      final (ta, va) = a.stats!.strength(e);
      final (tb, vb) = b.stats!.strength(e);
      if (ta != tb) return tb.compareTo(ta);
      if (va != vb) return vb.compareTo(va);
      return top(b).compareTo(top(a));
    });
  }

  /// "Head · level 30 · Fatal Precision ×2"
  String _detail(Item i) {
    final st = i.stats!;
    final lv = st.levels;
    final shown = st.effects[effect] ?? '';
    return [
      if (st.slot != null) st.slotLabel,
      if (lv != null && lv.isNotEmpty)
        lv.first == lv.last
            ? 'level ${lv.first}'
            : 'level ${lv.first}–${lv.last}',
      shown.isEmpty ? effect! : '$effect $shown',
    ].join(' · ');
  }

  /// Every skill and stat gear gives, skills first, with how many items give it.
  void _pickEffect(GameDb db) {
    final filter = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder:
          (ctx) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            builder:
                (ctx, scroll) => StatefulBuilder(
                  builder: (ctx, set) {
                    final f = filter.text.trim().toLowerCase();
                    final names = [
                      for (final e in db.byEffect.keys)
                        if (f.isEmpty || e.toLowerCase().contains(f)) e,
                    ];
                    final skills = [
                      for (final e in names)
                        if (db.skillNames.contains(e)) e,
                    ]..sort();
                    final stats = [
                      for (final e in names)
                        if (!db.skillNames.contains(e)) e,
                    ]..sort();
                    Widget row(String e) => ListTile(
                      dense: true,
                      title: Text(e),
                      trailing: Text(
                        '${db.byEffect[e]!.length}',
                        style: const TextStyle(color: Palette.ash),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        setState(() => effect = e);
                      },
                    );
                    Widget head(String t) => Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        t,
                        style: const TextStyle(
                          color: Palette.flame,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                    return ListView(
                      controller: scroll,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                          child: TextField(
                            controller: filter,
                            onChanged: (_) => set(() {}),
                            decoration: const InputDecoration(
                              hintText: 'Find a skill or stat',
                              prefixIcon: Icon(Icons.search),
                            ),
                          ),
                        ),
                        if (skills.isNotEmpty)
                          head('Skills the gear gives or strengthens'),
                        for (final e in skills) row(e),
                        if (stats.isNotEmpty) head('Stats'),
                        for (final e in stats) row(e),
                      ],
                    );
                  },
                ),
          ),
    ).whenComplete(filter.dispose);
  }
}

class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.db,
    required this.item,
    this.trailing,
    this.detail,
  });
  final GameDb db;
  final Item item;
  final Widget? trailing;

  /// A second line under the category: the slot, level and effect when filtering by one.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final craftable = db.madeBy.containsKey(item.id);
    final live = LiveScope.of(context).state;
    final open =
        live == null || !craftable
            ? null
            : db.madeBy[item.id]!.any(
              (r) => live.recipesUnlocked.contains(r.id),
            );
    final owned = live?.owned(item.id) ?? 0;
    return ListTile(
      dense: true,
      leading: ItemIcon(
        item,
        fallback: craftable ? Icons.handyman_outlined : Icons.diamond_outlined,
      ),
      title: Text(item.name, style: const TextStyle(fontSize: 15)),
      subtitle: Text(
        [
          '${categoryLabels[item.category] ?? item.category} · ${item.rarity}',
          if (detail != null) detail!,
        ].join('\n'),
        style: const TextStyle(color: Palette.ash, fontSize: 12),
      ),
      trailing:
          trailing ??
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (owned > 0)
                Text(
                  '$owned',
                  style: const TextStyle(
                    color: Palette.spring,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (open != null) ...[
                const SizedBox(width: 8),
                Icon(
                  open ? Icons.lock_open : Icons.lock_outline,
                  size: 16,
                  color: open ? Palette.spring : Palette.ember,
                ),
              ],
            ],
          ),
      onTap:
          () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ItemScreen(db: db, item: item)),
          ),
    );
  }
}
