/// Fixed-distance zones around a hazard that aren't carried by the wind:
/// the danger zone around an erupting volcano, and how far a tsunami's
/// first wave has travelled after 10, 30, 60 and 120 minutes.
///
/// Plain Dart. Like the plumes, these are rough guides and the sheets say
/// so: real volcanic hazard zones follow valleys, and real tsunamis slow,
/// bend and pile up over the sea floor.
library;

import '../hazard.dart';
import '../hazard_details.dart';

/// One ring around a hazard.
class ZoneRing {
  const ZoneRing({required this.radiusMeters, required this.label, this.danger = false});

  final double radiusMeters;

  /// Shown on the ring: "10 min", "Danger zone".
  final String label;

  /// Stay out: drawn solid and avoided by directions.
  final bool danger;
}

/// Around an erupting vent, falling rock and pyroclastic flows (fast
/// avalanches of hot gas and ash) are the deadly threat. Most deaths in
/// eruptions happen within 10 km, the radius many volcano observatories
/// use for their first exclusion zone.
const eruptionDangerMeters = 10000.0;

/// The rings of [hazard], smallest first; empty for types without any.
List<ZoneRing> zoneRings(Hazard hazard) {
  switch (hazard.type) {
    case HazardType.volcanicEruption:
      return const [ZoneRing(radiusMeters: eruptionDangerMeters, label: 'Danger zone: 10 km', danger: true)];
    case HazardType.tsunami:
      final tsunami = hazard.tsunami;
      if (tsunami == null) return const [];
      return [
        for (final minutes in TsunamiDetails.ringMinutes)
          ZoneRing(radiusMeters: tsunami.reachMeters(minutes), label: '$minutes min'),
      ];
    default:
      return const [];
  }
}

/// Minutes until a tsunami's first wave covers [meters] from its origin,
/// rounded up. A rough guide: the wave slows as the water shallows.
int tsunamiMinutesTo(TsunamiDetails tsunami, double meters) =>
    (meters / tsunami.depth.speedMetersPerSecond / 60).ceil();
