import '../l10n.dart';
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
/// writes them, longest match first: "Copper Ore" before "Copper". In another language the names in it
/// ([gt]) are found too, in any case; for scripts written without spaces (Japanese, Chinese, Thai) by
/// substring. What is found is the English thing (its id, its English name).
class Mentions {
  Mentions._(GameDb db) : _lang = L10n.lang.code {
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
    // the same things by their names in the chosen language; an English name keeps its target
    if (_lang != 'En_Us') {
      final english = _index.entries.toList();
      for (final e in english) {
        final t = e.value;
        final shown = gt(switch (t.kind) {
          MentionKind.item => t.item!.name,
          MentionKind.skill => t.skill!.name,
          MentionKind.place => t.place!.title,
        });
        if (_spaceless) {
          if (shown.runes.length > 1) _plain.putIfAbsent(shown, () => t);
          continue;
        }
        final k = _key(shown);
        if (k.isEmpty || _index.containsKey(k)) continue;
        _index[k] = t;
        _anyCase.add(k);
      }
      _plainNames =
          _plain.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    }
    for (final k in _index.keys) {
      final n = ' '.allMatches(k).length + 1;
      if (n > _longest) _longest = n;
    }
  }

  static final _cache = Expando<Mentions>();

  /// Built once per game data and language.
  static Mentions of(GameDb db) {
    final m = _cache[db];
    if (m != null && m._lang == L10n.lang.code) return m;
    return _cache[db] = Mentions._(db);
  }

  final String _lang;
  final _index = <String, _Target>{};
  var _longest = 1;

  /// Keys from translated names, which match without a leading capital (most languages don't capitalise
  /// item names).
  final _anyCase = <String>{};

  /// Scripts without spaces between words: translated names found as they are written.
  bool get _spaceless =>
      {'ja', 'zh', 'th'}.contains(L10n.lang.tag.split('-')[0]);
  final _plain = <String, _Target>{};
  var _plainNames = const <String>[];

  static final _ascii = RegExp(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)?");
  static final _letters = RegExp(
    r"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}]+)?",
    unicode: true,
  );
  RegExp get _word => _lang == 'En_Us' ? _ascii : _letters;
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

  String _key(String name) => _word
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
      final capital = _capital(first);
      if (!capital && _anyCase.isEmpty) {
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
        if (t != null && (capital || _anyCase.contains(_matched(key)))) {
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
    if (_plainNames.isNotEmpty) _findPlain(text, out);
    return out;
  }

  /// The index key a looked-up key matched: itself, or without a plural "s" / "es".
  String _matched(String key) {
    if (_index.containsKey(key)) return key;
    final s = key.substring(0, key.length - 1);
    if (key.endsWith('s') && _index.containsKey(s)) return s;
    return key.substring(0, key.length - 2);
  }

  /// Translated names in text without spaces, longest first, outside what was already found.
  void _findPlain(String text, List<Mention> out) {
    bool free(int a, int b) => out.every((m) => b <= m.start || a >= m.end);
    for (final name in _plainNames) {
      for (
        var at = text.indexOf(name);
        at >= 0;
        at = text.indexOf(name, at + 1)
      ) {
        final end = at + name.length;
        if (!free(at, end)) continue;
        final t = _plain[name]!;
        out.add(
          Mention(
            t.kind,
            switch (t.kind) {
              MentionKind.item => t.item!.name,
              MentionKind.skill => t.skill!.name,
              MentionKind.place => t.place!.title,
            },
            at,
            end,
            item: t.item,
            skill: t.skill,
            place: t.place,
          ),
        );
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
  }

  /// English: a capital letter or a digit, as the game writes names. Elsewhere also a letter without case.
  bool _capital(String word) {
    final c = word.codeUnitAt(0);
    if ((c >= 65 && c <= 90) || (c >= 48 && c <= 57)) return true;
    if (_lang == 'En_Us') return false;
    final ch = String.fromCharCode(word.runes.first);
    return ch.toUpperCase() == ch;
  }
}
