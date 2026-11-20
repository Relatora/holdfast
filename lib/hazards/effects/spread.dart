/// Where a drifting hazard is likely to spread with the wind: a simple,
/// clearly-labelled estimate, not a dispersion model.
///
/// Plain Dart. A plume is drawn as a teardrop: a small circle around the
/// source, widening downwind at a fixed half-angle (about ±12°, roughly
/// twice the crosswind spread of a plume in neutral weather, Pasquill class
/// D), with a rounded far end. Its length is how far the wind carries
/// things in the given time, capped per hazard type. Real plumes depend on
/// terrain, stability and release height; the UI says "estimate".
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../hazard.dart';
import '../hazard_details.dart';
import 'nuclear_effects.dart';

/// The times shown as bands.
const plumeHours = [1, 3, 6];

/// Half-angle of the plume's widening, in degrees.
const _spreadDegrees = 12.0;

/// Below this the air is calm and things spread evenly in every direction.
const _calmKmh = 3.0;

class Plume {
  const Plume({required this.hours, required this.lengthMeters, required this.outline});

  final int hours;

  /// How far downwind the band reaches.
  final double lengthMeters;

  /// Closed polygon around the band.
  final List<LatLng> outline;
}

/// The source's own width and the furthest a type's plume is drawn.
({double sourceMeters, double maxMeters})? _plumeShape(Hazard hazard) {
  final nuclear = hazard.nuclear;
  return switch (hazard.type) {
    HazardType.gasLeak => (sourceMeters: 50.0, maxMeters: 5000.0),
    HazardType.chemicalSpill => (sourceMeters: 100.0, maxMeters: 10000.0),
    HazardType.fire => (sourceMeters: 300.0, maxMeters: 30000.0),
    HazardType.radiation => (sourceMeters: 200.0, maxMeters: 50000.0),
    HazardType.volcanicAsh => (sourceMeters: 1000.0, maxMeters: 200000.0),
    // Only a ground burst throws up local fallout; an air burst's fireball
    // never touches the ground.
    HazardType.nuclearDetonation when nuclear != null && nuclear.burst == BurstType.surface => (
        sourceMeters: nuclearEffects(nuclear).first.radiusMeters * 2,
        maxMeters: 300000.0,
      ),
    _ => null,
  };
}

/// Plume bands for [hazard], smallest first; empty when the hazard doesn't
/// drift or no wind is known.
List<Plume> spreadPlumes(Hazard hazard) {
  final wind = hazard.wind;
  final shape = _plumeShape(hazard);
  if (wind == null || shape == null) return const [];
  final origin = LatLng(hazard.latitude, hazard.longitude);
  return [
    for (final hours in plumeHours)
      _plume(origin, wind, hours, shape.sourceMeters, shape.maxMeters),
  ];
}

Plume _plume(LatLng origin, Wind wind, int hours, double source, double max) {
  const distance = Distance();
  if (wind.speedKmh < _calmKmh) {
    // Calm: it creeps outward a little in every direction.
    final r = source + 300.0 * hours;
    return Plume(
      hours: hours,
      lengthMeters: r,
      outline: [for (var a = 0; a < 360; a += 15) distance.offset(origin, r, a.toDouble())],
    );
  }

  final length = math.min(wind.speedKmh * 1000 * hours, max);
  final toward = wind.towardDegrees;
  final tan = math.tan(_spreadDegrees * math.pi / 180);
  final farHalfWidth = source + length * tan;
  final tip = distance.offset(origin, length, toward);

  final outline = <LatLng>[
    // Round the upwind side of the source...
    for (var a = 90; a <= 270; a += 15) distance.offset(origin, source, toward + a),
    // ...then out to the far end, round it, and back.
    for (var a = -90; a <= 90; a += 15) distance.offset(tip, farHalfWidth, toward + a),
  ];
  return Plume(hours: hours, lengthMeters: length, outline: outline);
}

/// Circles covering a plume band, for route avoidance (the router avoids
/// circles): spaced along the axis, each as wide as the plume there.
List<({LatLng center, double radius})> plumeCircles(Hazard hazard, {int hours = 3}) {
  final wind = hazard.wind;
  final shape = _plumeShape(hazard);
  if (wind == null || shape == null || wind.speedKmh < _calmKmh) return const [];
  const distance = Distance();
  final origin = LatLng(hazard.latitude, hazard.longitude);
  final length = math.min(wind.speedKmh * 1000 * hours, shape.maxMeters);
  final tan = math.tan(_spreadDegrees * math.pi / 180);
  final circles = <({LatLng center, double radius})>[];
  var along = 0.0;
  while (along <= length) {
    final radius = shape.sourceMeters + along * tan;
    circles.add((center: distance.offset(origin, along, wind.towardDegrees), radius: radius));
    along += math.max(radius, 100);
  }
  return circles;
}
