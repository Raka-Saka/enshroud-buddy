import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/game_db.dart';
import '../data/history.dart';
import '../data/live_state.dart';
import '../theme.dart';
import 'widgets.dart';

/// The journey so far: level over time, and what each play session brought.
class JourneyScreen extends StatelessWidget {
  const JourneyScreen({super.key, required this.db});
  final GameDb db;

  static const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static String day(DateTime t) => '${t.day} ${months[t.month - 1]}';
  static String time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final h = LiveScope.of(context).history;
    final name = (String id) => db.items[id]?.name ?? id;
    final steps =
        [
          for (var i = h.length - 1; i > 0; i--)
            (h[i], changes(h[i - 1], h[i], name, db.balancing)),
        ].where((s) => s.$2.isNotEmpty).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Journey')),
      body:
          h.length < 2
              ? const Center(
                child: EmptyState(
                  icon: Icons.timeline,
                  title: 'Your journey starts here',
                  message:
                      'The PC agent records a snapshot at every game save (and reads the game\'s own backups once), so this fills in as you play.',
                ),
              )
              : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        for (final (v, l) in [
                          ('+${h.last.level - h.first.level}', 'levels'),
                          ('+${h.last.recipes - h.first.recipes}', 'recipes'),
                          (
                            '+${h.last.roots - h.first.roots + h.last.wells - h.first.wells}',
                            'Roots and Wells',
                          ),
                        ]) ...[
                          Expanded(child: StatTile(value: v, label: l)),
                          if (l != 'Roots and Wells') const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                  DashCard(
                    title: 'Level since ${day(h.first.t)}',
                    icon: Icons.show_chart,
                    child: SizedBox(
                      height: 140,
                      child: CustomPaint(
                        painter: _LevelChart(h),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                  const SectionTitle('Milestones'),
                  for (final (s, lines) in steps)
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(width: 20),
                          Column(
                            children: [
                              const SizedBox(height: 14),
                              Container(
                                width: 12,
                                height: 12,
                                decoration: const BoxDecoration(
                                  color: Palette.flame,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              Expanded(
                                child: Container(
                                  width: 2,
                                  color: Palette.shroudHigh,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(0, 8, 16, 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${day(s.t)} · ${time(s.t)} · level ${s.level}',
                                    style: const TextStyle(
                                      color: Palette.ash,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  for (final l in lines)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(l),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Text(
                      'Started ${day(h.first.t)} at level ${h.first.level}. Earlier play isn\'t in the game\'s backups.',
                      style: const TextStyle(color: Palette.ash, fontSize: 12),
                    ),
                  ),
                ],
              ),
    );
  }
}

/// Level over time as a stepped line, with a dot per snapshot.
class _LevelChart extends CustomPainter {
  _LevelChart(this.h);
  final List<Snapshot> h;

  @override
  void paint(Canvas canvas, Size size) {
    final t0 = h.first.t.millisecondsSinceEpoch.toDouble();
    final t1 = math.max(h.last.t.millisecondsSinceEpoch.toDouble(), t0 + 1);
    final lo = h.map((s) => s.level).reduce(math.min).toDouble() - 1;
    final hi = h.map((s) => s.level).reduce(math.max).toDouble() + 1;
    const left = 28.0, bottom = 18.0;
    Offset at(Snapshot s) => Offset(
      left +
          (s.t.millisecondsSinceEpoch - t0) /
              (t1 - t0) *
              (size.width - left - 8),
      (size.height - bottom) * (1 - (s.level - lo) / (hi - lo)),
    );
    final grid =
        Paint()
          ..color = Palette.shroudHigh
          ..strokeWidth = 1;
    final label = TextStyle(
      color: Palette.ash,
      fontSize: 10,
      fontFamily: 'Roboto',
    );
    for (final v in [lo + 1, hi - 1]) {
      final y = (size.height - bottom) * (1 - (v - lo) / (hi - lo));
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
      final tp = TextPainter(
        text: TextSpan(text: v.round().toString(), style: label),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }
    final path = Path();
    for (var i = 0; i < h.length; i++) {
      final p = at(h[i]);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, at(h[i - 1]).dy);
        path.lineTo(p.dx, p.dy);
      }
    }
    final fill =
        Path.from(path)
          ..lineTo(at(h.last).dx, size.height - bottom)
          ..lineTo(at(h.first).dx, size.height - bottom)
          ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Palette.flame.withValues(alpha: 0.35),
            Palette.flame.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Palette.flame
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
    for (final s in h) {
      canvas.drawCircle(at(s), 3.5, Paint()..color = Palette.bone);
    }
    for (final s in [h.first, h.last]) {
      final tp = TextPainter(
        text: TextSpan(text: JourneyScreen.day(s.t), style: label),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = (at(s).dx - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(x, size.height - tp.height));
    }
  }

  @override
  bool shouldRepaint(_LevelChart old) => old.h != h;
}
