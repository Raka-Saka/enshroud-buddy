import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/item_icons.dart';
import '../data/live_state.dart';
import '../data/planner.dart';
import '../data/tasks.dart';
import '../data/where.dart';
import '../nav.dart';
import '../theme.dart';
import 'item_screen.dart';
import 'map_screen.dart';
import 'widgets.dart';

class GoalsScope extends InheritedNotifier<Goals> {
  const GoalsScope({super.key, required Goals goals, required super.child})
    : super(notifier: goals);

  static Goals of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GoalsScope>()!.notifier!;
}

/// Ask how many, then add the item to the shopping list.
Future<void> addGoal(BuildContext context, Item item, int suggested) async {
  final goals = GoalsScope.of(context);
  var n = suggested;
  final ok = await showDialog<bool>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, set) => AlertDialog(
                title: Text('Plan ${item.name}'),
                content: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: n > 1 ? () => set(() => n--) : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '$n',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    IconButton(
                      onPressed: () => set(() => n++),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                    IconButton(
                      onPressed: () => set(() => n += 10),
                      icon: const Text('+10'),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Add to list'),
                  ),
                ],
              ),
        ),
  );
  if (ok == true) {
    await goals.add(item.id, n);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${item.name} ×$n added to the shopping list')),
      );
    }
  }
}

class PlansScreen extends StatelessWidget {
  const PlansScreen({super.key, required this.db});
  final GameDb db;

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
    final goals = GoalsScope.of(context);
    final state = LiveScope.of(context).state;
    final planner = Planner(db, state);
    final steps = planner.planAll(goals.all);
    final gather =
        planner.toGather.entries.toList()
          ..sort((a, b) => db.nameOf(a.key).compareTo(db.nameOf(b.key)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan'),
        actions: [
          if (gather.isNotEmpty)
            IconButton(
              tooltip: 'Show where to get everything on the map',
              icon: const Icon(Icons.map_outlined),
              onPressed: () {
                Navigator.of(context).popUntil((r) => r.isFirst);
                showShopping.value = true;
              },
            ),
        ],
      ),
      body:
          goals.all.isEmpty
              ? Center(
                child: EmptyState(
                  icon: Icons.checklist,
                  title: 'Nothing planned yet',
                  message:
                      'Add missing gear from Character, or tap + on any item. The plan then lists unlocks, stations, where to gather and what to craft.',
                  actions: [
                    FilledButton.tonal(
                      onPressed:
                          () => goTo(
                            Tabs.character,
                            character: CharacterTabs.gear,
                          ),
                      child: const Text('Missing gear'),
                    ),
                    OutlinedButton(
                      onPressed: () => goTo(Tabs.codex),
                      child: const Text('Browse items'),
                    ),
                  ],
                ),
              )
              : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  if (state == null)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'No live data from the PC agent: counting as if you own nothing.',
                        style: TextStyle(color: Palette.ember),
                      ),
                    ),
                  FutureBuilder<Terrain>(
                    future: Terrain.instance,
                    builder: (context, snap) {
                      final where = WhereToGet(
                        db,
                        state,
                        snap.data,
                        here: LiveScope.of(context).pos.value,
                      );
                      final plan = TaskPlan(db, state, goals.all, where);
                      return _TaskList(
                        db: db,
                        plan: plan,
                        where: where,
                        here: [
                          for (final n in nextUp(
                            plan,
                            LiveScope.of(context).pos.value,
                          ))
                            if (n.here) n,
                        ],
                        open: (id) => open(context, id),
                      );
                    },
                  ),
                  const SectionTitle('Goals'),
                  for (var i = 0; i < goals.all.length; i++)
                    Card(
                      child: ExpansionTile(
                        shape: const Border(),
                        initiallyExpanded: goals.all.length == 1,
                        leading: ItemIcon(
                          db.items[goals.all[i].itemId],
                          fallback: Icons.flag_outlined,
                        ),
                        title: Text(
                          '${db.nameOf(goals.all[i].itemId)} ×${goals.all[i].count}',
                        ),
                        subtitle: Text(
                          steps[i].recipe == null
                              ? 'No recipe: gather it'
                              : '${db.workshops[steps[i].recipe!.workshopId]?.name ?? ''}${planner.unlocked(steps[i].recipe!) ? '' : ' · locked'}',
                          style: TextStyle(
                            color:
                                steps[i].recipe != null &&
                                        !planner.unlocked(steps[i].recipe!)
                                    ? Palette.ember
                                    : Palette.ash,
                            fontSize: 12,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'One fewer',
                              icon: const Icon(Icons.remove),
                              onPressed:
                                  () => goals.setCount(
                                    goals.all[i],
                                    goals.all[i].count - 1,
                                  ),
                            ),
                            IconButton(
                              tooltip: 'One more',
                              icon: const Icon(Icons.add),
                              onPressed:
                                  () => goals.setCount(
                                    goals.all[i],
                                    goals.all[i].count + 1,
                                  ),
                            ),
                          ],
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          12,
                          0,
                          12,
                          10,
                        ),
                        children: [
                          for (final c in steps[i].children)
                            _StepView(
                              db: db,
                              step: c,
                              planner: planner,
                              depth: 0,
                              open: (id) => open(context, id),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
    );
  }
}

