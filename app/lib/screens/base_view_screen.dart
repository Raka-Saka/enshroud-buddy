import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/game_db.dart';
import '../data/live_state.dart';
import '../theme.dart';
import 'widgets.dart';

/// A base in 3D: its snapped building pieces, coloured by material. Drag to turn, pinch to zoom.
class BaseViewScreen extends StatefulWidget {
  const BaseViewScreen({super.key, required this.db, required this.base});
  final GameDb db;
  final Base base;

  @override
  State<BaseViewScreen> createState() => _BaseViewScreenState();
}

class _BaseViewScreenState extends State<BaseViewScreen> {
  double yaw = -0.6, pitch = 0.55, zoom = 1, _zoomStart = 1;
  final hidden = <String>{};

  /// A colour per building material, from its name; anything else gets a muted hue from its id.
  static Color materialColor(String name, String id) {
    final n = name.toLowerCase();
    for (final (k, c) in const [
      ('roof', Color(0xFF5E6E7E)),
      ('sandstone', Color(0xFFD8B97A)),
      ('flint', Color(0xFF6E7075)),
      ('brick', Color(0xFFA4553F)),
      ('mycelium', Color(0xFF8E6BBF)),
      ('hollow', Color(0xFF4E7470)),
      ('glass', Color(0xFF9FD3E0)),
      ('clay', Color(0xFFB5754F)),
      ('palm', Color(0xFFC69C6D)),
      ('polished', Color(0xFFC8C6BE)),
      ('refined', Color(0xFFB4B2AA)),
      ('fancy', Color(0xFFC9C2B0)),
      ('stone', Color(0xFF9A9A94)),
      ('timber', Color(0xFF9C6B45)),
      ('wood', Color(0xFF8B5E3C)),
      ('metal', Color(0xFF8E9AA6)),
      ('gold', Color(0xFFD4AF37)),
    ]) {
      if (n.contains(k)) return c;
    }
    final h = int.tryParse(id, radix: 16) ?? 0;
    return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.25, 0.55).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final db = widget.db;
    final b = widget.base;
    String name(String id) => db.items[id]?.name ?? id;
    final byMat = <String, int>{};
    final byShape = <String, int>{};
    for (final p in b.pieces) {
      byMat[p.material] = (byMat[p.material] ?? 0) + 1;
      byShape[p.shape] = (byShape[p.shape] ?? 0) + 1;
    }
    final mats =
        byMat.entries.toList()..sort((a, c) => c.value.compareTo(a.value));
    final shapes =
        byShape.entries.toList()..sort((a, c) => c.value.compareTo(a.value));
    final colors = {for (final m in byMat.keys) m: materialColor(name(m), m)};
    final shown = [
      for (final p in b.pieces)
        if (!hidden.contains(p.material)) p,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(b.label),
        actions: [
          IconButton(
            tooltip: 'Reset the view',
            icon: const Icon(Icons.center_focus_strong),
            onPressed:
                () => setState(() {
                  yaw = -0.6;
                  pitch = 0.55;
                  zoom = 1;
                }),
          ),
        ],
      ),
      body:
          b.pieces.isEmpty
              ? const Center(
                child: EmptyState(
                  icon: Icons.view_in_ar,
                  title: 'No snapped pieces here',
                  message:
                      'This base is built from free blocks (or not at all). Only snapped pieces such as walls, floors and roofs are drawn so far.',
                ),
              )
              : Column(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onScaleStart: (_) => _zoomStart = zoom,
                      onScaleUpdate:
                          (d) => setState(() {
                            yaw += d.focalPointDelta.dx * 0.01;
                            pitch = (pitch + d.focalPointDelta.dy * 0.01).clamp(
                              0.1,
                              1.45,
                            );
                            if (d.pointerCount > 1)
                              zoom = (_zoomStart * d.scale).clamp(0.4, 6);
                          }),
                      onDoubleTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => zoom = zoom > 1.5 ? 1 : 2.2);
                      },
                      child: Container(
                        color: Palette.night,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _BasePainter(
                            shown,
                            b.size,
                            colors,
                            yaw,
                            pitch,
                            zoom,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    color: Palette.shroud,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${b.pieces.length} pieces · altar ${b.altarLevel} · ${b.zone} build zone · drag to turn, pinch to zoom',
                          style: const TextStyle(
                            color: Palette.ash,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 36,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final e in mats)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: FilterChip(
                                    avatar: CircleAvatar(
                                      backgroundColor: colors[e.key],
                                      radius: 7,
                                    ),
                                    label: Text(
                                      '${name(e.key).replaceAll(' Block', '')} · ${e.value}',
                                    ),
                                    selected: !hidden.contains(e.key),
                                    onSelected: (on) {
                                      HapticFeedback.selectionClick();
                                      setState(
                                        () =>
                                            on
                                                ? hidden.remove(e.key)
                                                : hidden.add(e.key),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          shapes
                              .take(6)
                              .map((e) => '${e.value} ${name(e.key)}')
                              .join(' · '),
                          style: const TextStyle(
                            color: Palette.ash,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
    );
  }
}

/// Orthographic 3D: each piece is a box; visible faces are sorted far to near and lit from above.
class _BasePainter extends CustomPainter {
  _BasePainter(
    this.pieces,
    this.box,
    this.colors,
    this.yaw,
    this.pitch,
    this.zoom,
  );
  final List<Piece> pieces;
  final List<double> box;
  final Map<String, Color> colors;
  final double yaw, pitch, zoom;

  // face corners (indices into the 8 box corners) and outward normals
  static const _faces = [
    ([0, 1, 3, 2], [-1.0, 0.0, 0.0]),
    ([4, 6, 7, 5], [1.0, 0.0, 0.0]),
    ([0, 4, 5, 1], [0.0, -1.0, 0.0]),
    ([2, 3, 7, 6], [0.0, 1.0, 0.0]),
    ([0, 2, 6, 4], [0.0, 0.0, -1.0]),
    ([1, 5, 7, 3], [0.0, 0.0, 1.0]),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (pieces.isEmpty) return;
    // centre on the pieces themselves, not the whole build box
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity,
        maxY = -double.infinity,
        maxZ = -double.infinity;
    for (final p in pieces) {
      minX = math.min(minX, p.x);
      minY = math.min(minY, p.y);
      minZ = math.min(minZ, p.z);
      maxX = math.max(maxX, p.x + p.sx);
      maxY = math.max(maxY, p.y + p.sy);
      maxZ = math.max(maxZ, p.z + p.sz);
    }
    final cx = (minX + maxX) / 2,
        cy = (minY + maxY) / 2,
        cz = (minZ + maxZ) / 2;
    final extent = math.max(maxX - minX, math.max(maxZ - minZ, maxY - minY));
    final scale = math.min(size.width, size.height) / (extent * 1.25) * zoom;
    final cyaw = math.cos(yaw), syaw = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);
    // world: x east, y up, z north (away from the viewer). The camera looks down from the south by
    // `pitch`: farther points sit higher on screen, higher points are nearer (smaller depth).
    (double, double, double) rot(double x, double y, double z) {
      final x1 = x * cyaw - z * syaw, z1 = x * syaw + z * cyaw;
      final y2 = y * cp + z1 * sp, z2 = -y * sp + z1 * cp;
      return (x1, y2, z2);
    }

    Offset screen(double x, double y) =>
        Offset(size.width / 2 + x * scale, size.height / 2 - y * scale);

    // ground: the pieces' footprint grid, 4 m squares
    final grid =
        Paint()
          ..color = Palette.shroudHigh
          ..strokeWidth = 1;
    for (var gx = (minX / 8).floor() * 8.0; gx <= maxX; gx += 8) {
      final (a1, a2, _) = rot(gx - cx, minY - cy, minZ - cz);
      final (b1, b2, _) = rot(gx - cx, minY - cy, maxZ - cz);
      canvas.drawLine(screen(a1, a2), screen(b1, b2), grid);
    }
    for (var gz = (minZ / 8).floor() * 8.0; gz <= maxZ; gz += 8) {
      final (a1, a2, _) = rot(minX - cx, minY - cy, gz - cz);
      final (b1, b2, _) = rot(maxX - cx, minY - cy, gz - cz);
      canvas.drawLine(screen(a1, a2), screen(b1, b2), grid);
    }

    const light = [0.35, 0.85, 0.4];
    final faces = <(double, Path, Color)>[];
    for (final p in pieces) {
      final xs = [p.x - cx, p.x + p.sx - cx];
      final ys = [p.y - cy, p.y + p.sy - cy];
      final zs = [p.z - cz, p.z + p.sz - cz];
      final corners = <(double, double, double)>[
        for (final x in xs)
          for (final y in ys)
            for (final z in zs) rot(x, y, z),
      ];
      final base = colors[p.material] ?? Palette.ash;
      for (final (idx, n) in _faces) {
        // facing the viewer when its turned normal points toward the camera (negative depth)
        final (_, _, nz) = rot(n[0], n[1], n[2]);
        if (nz > -1e-6) continue;
        final lit =
            0.55 +
            0.45 *
                math.max(
                  0,
                  n[0] * light[0] + n[1] * light[1] + n[2] * light[2],
                );
        final path = Path();
        var depth = 0.0;
        for (var k = 0; k < 4; k++) {
          final c = corners[idx[k]];
          final o = screen(c.$1, c.$2);
          k == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
          depth += c.$3;
        }
        path.close();
        faces.add((depth / 4, path, Color.lerp(Colors.black, base, lit)!));
      }
    }
    faces.sort((a, b) => b.$1.compareTo(a.$1));
    final edge =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = Colors.black.withValues(alpha: 0.35);
    for (final (_, path, color) in faces) {
      canvas.drawPath(path, Paint()..color = color);
      canvas.drawPath(path, edge);
    }
  }

  @override
  bool shouldRepaint(_BasePainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      old.pieces.length != pieces.length;
}
