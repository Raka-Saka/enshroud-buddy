import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A map pin of my own, on the 1280 px fog-map grid.
class Pin {
  Pin({
    required this.x,
    required this.y,
    required this.title,
    this.note = '',
    this.kind = 'note',
    DateTime? created,
  }) : created = created ?? DateTime.now();

  factory Pin.fromJson(Map<String, dynamic> j) => Pin(
    x: (j['x'] as num).toDouble(),
    y: (j['y'] as num).toDouble(),
    title: j['title'] ?? '',
    note: j['note'] ?? '',
    kind: j['kind'] ?? 'note',
    created: DateTime.tryParse(j['created'] ?? ''),
  );

  double x, y;
  String title, note, kind;
  final DateTime created;

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'title': title,
    'note': note,
    'kind': kind,
    'created': created.toIso8601String(),
  };

  static const kinds = {
    'note': 'Note',
    'resource': 'Resource',
    'chest': 'Chest / loot',
    'danger': 'Danger',
    'todo': 'To do',
  };
}

/// My pins, kept on the phone. Game-data updates never touch them.
class Pins extends ChangeNotifier {
  final List<Pin> all = [];

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('pins');
      if (raw != null) {
        all
          ..clear()
          ..addAll([for (final j in jsonDecode(raw) as List) Pin.fromJson(j)]);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'pins',
      jsonEncode([for (final p in all) p.toJson()]),
    );
    notifyListeners();
  }

  Future<void> add(Pin p) async {
    all.add(p);
    await _save();
  }

  Future<void> update() => _save();

  Future<void> remove(Pin p) async {
    all.remove(p);
    await _save();
  }
}
