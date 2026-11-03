import 'package:flutter/material.dart';

import '../data/build.dart';
import '../data/game_db.dart';
import '../data/live_state.dart';
import '../data/survival.dart';
import '../data/tasks.dart';
import '../data/where.dart';
import '../nav.dart';
import '../theme.dart';
import 'ask_screen.dart';
import 'items_screen.dart';
import 'journey_screen.dart';
import 'setup_screen.dart';
import 'map_screen.dart';
import 'plans_screen.dart';
import 'projections_screen.dart';
import 'skill_tree_screen.dart';
import 'survival_screen.dart';
import 'widgets.dart';

/// Today: who you are, what you can survive, what to do next, how far you've come.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.db});
  final GameDb db;

  void _push(BuildContext context, Widget page) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final live = LiveScope.of(context);
    final s = live.state;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: live.refresh,
        child: CustomScrollView(
          slivers: [
            SliverAppBar.large(
              pinned: true,
              title: Text(s?.character ?? 'Enshrouded'),
              actions: [
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: live.loading ? null : live.refresh,
                ),
                IconButton(
                  tooltip: 'Setup: PC agent and game save',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => _push(context, const SetupScreen()),
                ),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    if (s != null)
                      Text(
                        '${s.world} · ',
                        style: const TextStyle(color: Palette.ash),
                      ),
                    Flexible(child: LiveBadge(live: live)),
                  ],
                ),
              ),
            ),
            // ask the companion: a search-like pill, the first thing under the status
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Material(
                  color: Palette.shroudHigh,
                  shape: const StadiumBorder(),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => _push(context, AskScreen(db: db)),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 18, right: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.auto_awesome, color: Palette.flame),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 14),
                              child: Text(
                                'Ask anything about your game',
                                style: TextStyle(color: Palette.ash),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Search items',
                            icon: const Icon(Icons.search, color: Palette.ash),
                            onPressed:
                                () => _push(
                                  context,
                                  Scaffold(
                                    appBar: AppBar(title: const Text('Items')),
                                    body: ItemsScreen(
                                      db: db,
                                      embedded: true,
                                      autofocus: true,
                                    ),
                                  ),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (s != null && s.warnings.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Material(
                    color: Palette.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(Radii.tile),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.warning_amber,
                            color: Palette.amber,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'The save has something the reader doesn\'t know yet, so some of it may be '
                              'missing:\n${s.warnings.join('\n')}',
                              style: const TextStyle(
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (s == null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.wifi_tethering_off,
                  title: 'Waiting for the PC agent',
                  message:
                      'Start the agent on your PC (start.bat), then open Setup and enter the address and pairing code its tray menu shows. Your character appears within seconds.',
                  actions: [
                    FilledButton.tonal(
                      onPressed: () => _push(context, const SetupScreen()),
                      child: const Text('Setup'),
                    ),
                  ],
                ),
              )
            else
              SliverList.list(children: _cards(context, s)),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  List<Widget> _cards(BuildContext context, LiveState s) {
    final points = SkillPoints(db, s);
    final sv = Survival(db, s);
    String mins(int secs) => Survival.format(secs);
    final stats = [
      StatTile(
        value: '${s.level}',
        label: 'Level',
        icon: Icons.person_outline,
        onTap: () => _push(context, JourneyScreen(db: db)),
      ),
      StatTile(
        value: '${s.flameLevel}',
        label: 'Flame strength',
        icon: Icons.local_fire_department,
        color: Palette.ember,
        onTap: () => _push(context, SurvivalScreen(db: db)),
      ),
      StatTile(
        value: '${points.free}',
        label: 'Skill points',
        icon: Icons.auto_awesome,
        color: points.free > 0 ? Palette.flame : Palette.ash,
        onTap: () => _push(context, SkillTreeScreen(db: db)),
      ),
      StatTile(
        value: mins(sv.shroudSeconds),
        label: 'In the Shroud',
        icon: Icons.hourglass_bottom,
        color: Palette.veil,
        onTap: () => _push(context, SurvivalScreen(db: db)),
      ),
      StatTile(
        value: '${sv.frostResistance}',
        label: sv.coldProtected ? 'Frost (no freezing)' : 'Frost resist',
        icon: Icons.ac_unit,
        color: const Color(0xFF8CC8FF),
        onTap: () => _push(context, SurvivalScreen(db: db)),
      ),
      StatTile(
        value: mins(sv.oxygenSeconds),
        label: 'Breath',
        icon: Icons.bubble_chart_outlined,
        color: Palette.spring,
        onTap: () => _push(context, SurvivalScreen(db: db)),
      ),
    ];

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth > 560 ? 6 : 3;
            final w = (c.maxWidth - 8 * (cols - 1)) / cols;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final t in stats) SizedBox(width: w, child: t)],
            );
          },
        ),
      ),
      _NextUp(db: db, state: s),
      _BuildCard(db: db, state: s, points: points),
      _ProgressCard(db: db, state: s),
      if (s.bases.isNotEmpty)
        DashCard(
          title: 'Bases',
          icon: Icons.cottage_outlined,
          action: 'All',
          onAction: () => goTo(Tabs.character, character: CharacterTabs.bases),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final b in s.bases)
                ActionChip(
                  avatar: const Icon(
                    Icons.local_fire_department,
                    size: 16,
                    color: Palette.flame,
                  ),
                  label: Text('${b.label} · altar ${b.altarLevel}'),
                  onPressed:
                      () =>
                          mapFocus.value = Poi({
                            'c': 'spot',
                            'k': 'Altar ${b.altarLevel} · build zone ${b.zone}',
                            't': b.label,
                            'x': b.mapX,
                            'y': b.mapY,
                          }),
                ),
            ],
          ),
        ),
    ];
  }
}

