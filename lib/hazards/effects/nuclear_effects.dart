/// How far a nuclear detonation's effects reach, from its yield.
///
/// Plain Dart. These are the standard, published scaling laws used by civil
/// defence planners and educational tools (e.g. NUKEMAP):
///
/// * Effect distances come from Glasstone & Dolan, *The Effects of Nuclear
///   Weapons*, 3rd ed. (US DoD/DoE, 1977, public domain). A reference
///   distance at 1 kt is scaled to yield W (kt) by a power law:
///   blast overpressure ∝ W^(1/3) ("cube-root scaling"), fireball ∝ W^0.4,
///   thermal (burn) range ∝ W^0.41, initial radiation ∝ W^0.19.
/// * Casualty rates per zone follow the US Office of Technology Assessment,
///   *The Effects of Nuclear War* (1979), e.g. 5–12 psi ≈ 50% killed, 40%
///   injured.
///
/// The result is a planning estimate: it ignores terrain, weather, warning
/// time and shelter, and fallout (drawn separately, downwind). The UI
/// says so wherever it shows these numbers.
library;

import 'dart:math' as math;

import '../hazard_details.dart';

/// One ring of effect around ground zero.
class EffectRing {
  const EffectRing({
    required this.kind,
    required this.radiusMeters,
    required this.title,
    required this.fatalShare,
    required this.injuredShare,
    required this.humanEffect,
    required this.buildingEffect,
    required this.functionalStatus,
  });

  final RingKind kind;
  final double radiusMeters;
  final String title;

  /// Expected share of people in this zone (beyond the next ring in) who die
  /// or are injured. Used for the human-impact view and casualty estimates.
  final double fatalShare, injuredShare;

  /// What happens to people here.
  final String humanEffect;

  /// What happens to buildings here.
  final String buildingEffect;

  /// What still works here: hospitals, roads, power, water, phones.
  final String functionalStatus;
}

/// The effects drawn, innermost first in severity.
enum RingKind {
  fireball,
  heavyBlast, // 20 psi
  radiation, // 500 rem initial dose
  moderateBlast, // 5 psi
  thermal, // third-degree burns
  lightBlast; // 1 psi

  /// Whether this ring is part of the building-damage view (blast and
  /// fireball) or only the human-impact view.
  bool get damagesBuildings => this != radiation && this != thermal;
}

/// Reference distances at 1 kt, in metres, for an air burst at the height
/// that maximises the 5 psi area ("optimum height of burst"). Chosen so the
/// scaled results match published figures: 1 Mt → 5 psi ≈ 7 km, 3rd-degree
/// burns ≈ 10 km, 500 rem ≈ 2.6 km; 15 kt (Hiroshima) → 5 psi ≈ 1.7 km.
abstract final class _At1kt {
  static const fireballAir = 44.0; // Glasstone: R = 145 ft × W^0.4
  static const psi20 = 270.0;
  static const psi5 = 700.0;
  static const psi1 = 1860.0;
  static const thermal3rd = 600.0;
  static const rem500 = 700.0;
}

