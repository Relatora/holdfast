import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/effects/spread.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_details.dart';
import 'package:holdfast/hazards/wind_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

Hazard _hazard(HazardType type, {Wind? wind, NuclearDetails? nuclear}) => Hazard(
      id: 'h',
      type: type,
      severity: HazardSeverity.high,
      latitude: 45.42,
      longitude: -75.69,
      reportedBy: 'a',
      reportedAt: DateTime.utc(2026, 11, 20),
      details: hazardDetails(wind: wind, nuclear: nuclear),
    );

void main() {
  const distance = Distance();
  const origin = LatLng(45.42, -75.69);
  const westWind = Wind(fromDegrees: 270, speedKmh: 10); // carries things east

  test('a plume points downwind, in 1, 3 and 6 hour bands that grow', () {
    final plumes = spreadPlumes(_hazard(HazardType.radiation, wind: westWind));
    expect(plumes.map((p) => p.hours), [1, 3, 6]);
    expect(plumes.map((p) => p.lengthMeters), [10000, 30000, 50000], reason: 'capped at 50 km for radiation');
    // The far end is east of the source, not west.
    final farthest = plumes.last.outline.reduce((a, b) => a.longitude > b.longitude ? a : b);
    expect(farthest.longitude, greaterThan(origin.longitude));
    expect(distance.bearing(origin, farthest), closeTo(90, 25));
  });

  test('a stronger wind carries it further', () {
    final slow = spreadPlumes(_hazard(HazardType.fire, wind: westWind)).first;
    final fast = spreadPlumes(_hazard(HazardType.fire, wind: const Wind(fromDegrees: 270, speedKmh: 25))).first;
    expect(fast.lengthMeters, greaterThan(slow.lengthMeters));
  });

  test('calm air spreads evenly in a small circle', () {
    final plume = spreadPlumes(_hazard(HazardType.gasLeak, wind: const Wind(fromDegrees: 0, speedKmh: 1))).first;
    final distances = plume.outline.map((p) => distance(origin, p)).toList();
    final spread = distances.reduce((a, b) => a > b ? a : b) - distances.reduce((a, b) => a < b ? a : b);
    expect(spread, lessThan(20), reason: 'every point the same distance away');
  });

  test('no plume without wind, for hazards that do not drift, or for an air burst', () {
    expect(spreadPlumes(_hazard(HazardType.radiation)), isEmpty);
    expect(spreadPlumes(_hazard(HazardType.flood, wind: westWind)), isEmpty);
    expect(spreadPlumes(_hazard(HazardType.nuclearDetonation, wind: westWind, nuclear: const NuclearDetails(yieldKt: 15))),
        isEmpty, reason: 'an air burst makes little local fallout');
    expect(
      spreadPlumes(_hazard(HazardType.nuclearDetonation,
          wind: westWind, nuclear: const NuclearDetails(yieldKt: 15, burst: BurstType.surface))),
      hasLength(3),
    );
  });

  test('route avoidance circles cover the 3 hour plume from source to end', () {
    final circles = plumeCircles(_hazard(HazardType.chemicalSpill, wind: westWind));
    expect(circles, isNotEmpty);
    expect(distance(origin, circles.first.center), lessThan(1));
    final last = circles.last;
    expect(distance(origin, last.center) + last.radius, greaterThanOrEqualTo(9000), reason: '10 km cap, 3 h at 10 km/h');
  });

  group('Open-Meteo wind', () {
    test('parses the current wind', () async {
      final service = WindService(client: MockClient((request) async {
        expect(request.url.host, 'api.open-meteo.com');
        expect(request.url.queryParameters['latitude'], '45.4200');
        return http.Response('{"current":{"wind_speed_10m":10.6,"wind_direction_10m":274}}', 200);
      }));
      final wind = await service.current(45.42, -75.69);
      expect(wind?.speedKmh, 10.6);
      expect(wind?.fromDegrees, 274);
      expect(wind?.source, WindSource.forecast);
    });

    test('offline or broken answers give null, never an exception', () async {
      final offline = WindService(client: MockClient((_) async => throw http.ClientException('offline')));
      expect(await offline.current(45, -75), isNull);
      final broken = WindService(client: MockClient((_) async => http.Response('{"oops":1}', 200)));
      expect(await broken.current(45, -75), isNull);
    });
  });
}
