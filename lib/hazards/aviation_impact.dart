/// Which airports a hazard is likely to shut, and how soon.
///
/// Airports matter in an emergency because airlifts, medical flights and
/// supply drops land there once roads are cut; a field under an ash cloud
/// is no use to any of them. For each live hazard that can stop flights,
/// the downloaded airports inside its zone are flagged with the earliest
/// band that reaches them:
///
/// * Volcanic ash and eruptions: aviation rules are to avoid any visible
///   ash (it melts in jet engines and sandblasts windscreens), so every
///   plume band counts, and the eruption's danger zone.
/// * Nuclear detonations and radiation: the effect rings and the fallout
///   plume.
/// * Wildfires: the smoke plume, which cuts visibility.
/// * Tsunamis: airports the first wave can reach within two hours, which
///   matters only for fields on the coast (the app can't tell which are).
///
/// Plain geometry over the same plumes and rings the map draws, so the list
/// always agrees with the picture.
library;

import 'package:latlong2/latlong.dart';

import '../pois/poi.dart';
import 'effects/nuclear_effects.dart';
import 'effects/spread.dart';
import 'effects/zones.dart';
import 'hazard.dart';
import 'hazard_details.dart';

/// How soon a hazard reaches an airport, most urgent first.
enum AirportBand {
  inZone('In the danger zone'),
  within1h('Within 1 hour'),
  within3h('Within 3 hours'),
  within6h('Within 6 hours'),
  wavesSoon('Waves within 2 hours, if on the coast');

  const AirportBand(this.label);
  final String label;
}

class AirportImpact {
  const AirportImpact({required this.airport, required this.hazard, required this.band, this.minutes});

  final Poi airport;
  final Hazard hazard;
  final AirportBand band;

  /// For a tsunami: minutes until the first wave could reach it.
  final int? minutes;

  /// What it means for flights, for the airport's sheet.
  String get consequence => switch (hazard.type) {
        HazardType.volcanicAsh || HazardType.volcanicEruption =>
          'Ash ${band == AirportBand.inZone ? 'over' : 'forecast over'} this airport: flights are likely grounded.',
        HazardType.nuclearDetonation || HazardType.radiation =>
          'Fallout or blast reaches this airport: expect it to close.',
        HazardType.fire => 'Smoke over this airport: low visibility may stop flights.',
        HazardType.tsunami => 'If this airport is on the coast, the first wave could reach it in about $minutes min.',
        _ => 'This hazard may close the airport.',
      };
}

/// Hazards that can stop flights.
bool affectsFlights(HazardType type) => switch (type) {
      HazardType.volcanicAsh ||
      HazardType.volcanicEruption ||
      HazardType.nuclearDetonation ||
      HazardType.radiation ||
      HazardType.fire ||
      HazardType.tsunami =>
        true,
      _ => false,
    };

/// Every airport in [airports] that a hazard in [hazards] is likely to
/// affect, most urgent first. An airport hit by several hazards is listed
/// once per hazard.
List<AirportImpact> airportImpacts(Iterable<Hazard> hazards, Iterable<Poi> airports) {
  final fields = [for (final a in airports) if (a.category == PoiCategory.airport) a];
  if (fields.isEmpty) return const [];
  final impacts = <AirportImpact>[];
  for (final hazard in hazards) {
    if (!affectsFlights(hazard.type)) continue;
    for (final airport in fields) {
      if (impactOn(hazard, airport) case final impact?) impacts.add(impact);
    }
  }
  impacts.sort((a, b) => a.band.index.compareTo(b.band.index));
  return impacts;
}

/// How [hazard] affects [airport], or null when it doesn't.
AirportImpact? impactOn(Hazard hazard, Poi airport) {
  final at = LatLng(airport.latitude, airport.longitude);
  final meters = distanceMeters(hazard.latitude, hazard.longitude, airport.latitude, airport.longitude);

  // Tsunamis: by arrival time of the first wave.
  if (hazard.type == HazardType.tsunami) {
    final tsunami = hazard.tsunami;
    if (tsunami == null) return null;
    final minutes = tsunamiMinutesTo(tsunami, meters);
    if (minutes > 120) return null;
    return AirportImpact(airport: airport, hazard: hazard, band: AirportBand.wavesSoon, minutes: minutes);
  }

  // Fixed zones: an eruption's danger zone, a detonation's rings.
  final zone = switch (hazard.type) {
    HazardType.volcanicEruption => eruptionDangerMeters,
    HazardType.nuclearDetonation => switch (hazard.nuclear) {
        final nuclear? => nuclearEffects(nuclear).map((r) => r.radiusMeters).fold(0.0, (a, b) => a > b ? a : b),
        null => 0.0,
      },
    _ => 0.0,
  };
  if (meters <= zone) return AirportImpact(airport: airport, hazard: hazard, band: AirportBand.inZone);

  // Plume bands, nearest first.
  for (final plume in spreadPlumes(hazard)) {
    if (pointInPolygon(at, plume.outline)) {
      final band = switch (plume.hours) {
        1 => AirportBand.within1h,
        3 => AirportBand.within3h,
        _ => AirportBand.within6h,
      };
      return AirportImpact(airport: airport, hazard: hazard, band: band);
    }
  }
  return null;
}

/// The nearest airport not in [impacts], for "airlifts may need another
/// field". Null when every known airport is affected.
Poi? nearestClearAirport(Poi from, Iterable<Poi> airports, Iterable<AirportImpact> impacts) {
  final affected = {for (final i in impacts) i.airport.id};
  Poi? best;
  var bestMeters = double.infinity;
  for (final a in airports) {
    if (a.category != PoiCategory.airport || a.id == from.id || affected.contains(a.id)) continue;
    final m = distanceMeters(from.latitude, from.longitude, a.latitude, a.longitude);
    if (m < bestMeters) {
      best = a;
      bestMeters = m;
    }
  }
  return best;
}

/// Ray casting in plain latitude and longitude: accurate enough for plumes
/// a few hundred kilometres long away from the poles.
bool pointInPolygon(LatLng p, List<LatLng> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i], b = polygon[j];
    if ((a.latitude > p.latitude) != (b.latitude > p.latitude) &&
        p.longitude <
            (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude) {
      inside = !inside;
    }
  }
  return inside;
}
