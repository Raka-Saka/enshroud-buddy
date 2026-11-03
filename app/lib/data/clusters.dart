/// Map points of one kind that sit close together at the current zoom, shown as one marker with a count.
class Cluster<T> {
  Cluster(this.items, this.x, this.y);

  /// The points it stands for; one item is a plain marker.
  final List<T> items;

  /// Their middle, in map pixels.
  final double x, y;
}

/// Groups [items] of the same [group] that fall in the same square of a grid [cell] map pixels wide, when a
/// square holds at least [min] of them; the rest stay single. The grid is fixed to the map, so groups don't
/// shift while panning, only when the zoom (and [cell]) changes.
List<Cluster<T>> clusterPoints<T>(
  Iterable<T> items, {
  required double Function(T) x,
  required double Function(T) y,
  required String Function(T) group,
  required double cell,
  int min = 3,
}) {
  final buckets = <(String, int, int), List<T>>{};
  for (final it in items) {
    (buckets[(group(it), (x(it) / cell).floor(), (y(it) / cell).floor())] ??=
            [])
        .add(it);
  }
  final out = <Cluster<T>>[];
  for (final b in buckets.values) {
    if (b.length < min) {
      out.addAll(b.map((it) => Cluster([it], x(it), y(it))));
      continue;
    }
    var sx = 0.0, sy = 0.0;
    for (final it in b) {
      sx += x(it);
      sy += y(it);
    }
    out.add(Cluster(b, sx / b.length, sy / b.length));
  }
  return out;
}
