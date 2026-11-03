import 'game_db.dart';
import 'live_state.dart';

/// What the character can take into the Shroud, the cold and the water, from the save:
/// Flame level, world settings, worn gear and owned food.
class Survival {
  Survival(this.db, this.state);
  final GameDb db;
  final LiveState state;

  static const shroudLabels = ['Time in the Shroud', 'Time In The Shroud'];

  /// "4 min", "1 min 30 s", "30 s", "-4 min": one way of writing times everywhere.
  static String format(num s) {
    final neg = s < 0;
    s = s.abs();
    final m = s ~/ 60, r = (s % 60).round();
    final t = m == 0 ? '$r s' : (r == 0 ? '$m min' : '$m min $r s');
    return neg ? '-$t' : t;
  }

  /// "1 min", "30 s", "20" (plain seconds, as oxygen food lists it) -> seconds.
  static int seconds(String v) {
    final m = RegExp(r'^(-?\d+(?:\.\d+)?)\s*(min|s)?$').firstMatch(v.trim());
    if (m == null) return 0;
    final n = double.parse(m.group(1)!);
    return (m.group(2) == 'min' ? n * 60 : n).round();
  }

  int _gearSeconds(List<String> labels) => state.equipment.fold(0, (a, o) {
    final vs = db.items[o.itemId]?.stats?.values ?? const <(String, String)>[];
    return a +
        vs
            .where((v) => labels.contains(v.$1))
            .fold(0, (b, v) => b + seconds(v.$2));
  });

  /// Time in the Shroud: base plus the Flame level, times the world setting, plus worn gear.
  int get shroudSeconds {
    final b = db.balancing;
    if (b == null) return 0;
    return ((b.fogBase + b.fogPerFlame * state.flameLevel) *
                (state.settings['shroud_time'] ?? 1.0))
            .round() +
        _gearSeconds(shroudLabels);
  }

  /// Breath underwater: base times the world setting, plus worn gear.
  int get oxygenSeconds {
    final b = db.balancing;
    if (b == null) return 0;
    return (b.oxygen * (state.settings['diving_time'] ?? 1.0)).round() +
        _gearSeconds(const ['Maximum Oxygen']);
  }

  /// Frost Resistance from worn gear.
  int get frostResistance => state.equipment.fold(
    0,
    (a, o) => a + (db.items[o.itemId]?.stats?.value('Frost Resistance') ?? 0),
  );

  bool get coldProtected =>
      state.flameLevel >= (db.balancing?.noFreezeFlameLevel ?? 99);

  /// The owned consumables with the most of a stat, best first: (item, value text, count owned).
  List<(Item, String, int)> bestFood(List<String> labels, {int count = 3}) {
    final out = <(Item, String, int, double)>[];
    for (final e in state.totals.entries) {
      final it = db.items[e.key];
      if (it == null || e.value <= 0 || it.stats?.slot != 'Consumable')
        continue;
      for (final (l, v) in it.stats!.values) {
        if (!labels.contains(l)) continue;
        final n =
            labels.first.startsWith('Time') || l == 'Maximum Oxygen'
                ? seconds(v).toDouble()
                : double.tryParse(
                      RegExp(r'\d+(\.\d+)?').stringMatch(v) ?? '',
                    ) ??
                    0;
        if (n > 0) out.add((it, v, e.value, n));
      }
    }
    out.sort((a, b) => b.$4.compareTo(a.$4));
    return [for (final o in out.take(count)) (o.$1, o.$2, o.$3)];
  }
}