/// The rings for [details], largest last.
List<EffectRing> nuclearEffects(NuclearDetails details) {
  final w = details.yieldKt;
  final ground = details.burst == BurstType.surface;
  double blast(double at1kt) => at1kt * math.pow(w, 1 / 3);

  // A ground burst spends much of its energy on the ground: a bigger
  // fireball (it touches the surface), but the lower-pressure rings reach
  // about three quarters as far, and less heat escapes to burn people.
  final fireball = _At1kt.fireballAir * math.pow(w, 0.4) * (ground ? 1.3 : 1.0);
  final heavy = blast(_At1kt.psi20) * (ground ? 0.9 : 1.0);
  final moderate = blast(_At1kt.psi5) * (ground ? 0.75 : 1.0);
  final light = blast(_At1kt.psi1) * (ground ? 0.75 : 1.0);
  final thermal = _At1kt.thermal3rd * math.pow(w, 0.41) * (ground ? 0.85 : 1.0);
  final radiation = _At1kt.rem500 * math.pow(w, 0.19);

  return [
    EffectRing(
      kind: RingKind.fireball,
      radiusMeters: fireball,
      title: 'Fireball',
      fatalShare: 1.0,
      injuredShare: 0.0,
      humanEffect: 'No one survives.',
      buildingEffect: 'Everything is vaporised or destroyed.',
      functionalStatus: 'Nothing functions.',
    ),
    EffectRing(
      kind: RingKind.heavyBlast,
      radiusMeters: heavy,
      title: 'Heavy blast (20 psi)',
      fatalShare: 0.98,
      injuredShare: 0.02,
      humanEffect: 'Nearly everyone is killed.',
      buildingEffect: 'Even reinforced concrete buildings are destroyed.',
      functionalStatus:
          'Roads buried in rubble. No power, water, gas or phones. No hospital can operate.',
    ),
    EffectRing(
      kind: RingKind.radiation,
      radiusMeters: radiation,
      title: 'Radiation (500 rem)',
      fatalShare: 0.7,
      injuredShare: 0.3,
      humanEffect: 'A lethal dose for most people in the open: half or more die within weeks without care.',
      buildingEffect: 'Buildings are not damaged by radiation itself.',
      functionalStatus: 'Survivors need urgent medical care that will not be available nearby.',
    ),
    EffectRing(
      kind: RingKind.moderateBlast,
      radiusMeters: moderate,
      title: 'Moderate blast (5 psi)',
      fatalShare: 0.5,
      injuredShare: 0.4,
      humanEffect: 'About half are killed, most others injured.',
      buildingEffect: 'Most homes collapse. Fires spread widely.',
      functionalStatus:
          'Roads blocked by debris. Power, water and phone networks down. Hospitals destroyed or unusable.',
    ),
    EffectRing(
      kind: RingKind.thermal,
      radiusMeters: thermal,
      title: 'Third-degree burns',
      fatalShare: 0.25,
      injuredShare: 0.5,
      humanEffect: 'Severe burns on exposed skin. Many burned people die without specialist care.',
      buildingEffect: 'Paper, fabric and dry wood catch fire.',
      functionalStatus: 'Burn care needs far beyond any local capacity.',
    ),
    EffectRing(
      kind: RingKind.lightBlast,
      radiusMeters: light,
      title: 'Light blast (1 psi)',
      fatalShare: 0.01,
      injuredShare: 0.25,
      humanEffect: 'Injuries mostly from flying glass and debris.',
      buildingEffect: 'Windows shatter. Light damage to homes.',
      functionalStatus:
          'Most roads passable. Power and phones likely out. Hospitals overwhelmed with the injured.',
    ),
  ]..sort((a, b) => a.radiusMeters.compareTo(b.radiusMeters));
}

/// Estimated deaths and injuries, summed zone by zone.
///
/// [peopleWithin] counts people inside a circle of the given radius around
/// ground zero (from a population grid). Each person is counted once, at
/// the rate of the *most lethal* effect that reaches them: the area is cut
/// into bands between consecutive ring radii, and every ring at least as
/// wide as a band covers it. That matters because the order of the rings
/// changes with yield: for a small weapon the radiation ring reaches past
/// the 20 psi ring, for a megaton weapon it sits well inside it.
({double deaths, double injured}) estimateCasualties(
  List<EffectRing> rings,
  double Function(double radiusMeters) peopleWithin,
) {
  final sorted = [...rings]..sort((a, b) => a.radiusMeters.compareTo(b.radiusMeters));
  var deaths = 0.0, injured = 0.0, inner = 0.0;
  for (var i = 0; i < sorted.length; i++) {
    final outer = peopleWithin(sorted[i].radiusMeters);
    final inBand = math.max(0.0, outer - inner);
    inner = math.max(inner, outer);
    // Every ring from i outwards covers this band; the worst one decides.
    var worst = sorted[i];
    for (final ring in sorted.skip(i)) {
      if (ring.fatalShare > worst.fatalShare) worst = ring;
    }
    deaths += inBand * worst.fatalShare;
    injured += inBand * worst.injuredShare;
  }
  return (deaths: deaths, injured: injured);
}
