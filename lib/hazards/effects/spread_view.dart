import 'package:flutter_map/flutter_map.dart';
import 'package:material_ui/material_ui.dart';

import '../../map/hazard_marker.dart';
import '../hazard.dart';
import 'spread.dart';

/// Map layer with the downwind plume of every drifting hazard: the 6 h band
/// faintest, the 1 h band strongest, each labelled with its time.
Widget spreadLayer(Iterable<Hazard> hazards) {
  final polygons = <Polygon>[];
  for (final hazard in hazards) {
    final plumes = spreadPlumes(hazard);
    for (final plume in plumes.reversed) {
      final strength = switch (plume.hours) {
        1 => 0.28,
        3 => 0.18,
        _ => 0.10,
      };
      polygons.add(Polygon(
        points: plume.outline,
        color: hazard.type.color.withValues(alpha: strength),
        borderColor: hazard.type.color.withValues(alpha: 0.6),
        borderStrokeWidth: 1.5,
        pattern: const StrokePattern.dotted(),
        label: '${plume.hours} h',
        labelStyle: TextStyle(color: hazard.type.color, fontWeight: FontWeight.bold),
        labelPlacementCalculator: const PolygonLabelPlacementCalculator.centroid(),
      ));
    }
  }
  return PolygonLayer(polygons: polygons);
}
