import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/build.dart';
import '../data/game_db.dart';
import '../data/item_icons.dart';
import '../data/live_state.dart';
import '../data/share.dart';
import '../l10n.dart';
import '../labels.dart';
import '../theme.dart';
import 'skill_tree_screen.dart';
import 'widgets.dart';

/// The build as a card to share (Discord, a chat): the character, its class shares, what the build
/// favours, and the gear worn; as a picture with the same in words.
class ShareBuildScreen extends StatefulWidget {
  const ShareBuildScreen({super.key, required this.db});
  final GameDb db;

  @override
  State<ShareBuildScreen> createState() => _ShareBuildScreenState();
}

class _ShareBuildScreenState extends State<ShareBuildScreen> {
  final _card = GlobalKey();
  bool busy = false;

  Future<void> _share(String text) async {
    setState(() => busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final boundary =
          _card.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final ok = await sharePicture(
        png!.buffer.asUint8List(),
        'enshroud-buddy-build.png',
        text,
      );
      if (kIsWeb && ok) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              tr('Picture downloaded, and the build is on the clipboard'),
            ),
          ),
        );
      } else if (!ok) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('Couldn\'t share the build'))),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = widget.db;
    final s = LiveScope.of(context).state;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('Share build'))),
        body: Center(
          child: EmptyState(
            icon: Icons.wifi_tethering_off,
            title: tr('No live data yet'),
            message: tr('Your build appears after the PC agent reads a save.'),
          ),
        ),
      );
    }
    final target = BuildTarget(
      db,
      s.skills,
      skillPlan.nodes(db, s.skills.keys.toSet()),
    );
    final classes =
        target.classes.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    final shares = classes
        .where((e) => e.value >= 0.01)
        .map((e) => '${classLabel(e.key)} ${(e.value * 100).round()}%')
        .join(' · ');
    final favours = [
      for (final w in target.topWeapons) weaponLabel(w),
      ...target.topTraits,
    ];
    final worn = [
      for (final o in s.equipment)
        if (db.items[o.itemId] case final it?) (o, it),
    ];
    final level = tr('Level {level} · Flame strength {flame}', {
      'level': s.level,
      'flame': s.flameLevel,
    });
    final text = [
      '${s.character}: $level',
      if (shares.isNotEmpty) shares,
      if (favours.isNotEmpty) favours.join(', '),
      if (worn.isNotEmpty)
        tr('Worn: {items}', {
          'items': worn.map((w) => gt(w.$2.name)).join(', '),
        }),
      tr('Shared from Enshroud Buddy, an unofficial Enshrouded companion'),
    ].join('\n');

    return Scaffold(
      appBar: AppBar(title: Text(tr('Share build'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Center(
            child: RepaintBoundary(
              key: _card,
              child: Container(
                width: 380,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Palette.night,
                  border: Border.all(color: Palette.flame, width: 1.5),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.character,
                      style: const TextStyle(
                        fontFamily: 'Cinzel',
                        fontSize: 24,
                        color: Palette.flame,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(level, style: const TextStyle(color: Palette.ash)),
                    if (shares.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        shares,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Palette.bone,
                        ),
                      ),
                    ],
                    if (favours.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final (i, f) in favours.indexed)
                            i < target.topWeapons.length
                                ? Pill(f, color: Palette.flame)
                                : Pill(f),
                        ],
                      ),
                    ],
                    if (worn.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      for (final (o, it) in worn)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 30,
                                height: 30,
                                child: switch (ItemIcons.asset(o.itemId)) {
                                  final a? => Image.asset(a),
                                  null => const Icon(
                                    Icons.shield_outlined,
                                    color: Palette.ash,
                                  ),
                                },
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  gt(it.name),
                                  style: const TextStyle(color: Palette.bone),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (it.stats?.slotLabel case final l?
                                  when l.isNotEmpty)
                                Text(
                                  slotName(l),
                                  style: const TextStyle(
                                    color: Palette.ash,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                    const SizedBox(height: 14),
                    Text(
                      tr(
                        'Enshroud Buddy · unofficial fan app, not affiliated with Keen Games',
                      ),
                      style: const TextStyle(color: Palette.ash, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: busy ? null : () => _share(text),
            icon: const Icon(Icons.share),
            label: Text(
              kIsWeb ? tr('Download picture and copy text') : tr('Share'),
            ),
          ),
        ],
      ),
    );
  }
}
