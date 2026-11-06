import 'package:flutter/material.dart';

import '../data/build.dart';
import '../data/game_db.dart';
import '../data/live_state.dart';
import '../l10n.dart';
import '../labels.dart';
import '../theme.dart';
import 'gear_screen.dart';
import 'item_screen.dart';
import 'plans_screen.dart';
import 'projections_screen.dart';
import 'share_screen.dart';
import 'skill_tree_screen.dart';
import 'widgets.dart';

/// Which half of the build to show: skills (points, target, plan) or gear (slots, food, upgrades).
enum BuildPart { skills, gear }

/// My build: skill points and archetypes, the skill plan, and gear per slot (worn, in storage, to find).
class BuildScreen extends StatefulWidget {
  const BuildScreen({
    super.key,
    required this.db,
    this.part = BuildPart.skills,
    this.embedded = false,
  });
  final GameDb db;
  final BuildPart part;

  /// Inside the Character tabs: no app bar of its own.
  final bool embedded;

  @override
  State<BuildScreen> createState() => _BuildScreenState();
}

class _BuildScreenState extends State<BuildScreen> {
  String? forClass;

  @override
  void initState() {
    super.initState();
    skillPlan.addListener(_changed);
  }

  @override
  void dispose() {
    skillPlan.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  void _push(Widget page) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final db = widget.db;
    final s = LiveScope.of(context).state;
    final title = widget.part == BuildPart.skills ? tr('Build') : tr('Gear');
    if (s == null) {
      final empty = EmptyState(
        icon: Icons.wifi_tethering_off,
        title: tr('No live data yet'),
        message: tr('Your build appears after the PC agent reads a save.'),
      );
      return widget.embedded
          ? Center(child: empty)
          : Scaffold(
            appBar: AppBar(title: Text(title)),
            body: Center(child: empty),
          );
    }
    final body = ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 32),
      children: widget.part == BuildPart.skills ? _skills(db, s) : _gear(db, s),
    );
    return widget.embedded
        ? body
        : Scaffold(appBar: AppBar(title: Text(title)), body: body);
  }

  List<Widget> _skills(GameDb db, LiveState s) {
    final points = SkillPoints(db, s);
    final profile = BuildProfile(db, s.skills);
    final plan = skillPlan.nodes(db, s.skills.keys.toSet());
    final target = BuildTarget(db, s.skills, plan);
    final totalPts = profile.archetypes.values.fold(0, (a, b) => a + b);
    final classes =
        target.classes.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: StatTile(
                value: '${points.free}',
                label: tr('free skill points'),
                icon: Icons.auto_awesome,
                onTap: () => _push(SkillTreeScreen(db: db)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StatTile(
                value: '${points.spent}/${points.total}',
                label: tr('{levels} levels · {found} found', {
                  'levels': points.fromLevel,
                  'found': points.fromKnowledge,
                }),
                icon: Icons.hub_outlined,
                color: Palette.veil,
                onTap: () => _push(SkillTreeScreen(db: db)),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      Card(
        child: ListTile(
          leading: const Icon(Icons.auto_graph, color: Palette.spring),
          title: Text(tr('Suggested builds')),
          subtitle: Text(
            tr(
              'Eleven directions with the skills to take, scored on damage, area, survival, gathering, building and passives',
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(ProjectionsScreen(db: db)),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.share_outlined, color: Palette.flame),
          title: Text(tr('Share build')),
          subtitle: Text(
            tr('A picture of your build and gear for Discord or a chat'),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(ShareBuildScreen(db: db)),
        ),
      ),
      DashCard(
        title: tr('Build target'),
        icon: Icons.track_changes,
        action: tr('Skill tree'),
        onAction: () => _push(SkillTreeScreen(db: db)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              classes
                  .map(
                    (e) => '${classLabel(e.key)} ${(e.value * 100).round()}%',
                  )
                  .join(' · '),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final w in target.topWeapons)
                  Pill(weaponLabel(w), color: Palette.flame),
                for (final v in target.topTraits) Pill(v),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              target.plannedCount > 0
                  ? tr(
                    'From your {n} learned skills and {planned} planned (counted 1.5×).',
                    {'n': target.learnedCount, 'planned': target.plannedCount},
                  )
                  : tr(
                    'From your {n} learned skills. Plan skills in the tree to steer it.',
                    {'n': target.learnedCount},
                  ),
              style: const TextStyle(color: Palette.ash, fontSize: 12),
            ),
          ],
        ),
      ),
      DashCard(
        title: tr('Points per area'),
        icon: Icons.donut_large,
        color: Palette.veil,
        child: Column(
          children: [
            for (final e in profile.topArchetypes.take(6))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(width: 104, child: Text(gt(e.key))),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: e.value / totalPts,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        tr('{n} pts', {'n': e.value}),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Palette.ash,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      SectionTitle(
        plan.isEmpty
            ? tr('Skill plan')
            : tr('Skill plan · {n} points', {
              'n': plan.fold<int>(0, (a, k) => a + k.cost),
            }),
      ),
      if (plan.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            tr(
              'Tap a node in the skill tree to plan the path to it, or adopt a suggested build.',
            ),
            style: const TextStyle(color: Palette.ash),
          ),
        ),
      for (final k in plan)
        ListTile(
          dense: true,
          leading: Icon(
            Icons.circle_outlined,
            size: 16,
            color: classColor[k.cls] ?? Palette.flame,
          ),
          title: Text(gt(k.name)),
          subtitle: Text(
            gt(k.description ?? k.archetype).split('\n').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            tr('{n} pt', {'n': k.cost}),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
    ];
  }

  List<Widget> _gear(GameDb db, LiveState s) {
    void open(Item it) => _push(ItemScreen(db: db, item: it));
    final plan = skillPlan.nodes(db, s.skills.keys.toSet());
    final target = BuildTarget(db, s.skills, plan, onlyClass: forClass);
    final advisor = GearAdvisor(db, s, target);
    final owned = advisor.owned();
    final toFind = {
      for (final slot in GearAdvisor.slots) slot: advisor.upgrades(slot, owned),
    };
    // per slot, the best item to find that beats everything owned
    final missing = [
      for (final slot in GearAdvisor.slots)
        if (toFind[slot]!.firstOrNull case final t?) t,
    ];
    final foods = advisor.food();
    final meal = advisor.meal(foods);
    final mealIds = {for (final f in meal) f.item.id};
    final toCook = [
      for (final f in foods)
        if (!f.ready && !mealIds.contains(f.item.id)) f,
    ].take(3);
    final runes = s.owned('41a792dc'), legendaryRunes = s.owned('a8fcdc84');

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SegmentedButton<String?>(
          segments: [
            ButtonSegment(value: null, label: Text(tr('My build'))),
            ButtonSegment(value: 'Warrior', label: Text(classLabel('Warrior'))),
            ButtonSegment(value: 'Ranger', label: Text(classLabel('Ranger'))),
            ButtonSegment(value: 'Mage', label: Text(classLabel('Mage'))),
          ],
          selected: {forClass},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => forClass = v.first),
        ),
      ),
      if (missing.isNotEmpty)
        Card(
          color: const Color(0xFF2A2214),
          child: ListTile(
            leading: const Icon(Icons.add_task, color: Palette.flame),
            title: Text(
              trn(
                missing.length,
                '{n} upgrades to find',
                '{n} upgrades to find',
              ),
            ),
            subtitle: Text(
              missing.map((m) => gt(m.item.name)).take(3).join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: FilledButton(
              onPressed: () async {
                final goals = GoalsScope.of(context);
                for (final g in missing) {
                  if (!goals.all.any((x) => x.itemId == g.item.id)) {
                    await goals.add(g.item.id, 1);
                  }
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        trn(
                          missing.length,
                          '{n} items added to the plan, with where to get them',
                          '{n} items added to the plan, with where to get them',
                        ),
                      ),
                    ),
                  );
                }
              },
              child: Text(tr('Plan')),
            ),
          ),
        ),
      DashCard(
        title: tr('Food · {n} slots', {'n': advisor.foodSlots}),
        icon: Icons.restaurant,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (meal.isEmpty)
              Text(
                tr(
                  'No buff food in your bag or chests, and none you can cook from stock.',
                ),
                style: const TextStyle(color: Palette.ash),
              ),
            for (final f in meal) _FoodRow(f: f, onTap: () => open(f.item)),
            if (toCook.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr('Better food to get'),
                  style: const TextStyle(color: Palette.ash, fontSize: 12),
                ),
              ),
              for (final f in toCook)
                _FoodRow(
                  f: f,
                  onTap: () => open(f.item),
                  how: advisor.howToGet(f.item),
                ),
            ],
          ],
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.inventory_2_outlined, color: Palette.flame),
          title: Text(tr('Everything I own, per slot')),
          subtitle: Text(
            tr(
              'Runes: {runes} · Legendary Runes: {legendary} (from the 4th upgrade)',
              {'runes': runes, 'legendary': legendaryRunes},
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(GearScreen(db: db)),
        ),
      ),
      for (final slot in GearAdvisor.slots)
        if (owned[slot] != null || toFind[slot]!.isNotEmpty) ...[
          SectionTitle(slotName(ItemStats.slotLabels[slot] ?? slot)),
          // what's in use, then the best owned piece that beats it
          for (final g in [
            ...?owned[slot]?.where((g) => g.current),
            ...?owned[slot]?.where((g) => !g.current).take(1),
          ])
            _OwnedRow(
              db: db,
              g: g,
              better: owned[slot]!.any((g) => g.current),
              onTap: () => open(g.item),
            ),
          for (final t in toFind[slot]!)
            ListTile(
              dense: true,
              leading: const Icon(Icons.search, color: Palette.gold),
              title: Text(tr('To find: {item}', {'item': gt(t.item.name)})),
              subtitle: Text(
                [
                  [
                    '${gt(t.item.rarity)}${_levels(t.item.stats?.levels)}',
                    ...t.why,
                  ].join(' · '),
                  ...advisor.howToGet(t.item),
                ].join('\n'),
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: tr('Add to the plan'),
                icon: const Icon(Icons.add_task),
                onPressed: () {
                  GoalsScope.of(context).add(t.item.id, 1);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        tr('{item} added to the plan', {
                          'item': gt(t.item.name),
                        }),
                      ),
                    ),
                  );
                },
              ),
              onTap: () => open(t.item),
            ),
        ],
    ];
  }
}