/// The first open tasks of the plan, or how to start one.
class _NextUp extends StatelessWidget {
  const _NextUp({required this.db, required this.state});
  final GameDb db;
  final LiveState state;

  static IconData icon(TaskKind k) => switch (k) {
    TaskKind.unlock => Icons.lock_outline,
    TaskKind.station => Icons.construction,
    TaskKind.prepare => Icons.shield_outlined,
    TaskKind.gather => Icons.grass,
    TaskKind.fetch => Icons.inventory_2_outlined,
    TaskKind.craft => Icons.handyman_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final goals = GoalsScope.of(context).all;
    if (goals.isEmpty) {
      return DashCard(
        title: 'Next up',
        icon: Icons.flag_outlined,
        child: EmptyState(
          icon: Icons.checklist,
          title: 'Nothing planned',
          message:
              'Pick something to make or find; the plan works out unlocks, stations, gathering and crafting.',
          actions: [
            FilledButton.tonal(
              onPressed:
                  () => goTo(Tabs.character, character: CharacterTabs.gear),
              child: const Text('Missing gear'),
            ),
            OutlinedButton(
              onPressed: () => goTo(Tabs.codex),
              child: const Text('Browse items'),
            ),
          ],
        ),
      );
    }
    return FutureBuilder<Terrain>(
      future: Terrain.instance,
      builder: (context, snap) {
        final here = LiveScope.of(context).pos.value;
        final plan = TaskPlan(
          db,
          state,
          goals,
          WhereToGet(db, state, snap.data, here: here),
        );
        // what you can do where you stand comes first (live position from the game)
        final open = nextUp(plan, here);
        return DashCard(
          title: 'Next up',
          icon: Icons.flag_outlined,
          action: '${open.length} tasks',
          onAction: () => goTo(Tabs.plan),
          child:
              open.isEmpty
                  ? const Text(
                    'Everything is in hand: craft away.',
                    style: TextStyle(color: Palette.spring),
                  )
                  : Column(
                    children: [
                      for (final n in open.take(4))
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            n.here ? Icons.near_me : icon(n.task.kind),
                            color: n.here ? Palette.spring : Palette.flame,
                          ),
                          title: Text(n.task.title),
                          subtitle: switch ((n.note, n.task)) {
                            (final note?, _) => Text(
                              note,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Palette.spring),
                            ),
                            (_, final t) when t.spots.isNotEmpty => Text(
                              t.spots.first.describe(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            (_, Task(detail: final d?)) => Text(
                              d,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            _ => null,
                          },
                          onTap: () => goTo(Tabs.plan),
                        ),
                    ],
                  ),
        );
      },
    );
  }
}

