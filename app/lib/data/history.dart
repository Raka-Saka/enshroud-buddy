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
  String up(String what, int from, int to) => '$what $to (+${to - from})';
  final out = <String>[
    if (b.level > a.level) up('Level', a.level, b.level),
    if (b.flame > a.flame) up('Flame strength', a.flame, b.flame),
    if (b.roots > a.roots)
      '+${b.roots - a.roots} Shroud Root${b.roots - a.roots > 1 ? 's' : ''} claimed',
    if (b.wells > a.wells)
      '+${b.wells - a.wells} Elixir Well${b.wells - a.wells > 1 ? 's' : ''} cleared',
    if (b.ranks > a.ranks) _n(b.ranks - a.ranks, 'skill rank'),
    if (b.recipes > a.recipes) _n(b.recipes - a.recipes, 'recipe'),
    for (final e in b.bases.entries)
      if (!a.bases.containsKey(e.key))
        'New base: ${_baseLabel(e.key)}'
      else if (e.value > a.bases[e.key]!)
        '${_baseLabel(e.key)}: altar ${e.value} (${balancing?.zoneAt(e.value) ?? '?'} zone)',
    for (final id in b.worn)
      if (!a.worn.contains(id)) 'Wearing ${name(id)}',
  ];
  if (out.isEmpty && b.knowledge > a.knowledge) {
    out.add(
      b.knowledge - a.knowledge == 1
          ? '+1 discovery'
          : '+${b.knowledge - a.knowledge} discoveries',
    );
  }
  return out;
}

String _n(int n, String what) => '+$n $what${n == 1 ? '' : 's'}';

String _baseLabel(String key) =>
    key.startsWith('base') ? 'Unnamed base (${key.substring(4)})' : key;
