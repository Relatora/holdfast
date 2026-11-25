import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/aviation_impact.dart';
import 'package:holdfast/hazards/effects/zones.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_details.dart';
import 'package:holdfast/placement/address_search.dart';
import 'package:holdfast/placement/place_flow.dart';
import 'package:holdfast/pois/poi.dart';
import 'package:holdfast/routing/routing_graph.dart';
import 'package:latlong2/latlong.dart';

import '../routing/pack_builder.dart';

Hazard _hazard(HazardType type, {double lat = 46.20, double lon = -122.19, Map<String, Object?> details = const {}}) =>
    Hazard(
      id: type.name,
      type: type,
      severity: HazardSeverity.high,
      latitude: lat,
      longitude: lon,
      reportedBy: 'a',
      reportedAt: DateTime.utc(2026, 11, 25, 15),
      details: details,
    );

Poi _airport(String id, double lat, double lon) =>
    Poi(id: id, category: PoiCategory.airport, name: '$id airport', latitude: lat, longitude: lon);

void main() {
  group('a new type stays readable by older apps', () {
    test('volcanic eruption is geological, drifts with the wind, and old apps see "other"', () {
      expect(HazardType.volcanicEruption.category, HazardCategory.geological);
      expect(HazardType.volcanicEruption.spreadsWithWind, isTrue);
      expect(HazardType.parse('volcanicEruption'), HazardType.volcanicEruption);
      expect(HazardType.parse('somethingNewer'), HazardType.other);
    });

    test('a tsunami is placed on the map only: no street address out at sea', () {
      expect(placedByAddress(HazardType.tsunami), isFalse);
      for (final (type, _, _) in incidentChoices) {
        if (type != HazardType.tsunami) expect(placedByAddress(type), isTrue, reason: type.name);
      }
    });
  });

  group('zones', () {
    test('an eruption has a 10 km danger zone', () {
      final rings = zoneRings(_hazard(HazardType.volcanicEruption));
      expect(rings.single.radiusMeters, 10000);
      expect(rings.single.danger, isTrue);
    });

    test('tsunami rings follow the water depth: deep ocean at jet speed, a lake at a run', () {
      final deep = zoneRings(_hazard(HazardType.tsunami, details: hazardDetails(
        tsunami: const TsunamiDetails(depth: TsunamiDepth.deepOcean),
      )));
      expect([for (final r in deep) r.label], ['10 min', '30 min', '60 min', '120 min']);
      // √(9.81 × 4000) ≈ 198 m/s ≈ 713 km/h: about 119 km in 10 minutes.
      expect(deep.first.radiusMeters, closeTo(118800, 500));
      expect(TsunamiDepth.deepOcean.speedKmh, closeTo(713, 1));
      expect(TsunamiDepth.shallow.speedKmh, closeTo(80, 1));
    });

    test('a tsunami reported where waves hit has no arrival rings', () {
      expect(zoneRings(_hazard(HazardType.tsunami)), isEmpty);
    });

    test('tsunami depth survives sync, and an unknown depth is ignored', () {
      final h = _hazard(HazardType.tsunami, details: hazardDetails(tsunami: const TsunamiDetails(depth: TsunamiDepth.shelf)));
      expect(Hazard.fromJson(h.toJson()).tsunami?.depth, TsunamiDepth.shelf);
      expect(_hazard(HazardType.tsunami, details: {'tsunami': {'depth': 'abyss'}}).tsunami, isNull);
    });
  });

  group('airports a hazard is likely to close', () {
    // An eruption with wind from the west: ash drifts east at 40 km/h.
    final eruption = _hazard(HazardType.volcanicEruption, details: hazardDetails(
      wind: const Wind(fromDegrees: 270, speedKmh: 40),
    ));
    const distance = Distance();
    LatLng at(double meters, double bearing) => distance.offset(const LatLng(46.20, -122.19), meters, bearing);
    Poi airportAt(String id, double meters, double bearing) {
      final p = at(meters, bearing);
      return _airport(id, p.latitude, p.longitude);
    }

    test('in the danger zone, then by the plume band that reaches it first', () {
      final near = airportAt('near', 6000, 200);
      final ash1h = airportAt('ash1h', 30000, 90);
      final ash3h = airportAt('ash3h', 100000, 90);
      final upwind = airportAt('upwind', 40000, 270);
      final impacts = airportImpacts([eruption], [ash3h, upwind, ash1h, near]);
      expect([for (final i in impacts) (i.airport.id, i.band)], [
        ('near', AirportBand.inZone),
        ('ash1h', AirportBand.within1h),
        ('ash3h', AirportBand.within3h),
      ]);
      expect(impacts.first.consequence, contains('grounded'));
    });

    test('the nearest clear airport skips every affected one', () {
      final ash1h = airportAt('ash1h', 30000, 90);
      final ash3h = airportAt('ash3h', 60000, 90);
      final clear = airportAt('clear', 80000, 270);
      final impacts = airportImpacts([eruption], [ash1h, ash3h, clear]);
      expect(nearestClearAirport(ash1h, [ash1h, ash3h, clear], impacts)?.id, 'clear');
      expect(nearestClearAirport(ash1h, [ash1h, ash3h], impacts), isNull);
    });

    test('a tsunami flags airports its first wave reaches within two hours', () {
      final tsunami = _hazard(HazardType.tsunami, details: hazardDetails(
        tsunami: const TsunamiDetails(depth: TsunamiDepth.deepOcean),
      ));
      final impacts = airportImpacts([tsunami], [airportAt('coast', 300000, 90), airportAt('far', 2000000, 90)]);
      expect(impacts.single.airport.id, 'coast');
      expect(impacts.single.minutes, closeTo(26, 1));
    });

    test('hazards that never stop flights flag nothing', () {
      expect(airportImpacts([_hazard(HazardType.roadBlocked)], [airportAt('a', 100, 0)]), isEmpty);
    });

    test('point in polygon', () {
      const square = [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1), LatLng(1, 0)];
      expect(pointInPolygon(const LatLng(0.5, 0.5), square), isTrue);
      expect(pointInPolygon(const LatLng(1.5, 0.5), square), isFalse);
    });
  });

  group('address search', () {
    test('abbreviations and punctuation are spelled out', () {
      expect(normalizeWords('Main St.'), ['main', 'street']);
      expect(normalizeWords("St. Clair Pkwy"), ['street', 'clair', 'parkway']);
      expect(wordsMatch(normalizeWords('2nd ave'), normalizeWords('2nd Avenue')), isTrue);
      expect(wordsMatch(normalizeWords('mai'), normalizeWords('Main Street')), isTrue);
      expect(wordsMatch(normalizeWords('elm'), normalizeWords('Main Street')), isFalse);
    });

    // A little grid: Main Street runs east-west, crossed by 2nd Avenue and
    // Elm Road; a second, far-off stretch of Main Street to the east.
    RoutingGraph town() {
      final b = PackBuilder();
      final a = b.vertex(42.970, -82.410), c = b.vertex(42.970, -82.400), d = b.vertex(42.970, -82.390);
      final north = b.vertex(42.975, -82.400), south = b.vertex(42.965, -82.400);
      final elmN = b.vertex(42.975, -82.390);
      final farA = b.vertex(42.970, -82.200), farB = b.vertex(42.970, -82.190);
      b.edge(a, c, name: 'Main Street');
      b.edge(c, d, name: 'Main Street');
      b.edge(farA, farB, name: 'Main Street');
      b.edge(north, c, name: '2nd Avenue');
      b.edge(c, south, name: '2nd Avenue');
      b.edge(d, elmN, name: 'Elm Road');
      return RoutingGraph.decode(b.build());
    }

    test('a street is found where you are looking, not at one end', () {
      final index = StreetIndex(town());
      final near = index.streets('main st', near: const LatLng(42.971, -82.405)).single;
      expect(near.title, 'Main Street');
      expect(near.point.longitude, closeTo(-82.40, 0.011));
      final far = index.streets('main st', near: const LatLng(42.97, -82.19)).single;
      expect(far.point.longitude, closeTo(-82.19, 0.011));
    });

    test('a house number is set aside offline, and says why', () {
      final result = StreetIndex(town()).streets('123 Main St', near: const LatLng(42.97, -82.40)).single;
      expect(result.title, 'Main Street');
      expect(result.subtitle, contains('need a connection'));
    });

    test('crossings: "&", "and" and "at" all work', () {
      final index = StreetIndex(town());
      for (final q in ['Main St & 2nd Ave', 'main and 2nd', 'Main at 2nd', 'elm & main']) {
        final results = index.crossings(q, near: const LatLng(42.97, -82.40));
        expect(results, isNotEmpty, reason: q);
        expect(results.first.source, AddressSource.crossing);
      }
      expect(index.crossings('Main & 2nd', near: const LatLng(42.97, -82.40)).first.point,
          const LatLng(42.970, -82.400));
      expect(index.crossings('2nd & Elm', near: const LatLng(42.97, -82.40)), isEmpty, reason: 'they never meet');
    });

    test('named places and their addresses', () {
      const pois = [
        Poi(id: '1', category: PoiCategory.medical, name: 'Bluewater Health', latitude: 42.97, longitude: -82.40,
            tags: {'addr:street': 'Mitton Street', 'addr:housenumber': '89'}),
        Poi(id: '2', category: PoiCategory.grocery, name: 'Corner Store', latitude: 42.96, longitude: -82.41),
      ];
      expect(placeResults(pois, 'bluewater', near: const LatLng(42.97, -82.40)).single.title, 'Bluewater Health');
      expect(placeResults(pois, 'mitton st', near: const LatLng(42.97, -82.40)).single.subtitle, contains('89 Mitton'));
    });

    test("Photon's answers become results; odd features are skipped", () {
      final results = parsePhoton({
        'features': [
          {
            'geometry': {'coordinates': [-82.4066, 42.9745]},
            'properties': {'housenumber': '123', 'street': 'Front Street North', 'city': 'Sarnia', 'country': 'Canada'},
          },
          {
            'geometry': {'coordinates': [-91.2447, 40.7906]},
            'properties': {'name': 'Iowa Army Ammunition Plant', 'city': 'Middletown', 'state': 'Iowa'},
          },
          {'geometry': {'coordinates': 'nowhere'}, 'properties': {'name': 'Broken'}},
          {'geometry': {'coordinates': [0, 0]}, 'properties': <String, Object?>{}},
        ],
      });
      expect([for (final r in results) r.title], ['123 Front Street North', 'Iowa Army Ammunition Plant']);
      expect(results.first.subtitle, 'Sarnia, Canada');
      expect(results.first.point, const LatLng(42.9745, -82.4066));
      expect(results.last.source, AddressSource.online);
      expect(parsePhoton('not json'), isEmpty);
    });
  });
}
