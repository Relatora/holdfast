import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../../map/hazard_marker.dart';
import '../hazard.dart';
import 'zones.dart';

/// Map layers with every hazard's [zoneRings]: dashed rings with a label at
/// the top of each, solid and filled for a danger zone.
List<Widget> zoneLayers(Iterable<Hazard> hazards) {
  final circles = <CircleMarker>[];
  final labels = <Marker>[];
  const distance = Distance();
  for (final hazard in hazards) {
    final rings = zoneRings(hazard);
    if (rings.isEmpty) continue;
    final centre = LatLng(hazard.latitude, hazard.longitude);
    final color = hazard.type.color;
    for (final ring in rings.reversed) {
      circles.add(CircleMarker(
        point: centre,
        radius: ring.radiusMeters,
        useRadiusInMeter: true,
        color: color.withValues(alpha: ring.danger ? 0.16 : 0.04),
        borderColor: color.withValues(alpha: ring.danger ? 0.9 : 0.65),
        borderStrokeWidth: ring.danger ? 2.5 : 1.5,
      ));
      labels.add(Marker(
        point: distance.offset(centre, ring.radiusMeters, 0),
        width: 140,
        height: 22,
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              child: Text(
                ring.label,
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ));
    }
  }
  if (circles.isEmpty) return const [];
  return [CircleLayer(circles: circles), MarkerLayer(markers: labels)];
}
