import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../l10n.dart';
import '../theme.dart';
import 'item_screen.dart';
import 'widgets.dart';

/// [DocsScreen.title] (English, from the caller) for display.
String _titleText(String title) => switch (title) {
  'Lore' => tr('Lore'),
  'Quests' => tr('Quests'),
  _ => title,
};

/// Lore documents or quests, grouped by category, with search.
class DocsScreen extends StatefulWidget {
  const DocsScreen({
    super.key,
    required this.db,
    required this.docs,
    required this.title,
    this.embedded = false,
  });
  final GameDb db;
  final List<Doc> docs;
  final String title;

  /// Inside the Journal tab: no app bar of its own.
  final bool embedded;

  @override
  State<DocsScreen> createState() => _DocsScreenState();
}

class _DocsScreenState extends State<DocsScreen> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final st = LiveScope.of(context).state;
    final k = st?.knowledge;
    bool done(Doc d) =>
        k != null &&
        d.pages.isNotEmpty &&
        (d.pages.last.done?.likely(k, st!.unlockContext) ?? false);
    final needle = q.toLowerCase();
    final shown = widget.docs.where(
      (d) =>
          needle.isEmpty ||
          d.name.toLowerCase().contains(needle) ||
          gt(d.name).toLowerCase().contains(needle) ||
          d.pages.any(
            (p) =>
                p.text.toLowerCase().contains(needle) ||
                gt(p.text).toLowerCase().contains(needle),
          ),
    );
    final byCategory = <String, List<Doc>>{};
    for (final d in shown) {
      (byCategory[d.category] ??= []).add(d);
    }
    final cats =
        byCategory.keys.toList()..sort((a, b) => gt(a).compareTo(gt(b)));
    final n = widget.docs.length;
    return Scaffold(
      appBar:
          widget.embedded
              ? null
              : AppBar(title: Text('${_titleText(widget.title)} · $n')),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(12, widget.embedded ? 8 : 0, 12, 6),
            child: TextField(
              onChanged: (v) => setState(() => q = v),
              decoration: InputDecoration(
                hintText: switch (widget.title) {
                  'Lore' => tr('Search {n} lore texts', {'n': n}),
                  'Quests' => tr('Search {n} quests texts', {'n': n}),
                  _ => tr('Search {n} {what} texts', {
                    'n': n,
                    'what': widget.title.toLowerCase(),
                  }),
                },
                prefixIcon: const Icon(Icons.search, color: Palette.flame),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final c in cats)
                  ExpansionTile(
                    initiallyExpanded: needle.isNotEmpty,
                    leading: const Icon(
                      Icons.auto_stories_outlined,
                      color: Palette.veil,
                    ),
                    title: Text(gt(c)),
                    subtitle: Text(
                      '${byCategory[c]!.length}',
                      style: const TextStyle(color: Palette.ash),
                    ),
                    children: [
                      for (final d in byCategory[c]!)
                        ListTile(
                          contentPadding: const EdgeInsets.only(
                            left: 56,
                            right: 16,
                          ),
                          leading:
                              d.main
                                  ? const Icon(
                                    Icons.local_fire_department,
                                    color: Palette.flame,
                                    size: 18,
                                  )
                                  : null,
                          title: Text(
                            gt(d.name),
                            style: TextStyle(
                              color:
                                  k == null || done(d)
                                      ? Palette.bone
                                      : Palette.ash,
                            ),
                          ),
                          trailing:
                              done(d)
                                  ? const Icon(
                                    Icons.check_circle,
                                    size: 18,
                                    color: Palette.spring,
                                  )
                                  : d.pages.length > 1
                                  ? Text(
                                    trn(d.pages.length, '{n} page', '{n} pages'),
                                    style: const TextStyle(
                                      color: Palette.ash,
                                      fontSize: 12,
                                    ),
                                  )
                                  : null,
                          onTap:
                              () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder:
                                      (_) => DocScreen(db: widget.db, doc: d),
                                ),
                              ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DocScreen extends StatelessWidget {
  const DocScreen({super.key, required this.db, required this.doc});
  final GameDb db;
  final Doc doc;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(gt(doc.name), overflow: TextOverflow.ellipsis)),
    body: ListView(
      padding: const EdgeInsets.only(bottom: 24, top: 4),
      children: [
        for (final p in doc.pages) Parchment(title: gtn(p.title), text: gt(p.text)),
        if (doc.rewards.isNotEmpty) ...[
          SectionTitle(tr('Rewards')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final id in doc.rewards)
                  ActionChip(
                    label: Text(db.shownName(id)),
                    onPressed:
                        () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (_) => ItemScreen(db: db, item: db.items[id]!),
                          ),
                        ),
                  ),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}
