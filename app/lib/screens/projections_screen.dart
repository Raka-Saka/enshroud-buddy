import 'package:flutter/material.dart';

import '../data/build.dart';
import '../data/game_db.dart';
import '../data/live_state.dart';
import '../data/projection.dart';
import '../l10n.dart';
import '../labels.dart';
import '../theme.dart';
import 'skill_tree_screen.dart';
import 'widgets.dart';

/// Suggested builds: where each direction takes the character with a point budget.
class ProjectionsScreen extends StatefulWidget {
  const ProjectionsScreen({super.key, required this.db});
  final GameDb db;

  @override
  State<ProjectionsScreen> createState() => _ProjectionsScreenState();
}

class _ProjectionsScreenState extends State<ProjectionsScreen> {
  int extraLevels = 10;

  @override
  Widget build(BuildContext context) {
    final db = widget.db;
    final s = LiveScope.of(context).state;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('Suggested builds'))),
        body: Center(child: Text(tr('No live data from the PC agent yet.'))),
      );
    }
    final points = SkillPoints(db, s);
    final perLevel = db.balancing?.skillPointsPerLevel ?? 2;
    final cap = db.balancing?.playerLevelMax; // the game's own level cap
    final toCap = cap == null ? 0 : (cap - s.level).clamp(0, cap);
    final budget = points.free + perLevel * extraLevels;
    final target = BuildTarget(db, s.skills, const []);
    final goals = [
      Projection.fromBuild(db, s.skills, target),
      ...Projection.goals,
    ];
    final projections = [
      for (final g in goals)
        Projection(db, s.skills, g, budget, flameLevel: s.flameLevel),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(tr('Suggested builds'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (label, n) in [
                  (tr('Free now ({n})', {'n': points.free}), 0),
                  (tr('+{n} levels', {'n': 10}), 10),
                  (tr('+{n} levels', {'n': 20}), 20),
                  if (toCap > 0) (tr('Level {n}', {'n': cap}), toCap),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: extraLevels == n,
                    onSelected: (_) => setState(() => extraLevels = n),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              trn(
                budget,
                '{n} points to spend. Each path starts from your learned skills and follows the tree\'s links.',
                '{n} points to spend. Each path starts from your learned skills and follows the tree\'s links.',
              ),
              style: const TextStyle(color: Palette.ash, fontSize: 12),
            ),
          ),
          for (final p in projections)
            Card(
              child: InkWell(
                onTap:
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProjectionScreen(db: db, p: p),
                      ),
                    ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              p.goal.name,
                              style: const TextStyle(
                                fontFamily: 'Cinzel',
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          Pill(
                            tr('{n} pts', {'n': p.spent}),
                            color: Palette.flame,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        p.goal.blurb,
                        style: const TextStyle(
                          color: Palette.ash,
                          fontSize: 12.5,
                        ),
                      ),
                      if (p.goal.weapons.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final w in p.goal.weapons)
                              Pill(weaponLabel(w)),
                          ],
                        ),
                      ],
                      const SizedBox(height: 10),
                      ..._gains(p),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The three axes that grow most, as before/after bars.
  List<Widget> _gains(Projection p) {
    final grown = [
      for (final a in Projection.axes)
        if (p.share(a) > p.share(a, projected: false))
          (a, p.share(a) - p.share(a, projected: false)),
    ]..sort((x, y) => y.$2.compareTo(x.$2));
    if (grown.isEmpty) {
      return [
        Text(
          tr('Nothing left to gain for this direction.'),
          style: const TextStyle(color: Palette.ash, fontSize: 12),
        ),
      ];
    }
    return [
      for (final (a, _) in grown.take(3))
        AxisBar(
          label: Projection.axisNames[a]!,
          before: p.share(a, projected: false),
          after: p.share(a),
        ),
    ];
  }
}

/// One axis: what is taken now (dark) and after the projection (bright), with the percentages.
class AxisBar extends StatelessWidget {
  const AxisBar({
    super.key,
    required this.label,
    required this.before,
    required this.after,
    this.labelWidth = 110,
  });
  final String label;
  final double before, after;
  final double labelWidth;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: labelWidth,
          child: Text(label, style: const TextStyle(fontSize: 12.5)),
        ),
        Expanded(
          child: Stack(
            children: [
              LinearProgressIndicator(
                value: after,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              LinearProgressIndicator(
                value: before,
                minHeight: 8,
                color: Palette.ember,
                backgroundColor: Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 76,
          child: Text(
            '${(before * 100).round()}% → ${(after * 100).round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(color: Palette.ash, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

/// One projection: axis bars before and after, the steps in order, and adopting it as the plan.
class ProjectionScreen extends StatelessWidget {
  const ProjectionScreen({super.key, required this.db, required this.p});
  final GameDb db;
  final Projection p;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(p.goal.name)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              tr(
                'Bars: share of what the tree offers this build, now (dark) and after {n} points (bright).',
                {'n': p.spent},
              ),
              style: const TextStyle(color: Palette.ash, fontSize: 12),
            ),
          ),
          for (final a in Projection.axes)
            if ((p.axisMax[a] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: AxisBar(
                  label: Projection.axisNames[a]!,
                  before: p.share(a, projected: false),
                  after: p.share(a),
                  labelWidth: 120,
                ),
              ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FilledButton.icon(
              icon: const Icon(Icons.flag),
              label: Text(tr('Use as my skill plan')),
              onPressed:
                  p.steps.isEmpty
                      ? null
                      : () {
                        skillPlan.replace(
                          p.steps.map((s) => s.skill.id).toSet(),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr(
                                'Plan set. The skill tree and Build screen now follow it.',
                              ),
                            ),
                          ),
                        );
                      },
            ),
          ),
          SectionTitle(tr('Steps · {n}', {'n': p.steps.length})),
          for (final (i, st) in p.steps.indexed)
            ListTile(
              dense: true,
              leading: Text(
                '${i + 1}',
                style: const TextStyle(color: Palette.ash),
              ),
              title: Text(
                '${gt(st.skill.name)}${st.skill.maxLevel > 1 ? tr(' · rank {n}', {'n': st.rank}) : ''}',
              ),
              subtitle: Text(
                [
                  '${gt(st.skill.archetype)} · ${tr('{n} pt', {'n': st.skill.cost})}',
                  gt(st.skill.description ?? '').split('\n').first,
                ].join('\n'),
                style: const TextStyle(color: Palette.ash, fontSize: 12),
              ),
              trailing:
                  st.skill.axes.isEmpty
                      ? null
                      : Text(
                        st.skill.axes
                            .map(
                              (a) => Projection.axisNames[a]!.split(' ').first,
                            )
                            .join('\n'),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Palette.spring,
                          fontSize: 11,
                        ),
                      ),
            ),
        ],
      ),
    );
  }
}
