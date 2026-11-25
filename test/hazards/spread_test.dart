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

  group('lead dust', () {
    test('settles out along a long path, capped at 60 km', () {
      // From the Army's map for the 2026 Iowa detonation: deposits about
      // 40 miles (64 km) downwind.
      final plumes = spreadPlumes(_hazard(HazardType.leadDust, wind: const Wind(fromDegrees: 45, speedKmh: 15)));
      expect(plumes.map((p) => p.lengthMeters), [15000, 45000, 60000]);
      final far = plumes.last.outline.reduce((a, b) => a.latitude < b.latitude ? a : b);
      expect(far.latitude, lessThan(origin.latitude), reason: 'a NE wind carries it south-west');
      expect(far.longitude, lessThan(origin.longitude));
    });

    test('drifts with the wind, and is avoided along its plume', () {
      expect(HazardType.leadDust.spreadsWithWind, isTrue);
      expect(plumeCircles(_hazard(HazardType.leadDust, wind: westWind)), isNotEmpty);
    });
  });

  group('planned releases', () {
    Hazard planned(Object? startsAt) => Hazard(
          id: 'p',
          type: HazardType.leadDust,
          severity: HazardSeverity.high,
          latitude: 40.80,
          longitude: -91.26,
          reportedBy: 'a',
          reportedAt: DateTime.utc(2026, 11, 24),
          details: {'startsAt': startsAt},
        );

    test('the time round-trips through the report payload', () {
      final at = DateTime.utc(2026, 11, 25, 15);
      final details = hazardDetails(startsAt: at, wind: westWind);
      final hazard = Hazard.fromJson(planned(details['startsAt']).toJson());
      expect(hazard.startsAt, at);
      expect(hazard.plannedAt(DateTime.utc(2026, 11, 25, 14)), isTrue);
      expect(hazard.plannedAt(DateTime.utc(2026, 11, 25, 16)), isFalse, reason: 'it has happened');
    });

    test('a missing or unreadable time means "happening now"', () {
      expect(planned(null).startsAt, isNull);
      expect(planned('next Tuesday').startsAt, isNull);
      expect(planned(42).startsAt, isNull);
      expect(planned('next Tuesday').plannedAt(DateTime.utc(2026)), isFalse);
      expect(hazardDetails(wind: westWind).containsKey('startsAt'), isFalse);
    });

    test('forecastAt picks the forecast hour nearest the planned time', () async {
      Uri? asked;
      final service = WindService(client: MockClient((request) async {
        asked = request.url;
        return http.Response(
          '{"hourly":{"time":["2026-11-25T14:00","2026-11-25T15:00","2026-11-25T16:00"],'
          '"wind_speed_10m":[10,22,30],"wind_direction_10m":[0,45,90]}}',
          200,
        );
      }));
      // 09:20 in Iowa (CST, UTC-6) is 15:20 UTC: the 15:00 hour.
      final wind = await service.forecastAt(40.80, -91.26, DateTime.utc(2026, 11, 25, 15, 20));
      expect(wind!.fromDegrees, 45);
      expect(wind.speedKmh, 22);
      expect(wind.source, WindSource.forecast);
      expect(asked!.queryParameters['hourly'], 'wind_speed_10m,wind_direction_10m');
      expect(asked!.queryParameters['timezone'], 'GMT');
    });

    test('forecastAt says nothing for a time outside the forecast, or offline', () async {
      final service = WindService(client: MockClient((_) async => http.Response(
            '{"hourly":{"time":["2026-11-25T14:00"],"wind_speed_10m":[10],"wind_direction_10m":[0]}}',
            200,
          )));
      expect(await service.forecastAt(0, 0, DateTime.utc(2026, 12, 20)), isNull);
      final offline = WindService(client: MockClient((_) async => throw http.ClientException('offline')));
      expect(await offline.forecastAt(0, 0, DateTime.utc(2026, 11, 25, 14)), isNull);
    });
  });
}
