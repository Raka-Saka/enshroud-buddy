import 'package:flutter/material.dart';

import '../data/build.dart';
import '../data/game_db.dart';
import '../data/live_state.dart';
import '../theme.dart';
import 'gear_screen.dart';
import 'item_screen.dart';
import 'plans_screen.dart';
import 'projections_screen.dart';
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
    final title = widget.part == BuildPart.skills ? 'Build' : 'Gear';
    if (s == null) {
      const empty = EmptyState(
        icon: Icons.wifi_tethering_off,
        title: 'No live data yet',
        message: 'Your build appears after the PC agent reads a save.',
      );
      return widget.embedded
          ? const Center(child: empty)
          : Scaffold(
            appBar: AppBar(title: Text(title)),
            body: const Center(child: empty),
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
                label: 'free skill points',
                icon: Icons.auto_awesome,
                onTap: () => _push(SkillTreeScreen(db: db)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StatTile(
                value: '${points.spent}/${points.total}',
                label:
                    '${points.fromLevel} levels · ${points.fromKnowledge} found',
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
          title: const Text('Suggested builds'),
          subtitle: const Text(
            'Eleven directions with the skills to take, scored on damage, area, survival, gathering, building and passives',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(ProjectionsScreen(db: db)),
        ),
      ),
      DashCard(
        title: 'Build target',
        icon: Icons.track_changes,
        action: 'Skill tree',
        onAction: () => _push(SkillTreeScreen(db: db)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              classes
                  .map((e) => '${e.key} ${(e.value * 100).round()}%')
                  .join(' · '),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final w in target.topWeapons)
                  Pill(w, color: Palette.flame),
                for (final v in target.topTraits) Pill(v),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'From your ${target.learnedCount} learned skills'
              '${target.plannedCount > 0 ? ' and ${target.plannedCount} planned (counted 1.5×)' : '. Plan skills in the tree to steer it'}.',
              style: const TextStyle(color: Palette.ash, fontSize: 12),
            ),
          ],
        ),
      ),
      DashCard(
        title: 'Points per area',
        icon: Icons.donut_large,
        color: Palette.veil,
        child: Column(
          children: [
            for (final e in profile.topArchetypes.take(6))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(width: 104, child: Text(e.key)),
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
                        '${e.value} pts',
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
            ? 'Skill plan'
            : 'Skill plan · ${plan.fold(0, (a, k) => a + k.cost)} points',
      ),
      if (plan.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Tap a node in the skill tree to plan the path to it, or adopt a suggested build.',
            style: TextStyle(color: Palette.ash),
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
          title: Text(k.name),
          subtitle: Text(
            (k.description ?? k.archetype).split('\n').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            '${k.cost} pt',
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
          segments: const [
            ButtonSegment(value: null, label: Text('My build')),
            ButtonSegment(value: 'Warrior', label: Text('Warrior')),
            ButtonSegment(value: 'Ranger', label: Text('Ranger')),
            ButtonSegment(value: 'Mage', label: Text('Mage')),
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
            title: Text('${missing.length} upgrades to find'),
            subtitle: Text(
              missing.map((m) => m.item.name).take(3).join(', '),
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
                        '${missing.length} items added to the plan, with where to get them',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Plan'),
            ),
          ),
        ),
      DashCard(
        title: 'Food · ${advisor.foodSlots} slots',
        icon: Icons.restaurant,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (meal.isEmpty)
              const Text(
                'No buff food in your bag or chests, and none you can cook from stock.',
                style: TextStyle(color: Palette.ash),
              ),
            for (final f in meal) _FoodRow(f: f, onTap: () => open(f.item)),
            if (toCook.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Better food to get',
                  style: TextStyle(color: Palette.ash, fontSize: 12),
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
          title: const Text('Everything I own, per slot'),
          subtitle: Text(
            'Runes: $runes · Legendary Runes: $legendaryRunes (from the 4th upgrade)',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(GearScreen(db: db)),
        ),
      ),
      for (final slot in GearAdvisor.slots)
        if (owned[slot] != null || toFind[slot]!.isNotEmpty) ...[
          SectionTitle(ItemStats.slotLabels[slot] ?? slot),
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
              title: Text('To find: ${t.item.name}'),
              subtitle: Text(
                [
                  [
                    '${t.item.rarity}${_levels(t.item.stats?.levels)}',
                    ...t.why,
                  ].join(' · '),
                  ...advisor.howToGet(t.item),
                ].join('\n'),
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: 'Add to the plan',
                icon: const Icon(Icons.add_task),
                onPressed: () {
                  GoalsScope.of(context).add(t.item.id, 1);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${t.item.name} added to the plan')),
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
        '${g.item.name}${g.owned?.level != null ? ' · L${g.owned!.level}' : ''}',
      ),
      subtitle: Text(
        [
          g.current || !better ? (g.where ?? '') : 'Better: ${g.where ?? ''}',
          ...g.why.take(3),
          if (tier != null) 'upgraded ${tier[1]}/${tier[0]}',
          if (upgradesLeft > 0)
            '$upgradesLeft upgrade${upgradesLeft > 1 ? 's' : ''} left (L${g.owned!.topLevel})',
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
      '${f.item.name}${f.have > 0 ? ' · ${f.have} owned' : (f.canCook ? ' · can cook now' : '')}',
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
        ? ' · L${r[0]}'
        : ' · L${r[0]}–${r[1]}';
