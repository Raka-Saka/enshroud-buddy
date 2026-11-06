import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../data/survival.dart';
import '../l10n.dart';
import '../theme.dart';
import '../nav.dart';
import 'item_screen.dart';
import 'map_screen.dart' show mapShow;
import 'widgets.dart';

// one parser and one format with Home and the tasks (data/survival.dart)
int statSeconds(String v) => Survival.seconds(v);
String fmtSeconds(num s) => Survival.format(s);

/// Shroud, cold and water: what the Flame level, world settings, gear and food give you.
class SurvivalScreen extends StatelessWidget {
  const SurvivalScreen({super.key, required this.db});
  final GameDb db;

  static const shroudLabels = Survival.shroudLabels;

  @override
  Widget build(BuildContext context) {
    final s = LiveScope.of(context).state;
    final b = db.balancing;
    if (s == null || b == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('Survival'))),
        body: Center(child: Text(tr('No live data from the PC agent yet.'))),
      );
    }
    void open(Item it) => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ItemScreen(db: db, item: it)),
    );
    final flame = s.flameLevel;
    final shroudFactor = s.settings['shroud_time'] ?? 1.0;

    // --- Shroud time
    final base = (b.fogBase + b.fogPerFlame * flame) * shroudFactor;
    final gear = <(Item, int)>[];
    for (final o in s.equipment) {
      final it = db.items[o.itemId];
      final secs =
          it?.stats?.values
              .where((v) => shroudLabels.contains(v.$1))
              .fold(0, (a, v) => a + statSeconds(v.$2)) ??
          0;
      if (it != null && secs != 0) gear.add((it, secs));
    }
    final gearTotal = gear.fold(0, (a, g) => a + g.$2);

    // owned consumables that change Shroud time (flasks, food, scrolls) or restore it
    final owned = s.totals;
    final boosts = <(Item, int, int)>[]; // item, seconds, count owned
    final restores = <(Item, int)>[];
    for (final e in owned.entries) {
      final it = db.items[e.key];
      if (it == null || e.value <= 0 || it.stats?.slot != 'Consumable')
        continue;
      final secs = it.stats!.values
          .where((v) => shroudLabels.contains(v.$1))
          .fold(0, (a, v) => a + statSeconds(v.$2));
      if (secs > 0) boosts.add((it, secs, e.value));
      if ((it.description ?? '').contains('restores') &&
          (it.description ?? '').contains('Shroud'))
        restores.add((it, e.value));
    }
    boosts.sort((a, c) => c.$2.compareTo(a.$2));
    final bestBoost = boosts.isEmpty ? 0 : boosts.first.$2;
    final shroudSkills =
        db.skills
            .where(
              (k) =>
                  k.name.contains('Shroud') ||
                  k.name == 'Endurance of the Flame',
            )
            .toList();
    final beacons = db.poi.where((p) => p.kind == 'Return Beacon').length;
    final capsules = db.poi.where((p) => p.cat == 'shroud').length;

    // --- Cold
    int sumStat(Iterable<Owned> list, String label) => list.fold(0, (a, o) {
      final it = db.items[o.itemId];
      return a + (it?.stats?.value(label) ?? 0);
    });
    final frostGear = sumStat(s.equipment, 'Frost Resistance');
    List<(Item, int)> bestOwned(String label) {
      final out = <(Item, int)>[];
      for (final e in owned.entries) {
        final it = db.items[e.key];
        final v = it?.stats?.slot == 'Consumable' ? it!.stats!.value(label) : 0;
        if (v > 0) out.add((it!, v));
      }
      out.sort((a, c) => c.$2.compareTo(a.$2));
      return out.take(4).toList();
    }

    // --- Water
    final oxygenBase = b.oxygen * (s.settings['diving_time'] ?? 1.0);
    final oxygenGear = s.equipment.fold(0, (a, o) {
      final v = db.items[o.itemId]?.stats?.values.where(
        (v) => v.$1 == 'Maximum Oxygen',
      );
      return a + (v == null || v.isEmpty ? 0 : statSeconds(v.first.$2));
    });
    final airBubbles = db.poi.where((p) => p.cat == 'water').length;

    // to the map with that layer on
    void showOnMap(String layer) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      mapShow.value = layer;
      goTo(Tabs.map);
    }

    Widget row(String label, String value, {Color? color, bool bold = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: const TextStyle(color: Palette.ash)),
              ),
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(tr('Survival'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(
                    Icons.local_fire_department,
                    color: Palette.flame,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('Flame strength {flame} of {max}', {
                            'flame': flame,
                            'max': b.flameMax,
                          }),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          tr(
                            'Your Shroud Passage Level · up to {n} Flame Altars',
                            {'n': b.altarsAt(flame)},
                          ),
                          style: const TextStyle(color: Palette.ash),
                        ),
                        Text(
                          tr('Read from your save; check it matches the game.'),
                          style: const TextStyle(
                            color: Palette.ash,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SectionTitle(tr('Time in the Shroud')),
          row(
            tr('Base {base} + {per} × Flame {flame}', {
              'base': fmtSeconds(b.fogBase),
              'per': fmtSeconds(b.fogPerFlame),
              'flame': flame,
            }),
            fmtSeconds(b.fogBase + b.fogPerFlame * flame),
          ),
          if (shroudFactor != 1)
            row(
              tr('World setting ×{factor}', {'factor': shroudFactor}),
              fmtSeconds(base),
            ),
          for (final (it, secs) in gear)
            row(
              tr('{item} (worn)', {'item': gt(it.name)}),
              '+${fmtSeconds(secs)}',
            ),
          row(
            tr('You can stay'),
            fmtSeconds(base + gearTotal),
            color: Palette.flame,
            bold: true,
          ),
          if (bestBoost > 0)
            row(
              tr('With your best flask or food ({item})', {
                'item': gt(boosts.first.$1.name),
              }),
              fmtSeconds(base + gearTotal + bestBoost),
              color: Palette.spring,
              bold: true,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              tr(
                'Zones above your Shroud Passage Level are shown in red on the map (Shroud layer).',
              ),
              style: const TextStyle(color: Palette.ash, fontSize: 12),
            ),
          ),
          SectionTitle(tr('Refill inside the Shroud')),
          ListTile(
            dense: true,
            leading: const Icon(Icons.cell_tower, color: Palette.spring),
            title: Text(tr('Return Beacons · {n} on the map', {'n': beacons})),
            subtitle: Text(
              tr('Stand near one to refill your Time in the Shroud.'),
              style: const TextStyle(color: Palette.ash),
            ),
            trailing: const Icon(Icons.map_outlined, size: 20),
            onTap: () => showOnMap('shroud'),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.hourglass_bottom, color: Palette.flame),
            title: Text(
              tr('Hourglass capsules · {n} on the map', {'n': capsules}),
            ),
            subtitle: Text(
              tr('+5 min each, used on pickup.'),
              style: const TextStyle(color: Palette.ash),
            ),
            trailing: const Icon(Icons.map_outlined, size: 20),
            onTap: () => showOnMap('shroud'),
          ),
          for (final (it, n) in restores)
            ListTile(
              dense: true,
              leading: const Icon(Icons.healing, color: Palette.spring),
              title: Text('${gt(it.name)} ×$n'),
              subtitle: Text(
                gtn(it.description) ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Palette.ash, fontSize: 12),
              ),
              onTap: () => open(it),
            ),
          for (final k in shroudSkills)
            ListTile(
              dense: true,
              leading: Icon(
                s.skills.containsKey(k.id)
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                color:
                    s.skills.containsKey(k.id) ? Palette.spring : Palette.ash,
                size: 20,
              ),
              title: Text(
                s.skills.containsKey(k.id)
                    ? tr('{skill} · learned', {'skill': gt(k.name)})
                    : gt(k.name),
              ),
              subtitle: Text(
                (gtn(k.description) ?? '')
                    .replaceAll('%k', '…')
                    .replaceAll(RegExp(r'<[^>]+>'), ''),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Palette.ash, fontSize: 12),
              ),
            ),
          if (boosts.isNotEmpty) ...[
            SectionTitle(tr('Extend before going in')),
            for (final (it, secs, n) in boosts.take(6))
              ListTile(
                dense: true,
                leading: const Icon(
                  Icons.science_outlined,
                  color: Palette.veil,
                ),
                title: Text('${gt(it.name)} ×$n'),
                trailing: Text(
                  '+${fmtSeconds(secs)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => open(it),
              ),
          ],
          SectionTitle(tr('Cold')),
          row(
            tr('Freezing stops at Flame strength'),
            '${b.noFreezeFlameLevel}',
            color:
                flame >= b.noFreezeFlameLevel ? Palette.spring : Palette.ember,
          ),
          row(tr('Frost Resistance from your gear'), '$frostGear'),
          for (final (it, v) in bestOwned('Frost Resistance'))
            ListTile(
              dense: true,
              leading: const Icon(Icons.ac_unit, color: Palette.spring),
              title: Text(gt(it.name)),
              trailing: Text('+$v'),
              onTap: () => open(it),
            ),
          SectionTitle(tr('Water')),
          row(
            (s.settings['diving_time'] ?? 1) != 1
                ? tr('Oxygen {time} × {factor}', {
                  'time': fmtSeconds(b.oxygen),
                  'factor': s.settings['diving_time'],
                })
                : tr('Oxygen {time}', {'time': fmtSeconds(b.oxygen)}),
            fmtSeconds(oxygenBase),
          ),
          if (oxygenGear > 0)
            row(tr('From your gear'), '+${fmtSeconds(oxygenGear)}'),
          ListTile(
            dense: true,
            title: Text(
              tr('Air bubbles on the map'),
              style: const TextStyle(color: Palette.ash),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$airBubbles',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.map_outlined, size: 20),
              ],
            ),
            onTap: () => showOnMap('water'),
          ),
          for (final (it, v) in bestOwned('Maximum Oxygen'))
            ListTile(
              dense: true,
              leading: const Icon(Icons.water, color: Palette.spring),
              title: Text(gt(it.name)),
              trailing: Text('+$v'),
              onTap: () => open(it),
            ),
        ],
      ),
    );
  }
}
