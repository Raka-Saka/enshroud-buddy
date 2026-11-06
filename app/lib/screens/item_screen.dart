import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../data/where.dart';
import '../data/item_icons.dart';
import '../l10n.dart';
import '../labels.dart';
import '../theme.dart';
import 'ask_screen.dart';
import 'items_screen.dart';
import 'map_screen.dart';
import 'plans_screen.dart';
import 'sets_screen.dart';
import 'widgets.dart';

class ItemScreen extends StatelessWidget {
  const ItemScreen({super.key, required this.db, required this.item});
  final GameDb db;
  final Item item;

  void open(BuildContext context, String id) {
    final it = db.items[id];
    if (it != null)
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ItemScreen(db: db, item: it)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final live = LiveScope.of(context).state;
    final where =
        live?.whereIs(item.id, (id) => db.items[id]?.name ?? id) ??
        const <StoredIn>[];
    final made = db.madeBy[item.id] ?? const [];
    final usedIn = <String, Recipe>{};
    for (final r in db.usedIn[item.id] ?? const <Recipe>[]) {
      for (final o in r.outputs) {
        if (o.ref != item.id && db.items.containsKey(o.ref))
          usedIn.putIfAbsent(o.ref, () => r);
      }
    }
    final sets = db.inSets[item.id] ?? const [];
    final setHints = [
      for (final s in sets)
        for (final e in s.entries)
          if (e.itemId == item.id) ...e.hints,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(gt(item.name), overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: tr('Ask about this'),
            icon: const Icon(Icons.auto_awesome),
            onPressed:
                () => askAbout(context, db, item.name, itemPrompts(db, item)),
          ),
          IconButton(
            tooltip: tr('Add to shopping list'),
            icon: const Icon(Icons.add_task),
            onPressed:
                () => addGoal(
                  context,
                  item,
                  made.isEmpty ? 1 : made.first.outputs.first.count,
                ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                ItemIcon(item, size: 64),
                const SizedBox(width: 14),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Pill(gt(item.rarity), color: Palette.rarity(item.rarity)),
                      Pill(categoryLabel(item.category)),
                      if (item.maxStack > 1)
                        Pill(tr('Stacks to {n}', {'n': item.maxStack})),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (live != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      where.isEmpty
                          ? tr('You have none')
                          : tr('You have {n}', {'n': live.owned(item.id)}),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: where.isEmpty ? Palette.ash : Palette.spring,
                      ),
                    ),
                    for (final w in where)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                w.label,
                                style: const TextStyle(color: Palette.ash),
                              ),
                            ),
                            Text('${w.count}'),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (item.description != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                gt(item.description!),
                style: const TextStyle(height: 1.4),
              ),
            ),
          if (item.stats case final st?
              when st.values.isNotEmpty ||
                  st.perks.isNotEmpty ||
                  st.levels != null) ...[
            SectionTitle(tr('Stats')),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (st.slotLabel.isNotEmpty)
                          Pill(slotName(st.slotLabel), color: Palette.flame),
                        if (st.levels != null && st.levels![1] > 0)
                          Pill(
                            st.levels![0] == st.levels![1]
                                ? tr('Level {n}', {'n': st.levels![0]})
                                : tr('Level {from}–{to}', {
                                  'from': st.levels![0],
                                  'to': st.levels![1],
                                }),
                          ),
                        if (st.comfort > 0)
                          Pill(
                            tr('Comfort +{n}', {'n': st.comfort}),
                            color: Palette.spring,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (final (label, value) in st.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                gt(label),
                                style: const TextStyle(color: Palette.ash),
                              ),
                            ),
                            Text(
                              gt(value),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (st.perks.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        tr('Perks'),
                        style: const TextStyle(
                          color: Palette.veilText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final p in st.perks) Chip(label: Text(gt(p))),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (item.lore != null) Parchment(text: gt(item.lore!)),
          if (item.hint != null || setHints.isNotEmpty) ...[
            SectionTitle(tr('How to get it')),
            for (final h in {if (item.hint != null) item.hint!, ...setHints})
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(gt(h), style: const TextStyle(height: 1.4)),
                ),
              ),
          ],
          if (db.gather.containsKey(item.id) ||
              item.fixedPlacements > 0 ||
              item.chestKinds.isNotEmpty)
            FutureBuilder<Terrain>(
              future: Terrain.instance,
              builder: (context, snap) {
                final where = WhereToGet(
                  db,
                  live,
                  snap.data,
                  here: LiveScope.of(context).pos.value,
                );
                final best = where.best(item.id);
                // unique spots already ranked above aren't listed again below
                final ranked = {for (final r in best) r.spot.poi};
                final uniques = [
                  for (final spot in db.uniqueSpots(item.id).take(6))
                    if (!ranked.contains(spot)) spot,
                ];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (best.isNotEmpty)
                      SectionTitle(tr('Best places for you')),
                    for (final r in best)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          r.spot.kind == 'gather'
                              ? Icons.grass
                              : Icons.inventory_2_outlined,
                          color: Palette.risk(r.risk),
                        ),
                        title: Text(switch (r.spot.kind) {
                          'gather' => tr('Gather'),
                          'unique' => tr('Unique loot'),
                          _ =>
                            gtn(r.spot.poi?.title)?.split(' · ').first ??
                                tr('Chest'),
                        }),
                        subtitle: Text(
                          r.describe(),
                          style: const TextStyle(
                            color: Palette.ash,
                            fontSize: 12,
                          ),
                        ),
                        trailing: TextButton(
                          child: Text(tr('Map')),
                          onPressed: () {
                            Navigator.of(context).popUntil((r) => r.isFirst);
                            mapFocus.value = where.asPoi(item.id, r);
                          },
                        ),
                      ),
                    if (uniques.isNotEmpty || item.chestKinds.isNotEmpty)
                      SectionTitle(tr('Where to find it')),
                    for (final spot in uniques)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.star, color: Palette.gold),
                        title: Text(
                          spot.cat == 'special'
                              ? tr('In one of {n} chests in an area', {
                                'n': spot.candidates,
                              })
                              : tr('Always in a {chest}', {
                                'chest': _lowerEn(
                                  gt(spot.title).split(' · ').first,
                                ),
                              }),
                        ),
                        trailing: TextButton(
                          child: Text(tr('Map')),
                          onPressed: () {
                            Navigator.of(context).popUntil((r) => r.isFirst);
                            mapFocus.value = spot;
                          },
                        ),
                      ),
                    if (item.chestKinds.isNotEmpty)
                      ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.inventory_2_outlined,
                          color: Palette.flame,
                        ),
                        title: Text(
                          tr('Random loot in: {chests}', {
                            'chests': item.chestKinds.map(gt).join(', '),
                          }),
                        ),
                      ),
                  ],
                );
              },
            ),
          if (made.isNotEmpty) ...[
            SectionTitle(
              made.length == 1
                  ? tr('Recipe')
                  : tr('Recipes ({n})', {'n': made.length}),
            ),
            for (final r in made)
              RecipeCard(db: db, recipe: r, onItem: (id) => open(context, id)),
          ],
          if (usedIn.isNotEmpty) ...[
            SectionTitle(tr('Used to make ({n})', {'n': usedIn.length})),
            for (final e in usedIn.entries)
              ItemTile(
                db: db,
                item: db.items[e.key]!,
                trailing: Text(
                  gtn(db.workshops[e.value.workshopId]?.name) ?? '',
                  style: const TextStyle(color: Palette.ash, fontSize: 12),
                ),
              ),
          ],
          if (sets.isNotEmpty) ...[
            SectionTitle(tr('Part of a set')),
            for (final s in sets)
              ListTile(
                leading: const Icon(
                  Icons.collections_bookmark_outlined,
                  color: Palette.veil,
                ),
                title: Text(gt(s.name)),
                subtitle: Text(
                  gt(s.category),
                  style: const TextStyle(color: Palette.ash),
                ),
                onTap:
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SetScreen(db: db, set: s),
                      ),
                    ),
              ),
          ],
        ],
      ),
    );
  }
}

