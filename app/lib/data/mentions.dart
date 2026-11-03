import 'game_db.dart';

enum MentionKind { item, skill, place }

/// A game name found in a piece of text: an item, a skill or a named map place.
class Mention {
  Mention(
    this.kind,
    this.name,
    this.start,
    this.end, {
    this.item,
    this.skill,
    this.place,
  });
  final MentionKind kind;
  final String name;

  /// Where it is in the text (end exclusive).
  final int start, end;
  final Item? item;
  final Skill? skill;
  final Poi? place;

  /// One per thing named, for chips.
  String get key => switch (kind) {
    MentionKind.item => 'i:${item!.id}',
    MentionKind.skill => 's:${skill!.name}',
    MentionKind.place => 'p:${place!.title}',
  };
}

class _Target {
  _Target.item(this.item) : skill = null, place = null, kind = MentionKind.item;
  _Target.skill(this.skill)
    : item = null,
      place = null,
      kind = MentionKind.skill;
  _Target.place(this.place)
    : item = null,
      skill = null,
      kind = MentionKind.place;
  final MentionKind kind;
  final Item? item;
  final Skill? skill;
  final Poi? place;
}

/// Finds the game's names in answers, so they can be opened, planned or shown on the map.
///
/// Exact names only (case-insensitive, a plural "s" allowed), starting with a capital as the game
/// writes them, longest match first: "Copper Ore" before "Copper".
class Mentions {
  Mentions._(GameDb db) {
    // items: the one per name with the most to show (recipes, gather spots, loot), skipping building
    // blocks and decorations that nothing makes
    int score(Item i) =>
        (db.madeBy[i.id]?.isNotEmpty ?? false ? 4 : 0) +
        (db.gather.containsKey(i.id) ? 2 : 0) +
        (i.chestKinds.isNotEmpty || i.fixedPlacements > 0 ? 1 : 0) +
        (db.usedIn[i.id]?.isNotEmpty ?? false ? 1 : 0);
    final best = <String, Item>{};
    for (final i in db.sortedItems) {
      final s = score(i);
      if (s == 0 ||
          (i.category == 'BuildTools' &&
              !(db.madeBy[i.id]?.isNotEmpty ?? false))) {
        continue;
      }
      final k = _key(i.name);
      if (k.isEmpty || _stop.contains(k)) continue;
      final b = best[k];
      if (b == null || score(b) < s) best[k] = i;
    }
    for (final e in best.entries) {
      _index[e.key] = _Target.item(e.value);
    }
    // skills win over items of the same name ("Blink", "Spark"): answers name them as skills
    for (final k in db.skills) {
      if (k.type == 'Root') continue;
      final key = _key(k.name);
      if (key.isNotEmpty) _index[key] = _Target.skill(k);
    }
    // places with a name of their own (not "Shroud Root", which there are 58 of)
    final count = <String, int>{};
    for (final p in db.poi) {
      if (p.cat == 'label') count[p.title] = (count[p.title] ?? 0) + 1;
    }
    for (final p in db.poi) {
      if (p.cat != 'label' || count[p.title] != 1 || p.title == p.kind)
        continue;
      _index.putIfAbsent(_key(p.title), () => _Target.place(p));
    }
    for (final k in _index.keys) {
      final n = ' '.allMatches(k).length + 1;
      if (n > _longest) _longest = n;
    }
  }

  static final _cache = Expando<Mentions>();
  static Mentions of(GameDb db) => _cache[db] ??= Mentions._(db);

  final _index = <String, _Target>{};
  var _longest = 1;

  static final _word = RegExp(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)?");
  static final _gap = RegExp(r'^[ \t\-:]{1,3}$');

  /// Words too common in plain sentences to link on their own.
  static const _stop = {
    'wall',
    'date',
    'nova',
    'goo',
    'light',
    'mirage',
    'nightfall',
    'forsaken',
    'globe',
    'camera',
  };

  static String _key(String name) => _word
      .allMatches(name.replaceAll('’', "'"))
      .map((m) => m.group(0)!.toLowerCase())
      .join(' ');

  /// The names in [text], in order, not overlapping.
  List<Mention> find(String text) {
    final words = _word.allMatches(text).toList();
    final out = <Mention>[];
    var i = 0;
    while (i < words.length) {
      final first = words[i].group(0)!;
      if (!_capital(first.codeUnitAt(0))) {
        i++;
        continue;
      }
      var hit = 0;
      _Target? target;
      final parts = <String>[];
      for (var n = 1; n <= _longest && i + n <= words.length; n++) {
        if (n > 1 &&
            !_gap.hasMatch(
              text.substring(words[i + n - 2].end, words[i + n - 1].start),
            )) {
          break;
        }
        parts.add(
          words[i + n - 1].group(0)!.toLowerCase().replaceAll('’', "'"),
        );
        final key = parts.join(' ');
        final t =
            _index[key] ??
            (key.endsWith('s')
                ? _index[key.substring(0, key.length - 1)]
                : null) ??
            (key.endsWith('es')
                ? _index[key.substring(0, key.length - 2)]
                : null);
        if (t != null) {
          hit = n;
          target = t;
        }
      }
      final start = words[i].start,
          end = target == null ? 0 : words[i + hit - 1].end;
      // part of a hyphenated word ("Salt-cured") is not the name
      if (target == null ||
          (start > 0 && text[start - 1] == '-') ||
          (end < text.length && text[end] == '-')) {
        i++;
        continue;
      }
      out.add(
        Mention(
          target.kind,
          switch (target.kind) {
            MentionKind.item => target.item!.name,
            MentionKind.skill => target.skill!.name,
            MentionKind.place => target.place!.title,
          },
          start,
          end,
          item: target.item,
          skill: target.skill,
          place: target.place,
        ),
      );
      i += hit;
    }
    return out;
  }

  static bool _capital(int c) => (c >= 65 && c <= 90) || (c >= 48 && c <= 57);
}
