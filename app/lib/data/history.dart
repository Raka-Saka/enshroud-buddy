import '../l10n.dart';
import 'game_db.dart';

/// One progress snapshot from the PC agent (tools/history.py), taken at a game save.
class Snapshot {
  Snapshot(Map<String, dynamic> j)
    : t = DateTime.tryParse(j['t'] ?? '') ?? DateTime(2000),
      level = j['level'] ?? 0,
      xp = j['xp'] ?? 0,
      flame = j['flame'] ?? 0,
      skills = j['skills'] ?? 0,
      ranks = j['ranks'] ?? 0,
      recipes = j['recipes'] ?? 0,
      knowledge = j['knowledge'] ?? 0,
      roots = j['roots'] ?? 0,
      wells = j['wells'] ?? 0,
      bases = {
        for (final b in j['bases'] ?? const [])
          b[0] as String: (b[1] as num).toInt(),
      },
      worn = List<String>.from(j['worn'] ?? const []);

  final DateTime t;
  final int level, xp, flame, skills, ranks, recipes, knowledge, roots, wells;

  /// Base name (or id) to altar level, and the worn item ids.
  final Map<String, int> bases;
  final List<String> worn;
}

/// What changed between two snapshots, as short lines: "Level 33 (+5)", "+237 recipes", "New base: Copper Camp".
List<String> changes(
  Snapshot a,
  Snapshot b,
  String Function(String) name, [
  Balancing? balancing,
]) {
  final out = <String>[
    if (b.level > a.level)
      tr('Level {n} (+{up})', {'n': b.level, 'up': b.level - a.level}),
    if (b.flame > a.flame)
      tr('Flame strength {n} (+{up})', {'n': b.flame, 'up': b.flame - a.flame}),
    if (b.roots > a.roots)
      trn(
        b.roots - a.roots,
        '+{n} Shroud Root claimed',
        '+{n} Shroud Roots claimed',
      ),
    if (b.wells > a.wells)
      trn(
        b.wells - a.wells,
        '+{n} Elixir Well cleared',
        '+{n} Elixir Wells cleared',
      ),
    if (b.ranks > a.ranks)
      trn(b.ranks - a.ranks, '+{n} skill rank', '+{n} skill ranks'),
    if (b.recipes > a.recipes)
      trn(b.recipes - a.recipes, '+{n} recipe', '+{n} recipes'),
    for (final e in b.bases.entries)
      if (!a.bases.containsKey(e.key))
        tr('New base: {base}', {'base': _baseLabel(e.key)})
      else if (e.value > a.bases[e.key]!)
        tr('{base}: altar {n} ({zone} zone)', {
          'base': _baseLabel(e.key),
          'n': e.value,
          'zone': balancing?.zoneAt(e.value) ?? '?',
        }),
    for (final id in b.worn)
      if (!a.worn.contains(id)) tr('Wearing {item}', {'item': gt(name(id))}),
  ];
  if (out.isEmpty && b.knowledge > a.knowledge) {
    out.add(
      trn(b.knowledge - a.knowledge, '+{n} discovery', '+{n} discoveries'),
    );
  }
  return out;
}

String _baseLabel(String key) =>
    key.startsWith('base')
        ? tr('Unnamed base ({n})', {'n': key.substring(4)})
        : key;