class RecipeCard extends StatelessWidget {
  const RecipeCard({
    super.key,
    required this.db,
    required this.recipe,
    required this.onItem,
  });
  final GameDb db;
  final Recipe recipe;
  final void Function(String id) onItem;

  @override
  Widget build(BuildContext context) {
    final live = LiveScope.of(context).state;
    final w = db.workshops[recipe.workshopId];
    final npc = w?.kind == 'npc';
    final out = recipe.outputs.first;
    final unlocked = live?.recipesUnlocked.contains(recipe.id);
    bool? built(String? itemId) =>
        live == null || itemId == null ? null : (live.placed[itemId] ?? 0) > 0;
    int have(ItemStack i) =>
        live == null ? 0 : db.expand(i).fold(0, (a, id) => a + live.owned(id));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  npc ? Icons.person_outline : Icons.handyman_outlined,
                  size: 18,
                  color: npc ? Palette.spring : Palette.flame,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    gtn(w?.name) ?? tr('Unknown station'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (out.count > 1)
                  Text(
                    tr('makes {n}', {'n': out.count}),
                    style: const TextStyle(color: Palette.ash),
                  ),
                if (recipe.seconds > 0)
                  Text(
                    '  ${formatSeconds(recipe.seconds)}',
                    style: const TextStyle(color: Palette.ash),
                  ),
              ],
            ),
            if (built(w?.itemId) == false)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 26),
                child: Text(
                  tr('Station not built yet'),
                  style: const TextStyle(color: Palette.ember, fontSize: 13),
                ),
              ),
            if (recipe.props.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 26),
                child: Wrap(
                  spacing: 4,
                  children: [
                    Text(
                      tr('Needs'),
                      style: const TextStyle(
                        color: Palette.veilText,
                        fontSize: 13,
                      ),
                    ),
                    for (final p in recipe.props)
                      Text(
                        '${gt(db.workshops[p]?.name ?? p)}${switch (built(db.workshops[p]?.itemId)) {
                          true => ' ✓',
                          false => ' ✗',
                          null => '',
                        }}',
                        style: TextStyle(
                          color:
                              built(db.workshops[p]?.itemId) == false
                                  ? Palette.ember
                                  : Palette.veilText,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final i in recipe.inputs)
                  ActionChip(
                    avatar:
                        live == null
                            ? null
                            : Icon(
                              have(i) >= i.count
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              size: 16,
                              color:
                                  have(i) >= i.count
                                      ? Palette.spring
                                      : Palette.ember,
                            ),
                    label: Text(
                      live == null
                          ? '${i.count} × ${db.shownName(i.ref)}'
                          : '${have(i)}/${i.count} ${db.shownName(i.ref)}',
                    ),
                    onPressed: i.isCategory ? null : () => onItem(i.ref),
                  ),
              ],
            ),
            if (unlocked == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.lock_open,
                      size: 16,
                      color: Palette.spring,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      tr('Unlocked'),
                      style: const TextStyle(
                        color: Palette.spring,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            if (unlocked != true && recipe.unlock != null)
              UnlockView(
                unlock: recipe.unlock!,
                known: live?.knowledge,
                ctx: live?.unlockContext,
                onItem: onItem,
              ),
            if (unlocked == false && recipe.unlock == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr('Locked. Its unlock condition is not in the game data.'),
                  style: const TextStyle(color: Palette.ash, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "To unlock": the condition tree, ticked from the save.
class UnlockView extends StatelessWidget {
  const UnlockView({
    super.key,
    required this.unlock,
    required this.known,
    required this.onItem,
    this.ctx,
  });
  final Unlock unlock;
  final Set<String>? known;

  /// Flame strength, player level and altars, for number conditions.
  final UnlockContext? ctx;
  final void Function(String id) onItem;

  Widget _node(Unlock u, int depth) {
    if (!u.isLeaf) {
      return Padding(
        padding: EdgeInsets.only(left: depth == 0 ? 0 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (depth > 0 || u.op == 'OR')
              Text(
                u.op == 'OR' ? tr('Any of:') : tr('All of:'),
                style: const TextStyle(color: Palette.ash, fontSize: 12),
              ),
            for (final c in u.children) _node(c, depth + 1),
          ],
        ),
      );
    }
    final met = known == null ? null : u.met(known!, ctx);
    return InkWell(
      onTap: u.itemId == null ? null : () => onItem(u.itemId!),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(
              switch (met) {
                true => Icons.check_circle,
                false => Icons.cancel_outlined,
                null => Icons.circle_outlined,
              },
              size: 16,
              color: switch (met) {
                true => Palette.spring,
                false => Palette.ember,
                null => Palette.ash,
              },
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                gtn(u.text) ?? '',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 10),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Palette.night,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.lock_outline, size: 16, color: Palette.flame),
            const SizedBox(width: 6),
            Text(
              tr('To unlock'),
              style: const TextStyle(
                color: Palette.flame,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _node(unlock, 0),
      ],
    ),
  );
}

String formatSeconds(double s) =>
    s >= 60
        ? tr('{n} min', {'n': (s / 60).toStringAsFixed(s % 60 == 0 ? 0 : 1)})
        : tr('{n} s', {'n': s.toStringAsFixed(0)});

/// Lowercase in English ("Always in a gold chest"); other languages keep their own casing.
String _lowerEn(String s) => L10n.lang.code == 'En_Us' ? s.toLowerCase() : s;
