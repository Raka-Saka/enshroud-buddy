import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/build.dart';
import '../data/projection.dart';
import '../data/game_db.dart';
import '../data/live_state.dart';
import '../l10n.dart';
import '../labels.dart';
import '../theme.dart';
import 'ask_screen.dart';
import 'items_screen.dart';

final skillPlan = SkillPlan()..load();

const classColor = {
  'Warrior': Palette.ember,
  'Ranger': Palette.spring,
  'Mage': Palette.veil,
  'Neutral': Palette.flame,
};
const _gold = Palette.gold;

/// The game's node art (exported from the UI textures by tools/build_db.py), loaded once.
class SkillArt {
  SkillArt._();
  static final images = <String, ui.Image>{};
  static Future<void>? _loading;

  static Future<void> load(GameDb db) =>
      _loading ??= () async {
        final names = <String>[
          for (final kind in ['passiveskill', 'activeskill', 'attribute'])
            for (final state in ['activated', 'inreach', 'outofreach'])
              '${kind}_$state',
          'spark',
          'ring',
          for (final k in db.skills)
            if (k.icon != null) ...[
              'icon_${k.icon}_unlocked',
              'icon_${k.icon}_out_of_reach',
            ],
        ];
        for (final n in names.toSet()) {
          try {
            final data = await rootBundle.load('assets/skilltree/$n.png');
            final codec = await ui.instantiateImageCodec(
              data.buffer.asUint8List(),
            );
            images[n] = (await codec.getNextFrame()).image;
          } catch (_) {}
        }
      }();
}

/// The skill tree, drawn like the game's: Spark ring at the centre, nodes in gold (learned),
/// bronze (can learn next) or dark, the plan in gold outline.
class SkillTreeScreen extends StatefulWidget {
  const SkillTreeScreen({super.key, required this.db, this.focus});
  final GameDb db;

  /// Opens centred on this skill with its details showing.
  final Skill? focus;

  @override
  State<SkillTreeScreen> createState() => _SkillTreeScreenState();
}

class _SkillTreeScreenState extends State<SkillTreeScreen> {
  static const canvas = 1400.0;
  final viewer = TransformationController();

  /// Game layout to canvas: the tree's own square (GameDb.skillLayout).
  Offset pos(Skill k) {
    final (u, v) = widget.db.skillLayout.unit(k.x, k.y);
    return Offset(u * canvas, v * canvas);
  }