class _OwnedRow extends StatelessWidget {
  const _OwnedRow({
    required this.db,
    required this.g,
    required this.better,
    required this.onTap,
  });
  final GameDb db;
  final GearOption g;

  /// Something is in use in the slot, so a piece that isn't is shown as better than it.
  final bool better;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tier = g.owned?.tier;
    final upgradesLeft = g.owned?.upgradesLeft ?? 0;
    return ListTile(
      dense: true,
      leading: Icon(
        g.current ? Icons.shield : Icons.shield_outlined,
        color: g.current ? Palette.flame : Palette.rarity(g.item.rarity),
      ),
      title: Text(
        '${gt(g.item.name)}${g.owned?.level != null ? ' · ${tr('L{n}', {'n': g.owned!.level})}' : ''}',
      ),
      subtitle: Text(
        [
          g.current || !better
              ? (g.place ?? '')
              : tr('Better: {where}', {'where': g.place ?? ''}),
          ...g.why.take(3),
          if (tier != null)
            tr('upgraded {done}/{all}', {'done': tier[1], 'all': tier[0]}),
          if (upgradesLeft > 0)
            trn(
              upgradesLeft,
              '{n} upgrade left (L{level})',
              '{n} upgrades left (L{level})',
              {'level': g.owned!.topLevel},
            ),
        ].where((t) => t.isNotEmpty).join(' · '),
        style: TextStyle(
          color: upgradesLeft > 0 ? Palette.spring : Palette.ash,
          fontSize: 12,
        ),
      ),
      onTap: onTap,
    );
  }
}

class _FoodRow extends StatelessWidget {
  const _FoodRow({required this.f, required this.onTap, this.how});
  final FoodOption f;
  final VoidCallback onTap;
  final List<String>? how;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      Icons.restaurant,
      color: f.ready ? Palette.flame : Palette.ash,
    ),
    title: Text(
      '${gt(f.item.name)}${f.have > 0 ? tr(' · {n} owned', {'n': f.have}) : (f.canCook ? tr(' · can cook now') : '')}',
    ),
    subtitle: Text([f.why.join(', '), ...?how].join('\n')),
    onTap: onTap,
  );
}

/// " · L40" for a fixed-level item, " · L30–55" for one that comes at the level of where it drops.
String _levels(List<int>? r) =>
    r == null || r[1] == 0
        ? ''
        : r[0] == r[1]
        ? ' · ${tr('L{n}', {'n': r[0]})}'
        : ' · ${tr('L{from}–{to}', {'from': r[0], 'to': r[1]})}';
