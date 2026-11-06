import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../data/item_icons.dart';
import '../l10n.dart';
import '../theme.dart';
import 'item_screen.dart';

class SetsScreen extends StatelessWidget {
  const SetsScreen({super.key, required this.db, this.embedded = false});
  final GameDb db;

  /// Inside the Codex tabs: no app bar of its own.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final k = LiveScope.of(context).state?.knowledge;
    String progress(ItemSet s) =>
        k == null
            ? '${s.entries.length}'
            : '${s.entries.where((e) => e.done?.likely(k) ?? false).length}/${s.entries.length}';
    final byCategory = <String, List<ItemSet>>{};
    for (final s in db.sets) {
      (byCategory[s.category] ??= []).add(s);
    }
    final cats =
        byCategory.keys.toList()..sort((a, b) => gt(a).compareTo(gt(b)));
    final list = ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            tr('{sets} sets in {groups} groups', {
              'sets': db.sets.length,
              'groups': cats.length,
            }),
            style: const TextStyle(color: Palette.ash),
          ),
        ),
        for (final c in cats)
          ExpansionTile(
            leading: const Icon(
              Icons.collections_bookmark_outlined,
              color: Palette.veil,
            ),
            title: Text(gt(c)),
            subtitle: Text(
              trn(byCategory[c]!.length, '{n} set', '{n} sets'),
              style: const TextStyle(color: Palette.ash),
            ),
            children: [
              for (final s in byCategory[c]!)
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 56, right: 16),
                  title: Text(gt(s.name)),
                  trailing: Text(
                    progress(s),
                    style: const TextStyle(color: Palette.ash),
                  ),
                  onTap:
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SetScreen(db: db, set: s),
                        ),
                      ),
                ),
            ],
          ),
      ],
    );
    return embedded
        ? list
        : Scaffold(
          appBar: AppBar(
            title: Text(tr('Sets · {n}', {'n': db.sets.length})),
          ),
          body: list,
        );
  }
}

class SetScreen extends StatelessWidget {
  const SetScreen({super.key, required this.db, required this.set});
  final GameDb db;
  final ItemSet set;

  @override
  Widget build(BuildContext context) {
    final k = LiveScope.of(context).state?.knowledge;
    return Scaffold(
      appBar: AppBar(title: Text(gt(set.name))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              trn(set.entries.length, '{set} · {n} item', '{set} · {n} items', {
                'set': gt(set.category),
              }),
              style: const TextStyle(color: Palette.ash),
            ),
          ),
          for (final e in set.entries)
            if (db.items[e.itemId] case final item?)
              _EntryTile(db: db, entry: e, item: item, known: k),
        ],
      ),
    );
  }
}

/// One item of a set. The first hint is the subtitle: one line folded, in full when open (not repeated
/// below it).
class _EntryTile extends StatefulWidget {
  const _EntryTile({
    required this.db,
    required this.entry,
    required this.item,
    required this.known,
  });
  final GameDb db;
  final SetEntry entry;
  final Item item;
  final Set<String>? known;

  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final db = widget.db,
        e = widget.entry,
        item = widget.item,
        k = widget.known;
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        onExpansionChanged: (v) => setState(() => open = v),
        leading:
            k != null && (e.done?.likely(k) ?? false)
                ? const Icon(Icons.check_circle, color: Palette.spring)
                : ItemIcon(item, size: 32),
        title: Text(gt(item.name)),
        subtitle:
            e.hints.isEmpty
                ? null
                : Text(
                  gt(e.hints.first),
                  maxLines: open ? null : 1,
                  overflow: open ? null : TextOverflow.ellipsis,
                  style: TextStyle(
                    color: open ? null : Palette.ash,
                    fontSize: open ? 14 : 12,
                    height: open ? 1.4 : null,
                  ),
                ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final h in e.hints.skip(1))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(gt(h), style: const TextStyle(height: 1.4)),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(tr('Item page')),
              onPressed:
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ItemScreen(db: db, item: item),
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