  @override
  void initState() {
    super.initState();
    skillPlan.addListener(_changed);
    SkillArt.load(widget.db).then((_) => mounted ? setState(() {}) : null);
    // start zoomed on the centre
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = context.size ?? const Size(400, 700);
      final focus = widget.focus;
      final c =
          focus != null ? pos(focus) : const Offset(canvas / 2, canvas / 2);
      final scale = focus != null ? 1.4 : 0.9;
      viewer.value =
          Matrix4.identity()
            ..translate(
              size.width / 2 - c.dx * scale,
              size.height / 2.4 - c.dy * scale,
            )
            ..scale(scale);
      if (focus != null) {
        showNode(focus, LiveScope.of(context).state?.skills ?? const {});
      }
    });
  }

  @override
  void dispose() {
    skillPlan.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  void showNode(Skill k, Map<String, int> learned) {
    final rank = learned[k.id];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A0E24),
      builder:
          (ctx) => Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (k.icon != null &&
                        SkillArt.images['icon_${k.icon}_unlocked'] != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: RawImage(
                          image: SkillArt.images['icon_${k.icon}_unlocked'],
                          width: 36,
                          height: 36,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        gt(k.name),
                        style: Theme.of(ctx).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    gt(k.archetype),
                    if (k.cls != 'Neutral') classLabel(k.cls),
                    switch (k.type) {
                      'ActiveSkill' => tr('Active skill'),
                      'PassiveSkill' => tr('Passive skill'),
                      'Attribute' => tr('Attribute'),
                      _ => k.type.replaceAll('Skill', ' skill'),
                    },
                    k.maxLevel > 0
                        ? (k.cost > 1
                            ? trn(
                              k.cost,
                              '{n} point per rank',
                              '{n} points per rank',
                            )
                            : tr('{n} point per rank', {'n': k.cost}))
                        : (k.cost > 1
                            ? trn(k.cost, '{n} point', '{n} points')
                            : tr('{n} point', {'n': k.cost})),
                  ].join(' · '),
                  style: const TextStyle(color: Palette.ash),
                ),
                const SizedBox(height: 8),
                if (rank != null)
                  Text(
                    k.maxLevel > 0
                        ? tr('Learned: rank {rank} of {max}', {
                          'rank': rank,
                          'max': k.maxLevel,
                        })
                        : tr('Learned'),
                    style: const TextStyle(
                      color: _gold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (k.description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      gt(k.description!).replaceAll('%k', '…'),
                      style: const TextStyle(height: 1.4),
                    ),
                  ),
                if (k.perLevel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      gt(k.perLevel!).replaceAll('%k', '…'),
                      style: const TextStyle(color: Palette.ash),
                    ),
                  ),
                if (k.guessed)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      tr(
                        'Numbers from the game files; which number goes where is a best guess.',
                      ),
                      style: const TextStyle(color: Palette.ash, fontSize: 12),
                    ),
                  ),
                if (k.axes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      [
                        k.axes
                            .map((a) => Projection.axisNames[a] ?? a)
                            .join(', '),
                        if (k.weapons.isNotEmpty)
                          tr('with {weapons}', {
                            'weapons': k.weapons.map(weaponLabel).join(', '),
                          }),
                      ].join(' · '),
                      style: const TextStyle(
                        color: Palette.spring,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                if (rank == null && k.type != 'Root')
                  FilledButton.icon(
                    icon: Icon(
                      skillPlan.targets.contains(k.id)
                          ? Icons.remove
                          : Icons.add,
                    ),
                    label: Text(
                      skillPlan.targets.contains(k.id)
                          ? tr('Remove from plan')
                          : tr('Plan this skill'),
                    ),
                    onPressed: () {
                      skillPlan.toggle(k.id);
                      Navigator.pop(ctx);
                    },
                  ),
                if (widget.db.byEffect[k.name] case final gear?)
                  TextButton.icon(
                    icon: const Icon(Icons.shield_outlined),
                    label: Text(
                      tr('Gear with this skill ({n})', {'n': gear.length}),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              (_) => Scaffold(
                                appBar: AppBar(title: Text(gt(k.name))),
                                body: ItemsScreen(
                                  db: widget.db,
                                  effect: k.name,
                                  embedded: true,
                                ),
                              ),
                        ),
                      );
                    },
                  ),
                if (k.type != 'Root')
                  TextButton.icon(
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(tr('Ask about this')),
                    onPressed: () {
                      Navigator.pop(ctx);
                      askAbout(context, widget.db, k.name, skillPrompts(k));
                    },
                  ),
              ],
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final db = widget.db;
    final s = LiveScope.of(context).state;
    final learned = s?.skills ?? const <String, int>{};
    final points = s == null ? null : SkillPoints(db, s);
    final plan = skillPlan.nodes(db, learned.keys.toSet());
    final planIds = {for (final k in plan) k.id};
    final planCost = plan.fold(0, (a, k) => a + k.cost);
    final reachable = <String>{
      for (final k in db.skills)
        if (!learned.containsKey(k.id) &&
            k.links.any(
              (l) => learned.containsKey(l) || db.skillById[l]?.type == 'Root',
            ))
          k.id,
    };

    return Scaffold(
      backgroundColor: const Color(0xFF0E0716),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0716),
        title: Text(tr('Skill tree')),
        actions: [
          if (skillPlan.targets.isNotEmpty)
            IconButton(
              tooltip: tr('Clear plan'),
              icon: const Icon(Icons.layers_clear),
              onPressed: () async {
                for (final t in skillPlan.targets.toList()) {
                  await skillPlan.toggle(t);
                }
              },
            ),
        ],
      ),
      body: Column(
        children: [
          if (points != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                tr(
                  'Level {level} · {spent} of {total} points spent · {free} free',
                  {
                    'level': s!.level,
                    'spent': points.spent,
                    'total': points.total,
                    'free': points.free,
                  },
                ),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          if (plan.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                '${tr('Plan: {nodes} nodes, {points} points', {'nodes': plan.length, 'points': planCost})}'
                '${points == null
                    ? ''
                    : planCost <= points.free
                    ? tr(' (you can take it now)')
                    : tr(' ({n} more levels)', {'n': ((planCost - points.free) / (db.balancing?.skillPointsPerLevel ?? 2)).ceil()})}',
                style: const TextStyle(color: _gold),
              ),
            ),
          Expanded(
            child: ClipRect(
              child: InteractiveViewer(
                transformationController: viewer,
                minScale: 0.25,
                maxScale: 6,
                boundaryMargin: const EdgeInsets.all(600),
                constrained: false,
                child: GestureDetector(
                  onTapUp: (d) {
                    final p = d.localPosition;
                    Skill? best;
                    // at least 24 dp on screen whatever the zoom (22 canvas px is 11 dp zoomed out)
                    final scale = viewer.value.getMaxScaleOnAxis();
                    var bestD = math.max(22.0, 24 / scale);
                    for (final k in db.skills) {
                      final dd = (pos(k) - p).distance;
                      if (dd < bestD) {
                        bestD = dd;
                        best = k;
                      }
                    }
                    if (best != null) showNode(best, learned);
                  },
                  child: CustomPaint(
                    size: const Size(canvas, canvas),
                    painter: _TreePainter(
                      db,
                      learned,
                      reachable,
                      planIds,
                      skillPlan.targets,
                      pos,
                      SkillArt.images,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Wrap(
              spacing: 12,
              children: [
                _Legend(const Color(0xFFE0B060), tr('learned'), filled: true),
                _Legend(
                  const Color(0xFF8A6A3A),
                  tr('can learn next'),
                  filled: true,
                ),
                _Legend(_gold, tr('planned')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.text, {this.filled = false});
  final Color color;
  final String text;
  final bool filled;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? color : null,
          border: Border.all(color: color, width: 2),
        ),
      ),
      const SizedBox(width: 4),
      Text(text, style: const TextStyle(fontSize: 12, color: Palette.ash)),
    ],
  );
}

class _TreePainter extends CustomPainter {
  _TreePainter(
    this.db,
    this.learned,
    this.reachable,
    this.plan,
    this.targets,
    this.pos,
    this.art,
  );
  final GameDb db;
  final Map<String, int> learned;
  final Set<String> reachable, plan, targets;
  final Offset Function(Skill) pos;
  final Map<String, ui.Image> art;

  void _image(
    Canvas canvas,
    ui.Image? img,
    Offset centre,
    double size, {
    double opacity = 1,
  }) {
    if (img == null) return;
    final src = Rect.fromLTWH(
      0,
      0,
      img.width.toDouble(),
      img.height.toDouble(),
    );
    final dst = Rect.fromCenter(
      center: centre,
      width: size,
      height: size * img.height / img.width,
    );
    canvas.drawImageRect(
      img,
      src,
      dst,
      Paint()
        ..color = Colors.white.withValues(alpha: opacity)
        ..filterQuality = FilterQuality.medium,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final layout = db.skillLayout;
    final centre = Offset(size.width / 2, size.height / 2);
    // nebula background
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          centre,
          size.width * 0.7,
          const [Color(0xFF2A1238), Color(0xFF160A22), Color(0xFF0B0612)],
          const [0, 0.55, 1],
        ),
    );
    for (final (dx, dy, r, c) in const [
      (-0.18, -0.2, 0.22, Color(0x3A6A2A8A)),
      (0.2, 0.15, 0.25, Color(0x2E8A2A5A)),
      (-0.1, 0.25, 0.2, Color(0x2A3A2A9A)),
    ]) {
      final o = centre + Offset(dx, dy) * size.width;
      canvas.drawCircle(
        o,
        r * size.width,
        Paint()
          ..shader = ui.Gradient.radial(o, r * size.width, [
            c,
            c.withValues(alpha: 0),
          ]),
      );
    }
    // the Spark ring
    final sparks = db.skills.where((k) => k.type == 'Root').toList();
    final ringR =
        sparks.isEmpty
            ? 0.0
            : sparks.map((k) => (pos(k) - centre).distance).reduce(math.min);
    canvas.drawCircle(
      centre,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xCCE040A0),
    );
    canvas.drawCircle(
      centre,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..color = const Color(0x33E040A0)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    _image(canvas, art['ring'], centre, ringR * 2.2, opacity: 0.6);
    // archetype names around the tree
    for (final (name, a) in layout.labels) {
      final p = centre + Offset(math.cos(a), math.sin(a)) * size.width * 0.46;
      final tp = TextPainter(
        text: TextSpan(
          text: gt(name).toUpperCase(),
          style: const TextStyle(
            color: Color(0x99D8C8E8),
            fontSize: 15,
            letterSpacing: 2,
            fontFamily: 'Cinzel',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }
    // connections
    final line = Paint()..strokeCap = StrokeCap.round;
    for (final k in db.skills) {
      for (final l in k.links) {
        final o = db.skillById[l];
        if (o == null || o.id.compareTo(k.id) < 0) continue;
        final lit =
            (learned.containsKey(k.id) || k.type == 'Root') &&
            (learned.containsKey(o.id) || o.type == 'Root');
        final planned =
            (plan.contains(k.id) ||
                learned.containsKey(k.id) ||
                k.type == 'Root') &&
            (plan.contains(o.id) ||
                learned.containsKey(o.id) ||
                o.type == 'Root') &&
            (plan.contains(k.id) || plan.contains(o.id));
        if (lit || planned) {
          line
            ..strokeWidth = 5
            ..color = (planned ? _gold : const Color(0xFFE050B0)).withValues(
              alpha: 0.25,
            )
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
          canvas.drawLine(pos(k), pos(o), line);
        }
        line
          ..maskFilter = null
          ..strokeWidth = lit || planned ? 1.8 : 1
          ..color =
              planned
                  ? _gold
                  : lit
                  ? const Color(0xFFF070C0)
                  : const Color(0x558A6BB8);
        canvas.drawLine(pos(k), pos(o), line);
      }
    }
    // nodes
    for (final k in db.skills) {
      final p = pos(k);
      if (k.type == 'Root') {
        _image(canvas, art['spark'], p, 34);
        continue;
      }
      final isLearned = learned.containsKey(k.id);
      final state =
          isLearned
              ? 'activated'
              : (reachable.contains(k.id) || plan.contains(k.id))
              ? 'inreach'
              : 'outofreach';
      final kind = switch (k.type) {
        'ActiveSkill' => 'activeskill',
        'Attribute' => 'attribute',
        _ => 'passiveskill',
      };
      final d = switch (kind) {
        'activeskill' => 34.0,
        'attribute' => 16.0,
        _ => k.icon != null || k.cost >= 3 ? 30.0 : 22.0,
      };
      final frame =
          art['${k.icon != null && kind == 'passiveskill' ? 'activeskill' : kind}_$state'];
      if (isLearned) {
        canvas.drawCircle(
          p,
          d * 0.75,
          Paint()
            ..color = const Color(0x66FFB040)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
        );
      }
      if (frame != null) {
        _image(canvas, frame, p, d);
      } else {
        canvas.drawCircle(
          p,
          d / 2,
          Paint()
            ..color =
                isLearned ? const Color(0xFFE0B060) : const Color(0xFF3A3040),
        );
      }
      if (k.icon != null) {
        _image(
          canvas,
          art['icon_${k.icon}_${isLearned ? 'unlocked' : 'out_of_reach'}'],
          p,
          d * 0.62,
        );
      }
      if (plan.contains(k.id) || targets.contains(k.id)) {
        canvas.drawCircle(
          p,
          d / 2 + (targets.contains(k.id) ? 5 : 2.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = _gold,
        );
      }
      if (k.maxLevel > 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${learned[k.id] ?? 0}/${k.maxLevel}',
            style: TextStyle(
              color:
                  isLearned ? const Color(0xFFFFE0A0) : const Color(0xBBD0C8D8),
              fontSize: 9,
              fontWeight: FontWeight.w700,
              shadows: const [Shadow(blurRadius: 3)],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, p + Offset(-tp.width / 2, d / 2 - 1));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TreePainter old) => true;
}
