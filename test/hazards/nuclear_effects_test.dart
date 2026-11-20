import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/effects/nuclear_effects.dart';
import 'package:holdfast/hazards/hazard_details.dart';

double radius(List<EffectRing> rings, RingKind kind) => rings.firstWhere((r) => r.kind == kind).radiusMeters;

void main() {
  group('ring distances match published figures', () {
    // Reference values: Glasstone & Dolan scaling as used by civil defence
    // tables; tolerances are generous, these are planning numbers.
    test('15 kt air burst (Hiroshima-class)', () {
      final rings = nuclearEffects(const NuclearDetails(yieldKt: 15));
      expect(radius(rings, RingKind.moderateBlast), closeTo(1730, 150), reason: '5 psi ≈ 1.7 km');
      expect(radius(rings, RingKind.fireball), closeTo(130, 30));
      expect(radius(rings, RingKind.thermal), closeTo(1820, 250));
      expect(radius(rings, RingKind.radiation), closeTo(1170, 150));
    });

    test('1 Mt air burst', () {
      final rings = nuclearEffects(const NuclearDetails(yieldKt: 1000));
      expect(radius(rings, RingKind.moderateBlast), closeTo(7000, 300), reason: '5 psi ≈ 7 km');
      expect(radius(rings, RingKind.thermal), closeTo(10200, 1000), reason: 'burns ≈ 10 km');
      expect(radius(rings, RingKind.radiation), closeTo(2600, 300), reason: '500 rem ≈ 2.6 km');
    });

    test('effects grow with yield, and a ground burst trades blast reach for fallout', () {
      final small = nuclearEffects(const NuclearDetails(yieldKt: 15));
      final big = nuclearEffects(const NuclearDetails(yieldKt: 300));
      for (final kind in RingKind.values) {
        expect(radius(big, kind), greaterThan(radius(small, kind)), reason: kind.name);
      }
      final ground = nuclearEffects(const NuclearDetails(yieldKt: 15, burst: BurstType.surface));
      expect(radius(ground, RingKind.moderateBlast), lessThan(radius(small, RingKind.moderateBlast)));
      expect(radius(ground, RingKind.fireball), greaterThan(radius(small, RingKind.fireball)));
    });

    test('rings come back smallest first, and every ring explains what still works', () {
      final rings = nuclearEffects(const NuclearDetails(yieldKt: 100));
      for (var i = 1; i < rings.length; i++) {
        expect(rings[i].radiusMeters, greaterThanOrEqualTo(rings[i - 1].radiusMeters));
      }
      expect(rings.every((r) => r.functionalStatus.isNotEmpty && r.buildingEffect.isNotEmpty), isTrue);
    });
  });

  group('casualty estimates', () {
    // Uniform density: people within r = density × π r².
    double Function(double) uniform(double perKm2) => (r) => perKm2 * 3.14159265 * (r / 1000) * (r / 1000);

    test('each person is counted once, at the most lethal rate that reaches them', () {
      final rings = nuclearEffects(const NuclearDetails(yieldKt: 15));
      final total = uniform(1000)(radius(rings, RingKind.lightBlast));
      final result = estimateCasualties(rings, uniform(1000));
      expect(result.deaths + result.injured, lessThanOrEqualTo(total));
      // Deaths are bounded by "everyone inside the 5 psi ring" and by "half
      // of everyone in the 1 psi ring".
      expect(result.deaths, lessThan(uniform(1000)(radius(rings, RingKind.thermal))));
      expect(result.deaths, greaterThan(0.3 * uniform(1000)(radius(rings, RingKind.moderateBlast))));
    });

    test('for a megaton weapon the 20 psi rate wins inside the radiation ring', () {
      final rings = nuclearEffects(const NuclearDetails(yieldKt: 1000));
      expect(radius(rings, RingKind.radiation), lessThan(radius(rings, RingKind.heavyBlast)));
      // Everyone inside the 20 psi ring dies at ≥ 98%, so people there are
      // never counted at the radiation ring's lower rate.
      final heavy = radius(rings, RingKind.heavyBlast);
      final onlyInner = estimateCasualties(rings, (r) => r <= heavy ? uniform(1000)(r) : uniform(1000)(heavy));
      expect(onlyInner.deaths, closeTo(0.98 * uniform(1000)(heavy), uniform(1000)(heavy) * 0.03));
    });

    test('nobody there, nobody hurt', () {
      final result = estimateCasualties(nuclearEffects(const NuclearDetails(yieldKt: 15)), (_) => 0);
      expect(result.deaths, 0);
      expect(result.injured, 0);
    });
  });
}
