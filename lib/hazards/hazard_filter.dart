/// Shortlisting and ordering hazards for the map and the Hazards list.
/// Plain Dart so the rules are unit-tested without widgets.
library;

import '../pois/poi.dart' show distanceMeters;
import 'hazard.dart';

/// Whether [hazard] belongs on a map filtered to [shown] categories
/// (empty means everything).
bool passesFilter(Hazard hazard, Set<HazardCategory> shown) =>
    shown.isEmpty || shown.contains(hazard.type.category);

enum HazardSort {
  nearest('Nearest'),
  severity('Most serious'),
  newest('Newest');

  const HazardSort(this.label);
  final String label;
}

/// [hazards] ordered for the list. Ties fall back to nearest first, so the
/// order never jumps about between rebuilds.
List<Hazard> sortHazards(
  Iterable<Hazard> hazards,
  HazardSort sort, {
  required double latitude,
  required double longitude,
}) {
  double away(Hazard h) => distanceMeters(latitude, longitude, h.latitude, h.longitude);
  final list = hazards.toList();
  list.sort((a, b) {
    final primary = switch (sort) {
      HazardSort.nearest => 0,
      HazardSort.severity => b.severity.index.compareTo(a.severity.index),
      HazardSort.newest => b.reportedAt.compareTo(a.reportedAt),
    };
    return primary != 0 ? primary : away(a).compareTo(away(b));
  });
  return list;
}

/// How many hazards fall in each category, for the filter chips.
Map<HazardCategory, int> countByCategory(Iterable<Hazard> hazards) {
  final counts = <HazardCategory, int>{};
  for (final h in hazards) {
    counts[h.type.category] = (counts[h.type.category] ?? 0) + 1;
  }
  return counts;
}