class _StepView extends StatelessWidget {
  const _StepView({
    required this.db,
    required this.step,
    required this.planner,
    required this.depth,
    required this.open,
  });
  final GameDb db;
  final PlanStep step;
  final Planner planner;
  final int depth;
  final void Function(String) open;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) =
        step.missing == 0
            ? (Icons.check_circle, Palette.spring, 'have ${step.need}')
            : step.crafted
            ? (
              Icons.handyman_outlined,
              planner.unlocked(step.recipe!) ? Palette.flame : Palette.ember,
              '${step.fromStock > 0 ? 'have ${step.fromStock}, ' : ''}craft ${step.batches}× at ${db.workshops[step.recipe!.workshopId]?.name ?? '?'}'
                  '${planner.unlocked(step.recipe!) ? '' : ' (locked)'}',
            )
            : (
              Icons.hardware_outlined,
              Palette.ember,
              '${step.fromStock > 0 ? 'have ${step.fromStock}, ' : ''}gather ${step.missing}',
            );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: step.ref.startsWith('cat:') ? null : () => open(step.ref),
          child: Padding(
            padding: EdgeInsets.only(left: depth * 16.0, top: 4, bottom: 4),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${step.need} × ${db.nameOf(step.ref)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: '  $text',
                          style: TextStyle(color: color, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        for (final c in step.children)
          _StepView(
            db: db,
            step: c,
            planner: planner,
            depth: depth + 1,
            open: open,
          ),
      ],
    );
  }
}

String _kindLabel(RankedSpot r) => switch (r.spot.kind) {
  'gather' => 'Gather',
  'unique' => 'Unique loot',
  'zone' => 'Zone: ${r.spot.zone}',
  _ => r.spot.poi?.title.split(' · ').first ?? 'Chest',
};

void _showOnMap(
  BuildContext context,
  WhereToGet where,
  String itemId,
  RankedSpot r,
) {
  Navigator.of(context).popUntil((route) => route.isFirst);
  mapFocus.value = where.asPoi(itemId, r);
}

