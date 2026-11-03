import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game_db.dart';
import 'live_state.dart';

/// Something I want to make: item id and how many.
class Goal {
  Goal(this.itemId, this.count);
  final String itemId;
  int count;
  Map<String, dynamic> toJson() => {'i': itemId, 'n': count};
}

/// My shopping list of goals, kept on the phone.
class Goals extends ChangeNotifier {
  final List<Goal> all = [];

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString('goals');
      if (raw != null) {
        all
          ..clear()
          ..addAll([
            for (final j in jsonDecode(raw) as List) Goal(j['i'], j['n']),
          ]);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    await (await SharedPreferences.getInstance()).setString(
      'goals',
      jsonEncode([for (final g in all) g.toJson()]),
    );
    notifyListeners();
  }

  Future<void> add(String itemId, int count) async {
    final g = all.where((g) => g.itemId == itemId).firstOrNull;
    if (g != null) {
      g.count += count;
    } else {
      all.add(Goal(itemId, count));
    }
    await _save();
  }

  Future<void> setCount(Goal g, int count) async {
    if (count <= 0) {
      all.remove(g);
    } else {
      g.count = count;
    }
    await _save();
  }
}

/// One line of a plan: use stock, craft, or gather.
class PlanStep {
  PlanStep({
    required this.ref,
    required this.need,
    required this.fromStock,
    this.recipe,
    this.batches = 0,
    this.children = const [],
  });

  /// Item id or `cat:<id>`.
  final String ref;
  final int need, fromStock;
  final Recipe? recipe;
  final int batches;
  final List<PlanStep> children;

  int get missing => need - fromStock;
  bool get crafted => recipe != null && batches > 0;
}

/// Works out what a list of goals needs, against what I own.
class Planner {
  Planner(this.db, this.state) : stock = Map.of(state?.totals ?? const {});

  final GameDb db;
  final LiveState? state;

  /// Remaining stock while planning: each goal uses up what earlier goals did not.
  final Map<String, int> stock;

  /// Raw materials still to gather, summed over every goal.
  final Map<String, int> toGather = {};

  /// What the plan takes from stock, per item id (category inputs resolved to the items used).
  final Map<String, int> taken = {};

  bool unlocked(Recipe r) =>
      state == null || state!.recipesUnlocked.contains(r.id);

  /// The recipe to use: an unlocked one first, then any.
  Recipe? recipeFor(String itemId) {
    final rs = db.madeBy[itemId];
    if (rs == null || rs.isEmpty) return null;
    return rs.firstWhere(unlocked, orElse: () => rs.first);
  }

  int _take(String ref, int need) {
    var got = 0;
    for (final id
        in ref.startsWith('cat:')
            ? db.categories[ref.substring(4)] ?? const <String>[]
            : [ref]) {
      final have = stock[id] ?? 0;
      final use = have < need - got ? have : need - got;
      if (use > 0) {
        stock[id] = have - use;
        taken[id] = (taken[id] ?? 0) + use;
        got += use;
      }
      if (got == need) break;
    }
    return got;
  }

  PlanStep plan(String ref, int need, {int depth = 0, bool useStock = true}) {
    final fromStock = useStock ? _take(ref, need) : 0;
    final missing = need - fromStock;
    if (missing == 0)
      return PlanStep(ref: ref, need: need, fromStock: fromStock);
    final recipe = ref.startsWith('cat:') || depth > 5 ? null : recipeFor(ref);
    if (recipe == null) {
      toGather[ref] = (toGather[ref] ?? 0) + missing;
      return PlanStep(ref: ref, need: need, fromStock: fromStock);
    }
    final makes =
        recipe.outputs
            .firstWhere((o) => o.ref == ref, orElse: () => recipe.outputs.first)
            .count;
    final batches = (missing + makes - 1) ~/ makes;
    return PlanStep(
      ref: ref,
      need: need,
      fromStock: fromStock,
      recipe: recipe,
      batches: batches,
      children: [
        for (final i in recipe.inputs)
          plan(i.ref, i.count * batches, depth: depth + 1),
      ],
    );
  }

  /// Plans every goal; the goal item itself is made, not taken from stock.
  List<PlanStep> planAll(List<Goal> goals) => [
    for (final g in goals) plan(g.itemId, g.count, useStock: false),
  ];
}
