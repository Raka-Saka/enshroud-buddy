import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'game_db.dart';

/// Item pictures from the Enshrouded wiki (assets/icons, written by tools/icons.py), 64 px: about 9 in
/// 10 items. The game draws most icons from 3D models at runtime, so its files don't have them.
class ItemIcons {
  static Map<String, String> _files = const {};

  static Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('assets/icons/index.json');
      _files = (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {}
  }

  /// The asset path for an item's picture, or null.
  static String? asset(String itemId) {
    final f = _files[itemId];
    return f == null ? null : 'assets/icons/$f';
  }
}

/// Map markers as the game draws them, from the wiki's map (assets/map_icons, tools/icons.py build_map):
/// a place gets the marker named by its kind (from the game's templates, so an enemy "Caravan Camp" stays
/// an Enemy Camp), else the one whose name is a whole phrase of its title ("Balefire Garrison" → Balefire,
/// "Hidden Hollow Tomb" → Tomb); lore notes get the lore marker. Longest name wins. Places without one
/// (Return Beacon, most bosses, chests) keep a glyph.
class MapIcons {
  static Map<String, String> _files = const {};
  static List<String> _names = const [];
  static final _memo = Expando<String>();

  static String _words(String s) =>
      ' ${s.toLowerCase().replaceAll(RegExp(r"[^a-z0-9']+"), ' ').trim()} ';

  static Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('assets/map_icons/index.json');
      _files = {
        for (final e in (jsonDecode(raw) as Map).entries)
          _words(e.key as String): e.value as String,
      };
      _names = _files.keys.toList()..sort((a, b) => b.length - a.length);
    } catch (_) {}
  }

  /// The asset path for a map point's marker, or null.
  static String? asset(Poi p) {
    final hit = _memo[p];
    if (hit != null) return hit.isEmpty ? null : hit;
    String? found;
    for (final s in p.cat == 'label' ? [p.kind, p.title] : [p.cat]) {
      if (s == null) continue;
      final w = _words(s);
      final n = _names.where(w.contains).firstOrNull;
      if (n != null) {
        found = 'assets/map_icons/${_files[n]}';
        break;
      }
    }
    _memo[p] = found ?? '';
    return found;
  }
}

/// An item's picture on a rarity-tinted tile, or [fallback] when it has none.
class ItemIcon extends StatelessWidget {
  const ItemIcon(
    this.item, {
    super.key,
    this.size = 36,
    this.fallback = Icons.diamond_outlined,
    this.ring,
  });
  final Item? item;
  final double size;
  final IconData fallback;

  /// Border colour instead of the rarity's (e.g. flame for equipped gear).
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final color = Palette.rarity(item?.rarity ?? '');
    final path = item == null ? null : ItemIcons.asset(item!.id);
    final glyph = Icon(fallback, size: size * 0.5, color: color);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.22),
        border: Border.all(
          color: ring ?? color.withValues(alpha: 0.55),
          width: ring == null ? 1 : 1.6,
        ),
      ),
      child:
          path == null
              ? glyph
              : Padding(
                padding: EdgeInsets.all(size * 0.08),
                child: Image.asset(
                  path,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => glyph,
                ),
              ),
    );
  }
}
