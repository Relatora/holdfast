import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/aviation_impact.dart' show pointInPolygon;
import 'package:holdfast/hazards/effects/spread.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_details.dart';
import 'package:holdfast/map/effects/effects_layer.dart' show hasEffects;
import 'package:holdfast/map/effects/effects_model.dart';
import 'package:latlong2/latlong.dart';

Hazard _hazard(HazardType type, {Wind? wind, TsunamiDetails? tsunami}) => Hazard(
      id: 'h-${type.name}',
      type: type,
      severity: HazardSeverity.high,
      latitude: 42.97,
      longitude: -82.40,
      reportedBy: 'a',
      reportedAt: DateTime.utc(2026, 11, 25, 15),
      details: hazardDetails(wind: wind, tsunami: tsunami),
    );

void main() {
  const breeze = Wind(fromDegrees: 21, speedKmh: 13.6);

  test('every mote stays inside the plume the map draws', () {
    for (final type in [HazardType.chemicalSpill, HazardType.leadDust, HazardType.volcanicEruption, HazardType.fire]) {
      final hazard = _hazard(type, wind: breeze);
      final band = spreadPlumes(hazard).last; // the 6 h band
      for (final t in [0.0, 1.3, 7.7, 120.0]) {
        for (final mote in plumeMotes(hazard, t, count: 80)) {
          expect(pointInPolygon(mote.at, band.outline), isTrue, reason: '$type at ${t}s');
          expect(mote.opacity, inInclusiveRange(0, 1));
        }
      }
    }
  });

  test('motes move downwind, and the same moment is always the same frame', () {
    final hazard = _hazard(HazardType.chemicalSpill, wind: const Wind(fromDegrees: 270, speedKmh: 20));
    final a = plumeMotes(hazard, 2.0, count: 10), b = plumeMotes(hazard, 2.0, count: 10);
    expect([for (final m in a) m.at], [for (final m in b) m.at]);
    // Wind from the west carries east: longitude grows for a mote that
    // hasn't wrapped back to the source.
    final later = plumeMotes(hazard, 2.2, count: 10);
    final moved = [for (var i = 0; i < 10; i++) later[i].at.longitude - a[i].at.longitude];
    expect(moved.where((d) => d > 0).length, greaterThanOrEqualTo(8));
  });

  test('lead settles out early; smoke swells as it drifts', () {
    final lead = plumeMotes(_hazard(HazardType.leadDust, wind: breeze), 3, count: 200);
    expect(lead.where((m) => m.opacity == 0), isNotEmpty, reason: 'motes past 70 % are gone');
    final smoke = plumeMotes(_hazard(HazardType.fire, wind: breeze), 3, count: 200);
    expect(smoke.map((m) => m.size).reduce((a, b) => a > b ? a : b), greaterThan(1.3));
  });

  test('no wind, no motes or streaks; calm air has no direction to show', () {
    expect(plumeMotes(_hazard(HazardType.chemicalSpill), 1), isEmpty);
    expect(windStreaks(_hazard(HazardType.chemicalSpill, wind: const Wind(fromDegrees: 0, speedKmh: 1)), 1), isEmpty);
    expect(windStreaks(_hazard(HazardType.fire, wind: breeze), 1), hasLength(24));
  });

  test('a window keeps every mote in the stretch on screen', () {
    final hazard = _hazard(HazardType.leadDust, wind: const Wind(fromDegrees: 270, speedKmh: 20));
    const distance = Distance();
    for (final t in [0.0, 4.0, 11.0]) {
      final motes = plumeMotes(hazard, t, count: 50, window: (from: 2000, to: 5000));
      expect(motes, hasLength(50));
      for (final m in motes) {
        // East of the source by 2-5 km, give or take the plume's sideways spread.
        final east = distance.as(LengthUnit.Meter, const LatLng(42.97, -82.40), LatLng(42.97, m.at.longitude));
        expect(east, inInclusiveRange(1900, 5100));
      }
    }
    expect(plumeMotes(hazard, 1, window: (from: 200000, to: 300000)), isEmpty, reason: 'past the far end');
  });

  test('a stronger wind crosses the plume faster', () {
    expect(crossingSeconds(5), greaterThan(crossingSeconds(50)));
    expect(crossingSeconds(0), 14);
    expect(crossingSeconds(200), 6);
  });

  test('tsunami fronts run out to the 120-minute ring and fade as they go', () {
    final hazard = _hazard(HazardType.tsunami, tsunami: const TsunamiDetails(depth: TsunamiDepth.shelf));
    final reach = const TsunamiDetails(depth: TsunamiDepth.shelf).reachMeters(120);
    for (final t in [0.0, 2.5, 8.9, 31.0]) {
      final fronts = tsunamiFronts(hazard, t);
      expect(fronts, hasLength(3));
      for (final f in fronts) {
        expect(f.radiusMeters, inInclusiveRange(0, reach));
      }
      // The furthest front is the faintest.
      final sorted = [...fronts]..sort((a, b) => a.radiusMeters.compareTo(b.radiusMeters));
      expect(sorted.first.opacity, greaterThanOrEqualTo(sorted.last.opacity));
    }
    expect(tsunamiFronts(_hazard(HazardType.tsunami), 1), isEmpty, reason: 'reported where waves hit');
  });

  test('only hazards that move get the animation layer', () {
    expect(hasEffects(_hazard(HazardType.roadBlocked)), isFalse);
    expect(hasEffects(_hazard(HazardType.chemicalSpill)), isFalse, reason: 'no wind yet');
    expect(hasEffects(_hazard(HazardType.chemicalSpill, wind: breeze)), isTrue);
    expect(hasEffects(_hazard(HazardType.volcanicEruption)), isTrue, reason: 'the vent moves even without wind');
    expect(hasEffects(_hazard(HazardType.radiation)), isTrue);
  });
}
