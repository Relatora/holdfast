import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/routing/directions.dart';
import 'package:holdfast/routing/router.dart';

import 'router_test.dart' show ne, se, sw, town;

void main() {
  test('plans from the device location when it has one', () async {
    final d = Directions(loadPack: () async => town().build(), mapCenter: () => ne, locate: () async => sw);
    await d.open(to: ne, label: 'NE corner', regionId: 'town', avoid: const []);
    expect(d.fromMyLocation, isTrue);
    expect(d.plan, isNotNull);
    expect(d.plan!.steps.first.instruction, 'Head east on South St');
  });

  test('falls back to the map centre without a location', () async {
    final d = Directions(loadPack: () async => town().build(), mapCenter: () => se, locate: () async => null);
    await d.open(to: ne, label: 'NE corner', regionId: 'town', avoid: const []);
    expect(d.fromMyLocation, isFalse);
    expect(d.origin, se);
    expect(d.plan!.steps.first.instruction, 'Head north on East Ave');
  });

  test('switching mode replans, and explains a mode that cannot work here', () async {
    final d = Directions(loadPack: () async => town().build(), mapCenter: () => sw, locate: () async => sw);
    await d.open(to: ne, label: 'NE corner', regionId: 'town', avoid: const []);
    d.setMode(TravelMode.train);
    expect(d.plan, isNull);
    expect(d.error, contains('no train stations'));
    d.setMode(TravelMode.car);
    expect(d.plan?.mode, TravelMode.car);
  });

  test('a map without a routing pack says how to get directions', () async {
    final d = Directions(loadPack: () async => null, mapCenter: () => sw, locate: () async => sw);
    await d.open(to: ne, label: 'NE corner', regionId: 'ontario', avoid: const []);
    expect(d.plan, isNull);
    expect(d.error, contains('city'));
  });

  test('hazards are avoided at a radius that suits their type', () {
    expect(avoidRadiusMeters(HazardType.flood), greaterThan(avoidRadiusMeters(HazardType.roadBlocked)));
    expect(avoidRadiusMeters(HazardType.contaminatedWater), 0, reason: 'bad water does not block a road');
  });
}
