import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../l10n.dart';
import '../theme.dart';
import 'item_screen.dart';
import 'widgets.dart';

/// Feeders and their stock, produce waiting in animals, seeds I own.
class FarmScreen extends StatelessWidget {
  const FarmScreen({super.key, required this.db});
  final GameDb db;

  static const lowFeed = 20;
  static final _produce = RegExp(r'Milk|Wool|Egg|Honey|Feather|Fleece|Down');

  bool _isFeeder(String name) =>
      name.contains('Feeder') ||
      name.contains('Bowl') ||
      name.contains('Trough');

  @override
  Widget build(BuildContext context) {
    final s = LiveScope.of(context).state;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('Farm'))),
        body: Center(child: Text(tr('No live data from the PC agent yet.'))),
      );
    }
    // English for the checks below (feeder, seeds), [shown] for the screen
    String name(String id) => db.items[id]?.name ?? id;
    String shown(String id) => gt(name(id));
    void open(String id) {
      final it = db.items[id];
      if (it != null)
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ItemScreen(db: db, item: it)),
        );
    }

    final labels = s.labels(name);
    final feeders = [
      for (final c in s.containers)
        if (c.kind != null && _isFeeder(name(c.kind!))) c,
    ];
    final emptyFeeders =
        s.placed.entries
            .where((e) => _isFeeder(name(e.key)))
            .fold(0, (a, e) => a + e.value) -
        feeders.length;
    // animals hold their produce (milk, wool, eggs) until collected
    final produce = <String, (int animals, int total)>{};
    for (final c in s.containers.where((c) => c.kind == null)) {
      for (final o in c.items) {
        final it = db.items[o.itemId];
        if (it == null || !_produce.hasMatch(it.name)) continue;
        final (a, t) = produce[o.itemId] ?? (0, 0);
        produce[o.itemId] = (a + 1, t + o.count);
      }
    }
    final seeds =
        s.totals.entries
            .where(
              (e) =>
                  e.value > 0 &&
                  (name(e.key).contains('Seedling') ||
                      name(e.key).contains('Seeds')),
            )
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));

    return Scaffold(
      appBar: AppBar(title: Text(tr('Farm'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SectionTitle(tr('Feeders · {n}', {'n': feeders.length})),
          if (emptyFeeders > 0)
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.warning_amber_rounded,
                color: Palette.ember,
              ),
              title: Text(
                trn(
                  emptyFeeders,
                  '{n} feeder looks empty',
                  '{n} feeders look empty',
                ),
              ),
            ),
          for (final c in feeders)
            for (final o in c.items.isEmpty ? <Owned?>[null] : c.items)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.pets,
                  color:
                      (o?.count ?? 0) < lowFeed
                          ? Palette.ember
                          : Palette.spring,
                ),
                title: Text(shownLabel(labels[c.index])),
                subtitle: Text(
                  o == null
                      ? tr('Empty')
                      : o.count < lowFeed
                      ? tr('{item} ×{n} · running low', {
                        'item': shown(o.itemId),
                        'n': o.count,
                      })
                      : '${shown(o.itemId)} ×${o.count}',
                  style: TextStyle(
                    color:
                        (o?.count ?? 0) < lowFeed ? Palette.ember : Palette.ash,
                  ),
                ),
                onTap: o == null ? null : () => open(o.itemId),
              ),
          SectionTitle(tr('Produce to collect · {n}', {'n': produce.length})),
          if (produce.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(tr('Nothing waiting in your animals.')),
            ),
          for (final e in produce.entries)
            ListTile(
              dense: true,
              leading: const Icon(Icons.egg_alt_outlined, color: Palette.flame),
              title: Text(shown(e.key)),
              subtitle: Text(
                trn(e.value.$1, 'in {n} animal', 'in {n} animals'),
                style: const TextStyle(color: Palette.ash),
              ),
              trailing: Text(
                '×${e.value.$2}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: () => open(e.key),
            ),
          SectionTitle(tr('Seeds you own · {n}', {'n': seeds.length})),
          for (final e in seeds)
            ListTile(
              dense: true,
              leading: const Icon(Icons.grass, color: Palette.spring),
              title: Text(shown(e.key)),
              trailing: Text(
                '×${e.value}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: () => open(e.key),
            ),
        ],
      ),
    );
  }
}