/// The build in one look: class mix, weapons, what it values; into the tree and the projections.
class _BuildCard extends StatelessWidget {
  const _BuildCard({
    required this.db,
    required this.state,
    required this.points,
  });
  final GameDb db;
  final LiveState state;
  final SkillPoints points;

  @override
  Widget build(BuildContext context) {
    final plan = skillPlan.nodes(db, state.skills.keys.toSet());
    final t = BuildTarget(db, state.skills, plan);
    final classes =
        t.classes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return DashCard(
      title: 'Your build',
      icon: Icons.account_tree_outlined,
      action: 'Details',
      onAction: () => goTo(Tabs.character, character: CharacterTabs.build),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // class mix as one segmented bar
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  for (final e in classes)
                    Expanded(
                      flex: (e.value * 100).round().clamp(1, 100),
                      child: Container(color: classColor[e.key] ?? Palette.ash),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            classes
                .map((e) => '${e.key} ${(e.value * 100).round()}%')
                .join(' · '),
            style: const TextStyle(color: Palette.ash, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final w in t.topWeapons) Pill(w, color: Palette.flame),
              for (final v in t.topTraits.take(4)) Pill(v),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.hub_outlined, size: 18),
                  label: const Text('Skill tree'),
                  onPressed:
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SkillTreeScreen(db: db),
                        ),
                      ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.auto_graph, size: 18),
                  label: const Text('Suggestions'),
                  onPressed:
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ProjectionsScreen(db: db),
                        ),
                      ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// How far the save has come: recipes, skills, set entries, lore, quests.
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.db, required this.state});
  final GameDb db;
  final LiveState state;

  @override
  Widget build(BuildContext context) {
    final k = state.knowledge;
    final setEntries = [for (final x in db.sets) ...x.entries];
    final lorePages = [for (final d in db.lore) ...d.pages];
    final quests =
        db.quests
            .where((q) => q.pages.isNotEmpty && q.pages.last.done != null)
            .toList();
    final h = LiveScope.of(context).history;
    return DashCard(
      title: 'Progress',
      icon: Icons.insights,
      color: Palette.veil,
      action: 'Journey',
      onAction:
          () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => JourneyScreen(db: db)),
          ),
      child: Column(
        children: [
          if (h.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'Since ${JourneyScreen.day(h.first.t)}: +${h.last.level - h.first.level} levels, +${h.last.recipes - h.first.recipes} recipes, +${h.last.roots - h.first.roots} Shroud Roots',
                style: const TextStyle(color: Palette.spring, fontSize: 12.5),
              ),
            ),
          ProgressLine(
            label: 'Recipes unlocked',
            icon: Icons.menu_book_outlined,
            done: state.recipesUnlocked.length,
            total: db.recipes.length,
            onTap: () => goTo(Tabs.codex, codex: CodexTabs.items),
          ),
          ProgressLine(
            label: 'Skills learned',
            icon: Icons.hub_outlined,
            done: state.skills.length,
            total: db.skills.where((s) => s.type != 'Root').length,
            onTap:
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SkillTreeScreen(db: db)),
                ),
          ),
          ProgressLine(
            label: 'Set pieces collected',
            icon: Icons.collections_bookmark_outlined,
            done: setEntries.where((e) => e.done?.likely(k) ?? false).length,
            total: setEntries.length,
            onTap: () => goTo(Tabs.codex, codex: CodexTabs.sets),
          ),
          ProgressLine(
            label: 'Lore pages found',
            icon: Icons.auto_stories_outlined,
            done: lorePages.where((p) => p.done?.likely(k) ?? false).length,
            total: lorePages.length,
            onTap: () => goTo(Tabs.codex, codex: CodexTabs.lore),
          ),
          ProgressLine(
            label: 'Quests completed',
            icon: Icons.flag_outlined,
            done:
                quests
                    .where(
                      (q) => q.pages.last.done!.likely(k, state.unlockContext),
                    )
                    .length,
            total: quests.length,
            onTap: () => goTo(Tabs.codex, codex: CodexTabs.quests),
          ),
        ],
      ),
    );
  }
}
