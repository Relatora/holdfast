import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../hazards/aviation_impact.dart';
import '../pois/poi.dart';
import 'hazard_marker.dart';

/// A marker for every airport a hazard is likely to close: the airport's
/// plane with a warning badge in the hazard's colour, gently pulsing so a
/// closing airport catches the eye. One marker per airport, showing its
/// most urgent impact ([impacts] come most urgent first).
Widget affectedAirportLayer(List<AirportImpact> impacts, {required bool animate, required ValueChanged<Poi> onTap}) {
  final seen = <String>{};
  final markers = <Marker>[];
  for (final impact in impacts) {
    if (!seen.add(impact.airport.id)) continue;
    final airport = impact.airport;
    final color = impact.hazard.type.color;
    Widget badge = Semantics(
      button: true,
      label: '${airport.title}: ${impact.consequence}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: PoiCategory.airport.color,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 3),
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8)],
        ),
        child: const Padding(
          padding: EdgeInsets.all(5),
          child: Icon(Icons.flight_rounded, size: 18, color: Colors.white),
        ),
      ),
    );
    if (animate) {
      badge = badge
          .animate(onPlay: (c) => c.repeat(reverse: true))
          .scaleXY(begin: 1, end: 1.12, duration: 900.ms, curve: Curves.easeInOut);
    }
    markers.add(Marker(
      key: ValueKey('airport-impact-${airport.id}'),
      point: LatLng(airport.latitude, airport.longitude),
      width: 44,
      height: 44,
      child: GestureDetector(
        onTap: () => onTap(airport),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(child: badge),
            Positioned(
              right: 0,
              top: 0,
              child: CircleAvatar(
                radius: 8,
                backgroundColor: color,
                child: const Icon(Icons.priority_high_rounded, size: 11, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    ));
  }
  return MarkerLayer(markers: markers);
}
