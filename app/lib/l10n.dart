import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The languages the game ships (its LocaTagCollectionResource), by the game's own code.
class Lang {
  final String code, tag, name;
  const Lang(this.code, this.tag, this.name);

  ui.Locale get locale {
    final p = tag.split('-');
    return p.length == 1 ? ui.Locale(p[0]) : ui.Locale(p[0], p[1]);
  }
}

const languages = [
  Lang('En_Us', 'en', 'English'),
  Lang('De_De', 'de', 'Deutsch'),
  Lang('Fr_Fr', 'fr', 'Français'),
  Lang('Es_Es', 'es', 'Español'),
  Lang('It_It', 'it', 'Italiano'),
  Lang('Pt_Br', 'pt-BR', 'Português (Brasil)'),
  Lang('Pl_Pl', 'pl', 'Polski'),
  Lang('Ru_Ru', 'ru', 'Русский'),
  Lang('Uk_Ua', 'uk', 'Українська'),
  Lang('Tr_Tr', 'tr', 'Türkçe'),
  Lang('Ja_Jp', 'ja', '日本語'),
  Lang('Ko_Kr', 'ko', '한국어'),
  Lang('Zh_Cn', 'zh-CN', '简体中文'),
  Lang('Zh_Tw', 'zh-TW', '繁體中文'),
  Lang('Th_Th', 'th', 'ไทย'),
];

/// The app's language: its own texts (assets/i18n/ui/<code>.json, English text → translation) and the
/// game's (assets/i18n/game/<code>.json, from tools/build_db.py: Keen's own translations of names, lore and
/// quests). English is the source, so anything not translated yet shows in English.
class L10n {
  static Lang lang = languages.first;
  static Map<String, Object?> _ui = const {};
  static Map<String, String> _game = const {};

  static const _pref = 'language';

  /// The language picked in Setup, or null to follow the phone.
  static Future<String?> chosen() async =>
      (await SharedPreferences.getInstance()).getString(_pref);

  /// Bumped when Setup picks another language; the app reloads its texts and rebuilds.
  static final changed = ValueNotifier(0);

  static Future<void> choose(String? code) async {
    final p = await SharedPreferences.getInstance();
    code == null ? await p.remove(_pref) : await p.setString(_pref, code);
    changed.value++;
  }

  /// The phone's language when the game has it, else English.
  static Lang ofDevice() {
    final all = ui.PlatformDispatcher.instance.locales;
    for (final l in all) {
      final region = l.countryCode?.toUpperCase();
      final script = l.scriptCode;
      for (final g in languages) {
        final p = g.tag.split('-');
        if (p[0] != l.languageCode) continue;
        if (p.length == 1) return g;
        // Chinese: Traditional for Taiwan, Hong Kong, Macau or the Hant script, else Simplified
        if (p[0] == 'zh') {
          final hant =
              script == 'Hant' || {'TW', 'HK', 'MO'}.contains(region);
          return languages.firstWhere(
            (x) => x.code == (hant ? 'Zh_Tw' : 'Zh_Cn'),
          );
        }
        if (p[1] == region || l.languageCode == 'pt') return g;
      }
    }
    return languages.first;
  }

  static Future<void> load() async {
    final code = await chosen();
    lang = languages.firstWhere((l) => l.code == code, orElse: ofDevice);
    if (lang.code == 'En_Us') {
      _ui = const {};
      _game = const {};
      return;
    }
    Future<Map<String, dynamic>> read(String path) async {
      try {
        return jsonDecode(await rootBundle.loadString(path))
            as Map<String, dynamic>;
      } catch (_) {
        return const {};
      }
    }

    _ui = await read('assets/i18n/ui/${lang.code}.json');
    _game = (await read(
      'assets/i18n/game/${lang.code}.json',
    )).map((k, v) => MapEntry(k, v as String));
  }

  /// For tests: set the tables directly.
  static void use(
    Lang l, {
    Map<String, Object?> ui = const {},
    Map<String, String> game = const {},
  }) {
    lang = l;
    _ui = ui;
    _game = game;
  }

  /// The plural category of [n] (CLDR's rules for the cardinal numbers these languages use).
  static String plural(int n) {
    final t = lang.tag.split('-')[0];
    final m10 = n % 10, m100 = n % 100;
    switch (t) {
      case 'ja' || 'ko' || 'zh' || 'th':
        return 'other';
      case 'fr' || 'pt':
        return n == 0 || n == 1 ? 'one' : 'other';
      case 'ru' || 'uk':
        if (m10 == 1 && m100 != 11) return 'one';
        if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'few';
        return 'many';
      case 'pl':
        if (n == 1) return 'one';
        if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'few';
        return 'many';
      default:
        return n == 1 ? 'one' : 'other';
    }
  }
}

String _fill(String s, Map<String, Object?>? args) {
  if (args == null || args.isEmpty) return s;
  return s.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
    final k = m.group(1)!;
    return args.containsKey(k) ? '${args[k]}' : m.group(0)!;
  });
}

/// The app's own text in the chosen language. [en] is the English text and the lookup key; `{name}` marks
/// where [args] go, so word order can change in translation.
String tr(String en, [Map<String, Object?>? args]) {
  final t = L10n._ui[en];
  return _fill(t is String && t.isNotEmpty ? t : en, args);
}

/// Text that changes with a count: [one] and [other] in English, `{n}` is the count. Translations keep
/// a form per plural category ("one", "few", "many", "other") under the key [other].
String trn(int n, String one, String other, [Map<String, Object?>? args]) {
  final a = {'n': n, ...?args};
  final t = L10n._ui[other];
  if (t is Map) {
    final f = t[L10n.plural(n)] ?? t['other'];
    if (f is String && f.isNotEmpty) return _fill(f, a);
  } else if (t is String && t.isNotEmpty) {
    return _fill(t, a);
  }
  return _fill(n == 1 ? one : other, a);
}

/// Game text (names, descriptions, lore, quests) in the chosen language, from Keen's own translations.
String gt(String s) => L10n._game[s] ?? s;

/// [gt] for text that may be missing.
String? gtn(String? s) => s == null ? null : L10n._game[s] ?? s;