/// The plan as numbered stages: unlock, build, gather and find, take from storage, craft.
class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.db,
    required this.plan,
    required this.where,
    required this.open,
    this.here = const [],
  });
  final GameDb db;
  final TaskPlan plan;
  final WhereToGet where;
  final void Function(String id) open;

  /// Tasks you can do where you stand (live position), shown first.
  final List<NextUp> here;

  static const stages = [
    (TaskKind.unlock, 'Unlock recipes'),
    (TaskKind.station, 'Build stations'),
    (TaskKind.prepare, 'Prepare'),
    (TaskKind.gather, 'Gather and find'),
    (TaskKind.fetch, 'Take from storage'),
    (TaskKind.craft, 'Craft, in this order'),
  ];

  @override
  Widget build(BuildContext context) {
    var n = 0;
    final open = plan.tasks.where((t) => !t.ready).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle('Tasks · $open to do'),
        if (here.isNotEmpty)
          Card(
            color: Palette.spring.withValues(alpha: 0.10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 6, 16, 2),
                    child: Row(
                      children: [
                        Icon(Icons.near_me, size: 18, color: Palette.spring),
                        SizedBox(width: 8),
                        Text(
                          'Here now',
                          style: TextStyle(
                            fontFamily: 'Cinzel',
                            fontWeight: FontWeight.w700,
                            color: Palette.spring,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final n in here)
                    ListTile(
                      dense: true,
                      leading: ItemIcon(
                        db.items[n.task.itemId],
                        size: 32,
                        ring: Palette.spring,
                      ),
                      title: Text(n.task.title),
                      subtitle: Text(
                        n.note ?? '',
                        style: const TextStyle(color: Palette.spring),
                      ),
                      onTap:
                          n.task.itemId == null
                              ? null
                              : () => this.open(n.task.itemId!),
                    ),
                ],
              ),
            ),
          ),
        for (final (kind, label) in stages)
          if (plan.of(kind).isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 12,
                            backgroundColor: Palette.flame,
                            foregroundColor: Palette.night,
                            child: Text(
                              '${++n}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              label,
                              style: const TextStyle(
                                fontFamily: 'Cinzel',
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          Text(
                            '${plan.of(kind).length}',
                            style: const TextStyle(color: Palette.ash),
                          ),
                        ],
                      ),
                    ),
                    for (final t in plan.of(kind))
                      _TaskTile(db: db, t: t, where: where, open: this.open),
                  ],
                ),
              ),
            ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text(
            'Stock counts your bag and every chest in every base. Splitting it by base needs chest positions (the two-chest test).',
            style: TextStyle(color: Palette.ash, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.db,
    required this.t,
    required this.where,
    required this.open,
  });
  final GameDb db;
  final Task t;
  final WhereToGet where;
  final void Function(String id) open;

  @override
  Widget build(BuildContext context) {
    const sub = TextStyle(color: Palette.ash, fontSize: 12);
    switch (t.kind) {
      case TaskKind.unlock:
        return ExpansionTile(
          dense: true,
          shape: const Border(),
          leading: const Icon(Icons.lock_outline, color: Palette.ember),
          title: Text(t.title),
          subtitle: Text(
            t.detail ?? t.steps.map((s) => s.text).take(2).join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: sub,
          ),
          children: [
            for (final s in t.steps)
              ListTile(
                dense: true,
                leading: Icon(
                  s.checkable
                      ? Icons.radio_button_unchecked
                      : Icons.help_outline,
                  size: 18,
                  color: Palette.ash,
                ),
                title: Text(s.text),
                subtitle:
                    s.spots.isEmpty
                        ? (s.checkable
                            ? null
                            : const Text(
                              'The save can\'t tell whether this is done',
                              style: sub,
                            ))
                        : Text(
                          '${_kindLabel(s.spots.first)} · ${s.spots.first.describe()}',
                          style: sub,
                        ),
                trailing:
                    s.spots.isEmpty
                        ? null
                        : TextButton(
                          onPressed:
                              () => _showOnMap(
                                context,
                                where,
                                s.itemId!,
                                s.spots.first,
                              ),
                          child: const Text('Map'),
                        ),
              ),
            if (t.itemId != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => open(t.itemId!),
                  child: const Text('Item page'),
                ),
              ),
          ],
        );
      case TaskKind.station:
        final craftable = db.madeBy.containsKey(t.itemId);
        return ListTile(
          dense: true,
          leading: const Icon(Icons.construction, color: Palette.ember),
          title: Text(t.title),
          subtitle: Text(t.detail ?? '', style: sub),
          trailing:
              craftable
                  ? TextButton(
                    onPressed: () => addGoal(context, db.items[t.itemId]!, 1),
                    child: const Text('Plan it'),
                  )
                  : null,
          onTap: () => open(t.itemId!),
        );
      case TaskKind.gather:
        final best = t.spots.firstOrNull;
        return ExpansionTile(
          dense: true,
          shape: const Border(),
          leading: ItemIcon(
            db.items[t.itemId],
            size: 32,
            fallback:
                best == null
                    ? (t.detail == null ? Icons.help_outline : Icons.forest)
                    : (best.spot.kind == 'gather'
                        ? Icons.grass
                        : Icons.inventory_2_outlined),
            ring: best == null ? Palette.ash : Palette.risk(best.risk),
          ),
          title: Text(t.title),
          subtitle: Text(
            [
              if (t.detail != null &&
                  (best == null || (db.items[t.itemId]?.isCommon ?? false)))
                t.detail!,
              if (best != null) '${_kindLabel(best)} · ${best.describe()}',
              if (best == null && t.detail == null)
                'No mapped spot: mined from terrain, or from vendors or quests',
            ].join('\n'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: sub,
          ),
          children: [
            for (final r in t.spots)
              ListTile(
                dense: true,
                leading: Icon(Icons.place, color: Palette.risk(r.risk)),
                title: Text(_kindLabel(r)),
                subtitle: Text(r.describe(), style: sub),
                trailing: TextButton(
                  onPressed: () => _showOnMap(context, where, t.itemId!, r),
                  child: const Text('Map'),
                ),
              ),
            if (t.detail != null &&
                best != null &&
                !(db.items[t.itemId]?.isCommon ?? false))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(t.detail!, style: sub),
              ),
            if (t.itemId != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => open(t.itemId!),
                  child: const Text('Item page'),
                ),
              ),
          ],
        );
      case TaskKind.prepare:
        return ListTile(
          dense: true,
          leading: const Icon(Icons.shield_outlined, color: Palette.amber),
          title: Text(t.title),
          subtitle: Text(t.detail ?? '', style: sub),
        );
      case TaskKind.fetch:
        return ListTile(
          dense: true,
          leading: ItemIcon(
            db.items[t.itemId],
            size: 32,
            fallback: t.ready ? Icons.check_circle : Icons.inventory_2_outlined,
            ring: t.ready ? Palette.spring : Palette.flame,
          ),
          title: Text(t.title),
          subtitle: Text(t.ready ? 'In your bag' : t.detail ?? '', style: sub),
          onTap: t.itemId == null ? null : () => open(t.itemId!),
        );
      case TaskKind.craft:
        return ListTile(
          dense: true,
          leading: ItemIcon(
            db.items[t.itemId],
            size: 32,
            fallback: Icons.handyman_outlined,
            ring: Palette.flame,
          ),
          title: Text(t.title),
          subtitle: Text(t.detail ?? '', style: sub),
          onTap: t.itemId == null ? null : () => open(t.itemId!),
        );
    }
  }
}
