/// Where the moving parts of the hazard animations are at a given moment:
/// motes drifting down a plume, wind streaks, tsunami wave fronts.
///
/// Plain Dart, deterministic and tested: every mote is seeded from the
/// hazard's id, so a frame at time t is always the same frame, and motes
/// are placed inside the plume the map draws. The painter
/// (effects_layer.dart) only projects these to the screen and colours them.
///
/// Motion is for reading, not realism: real smoke takes hours to cross a
/// plume, so motes cross it in seconds, a little faster in a stronger wind,
/// always in the direction the wind carries things.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../hazards/effects/spread.dart';
import '../../hazards/effects/zones.dart';
import '../../hazards/hazard.dart';
import '../../hazards/hazard_details.dart';

/// How a drifting hazard's motes look.
enum MoteStyle {
  /// Sickly yellow-green puffs that swell as they drift (chemical leaks).
  chemical,

  /// Thin violet wisps (gas leaks).
  gas,

  /// Fine twinkling sparks (radiation and fallout).
  radiation,

  /// Fine blue-grey dust that settles out early (lead).
  lead,

  /// Grey flakes (volcanic ash).
  ash,

  /// Brown-grey billows (wildfire smoke).
  smoke,
}

MoteStyle? moteStyleFor(HazardType type) => switch (type) {
  HazardType.chemicalSpill => MoteStyle.chemical,
  HazardType.gasLeak => MoteStyle.gas,
  HazardType.radiation || HazardType.nuclearDetonation => MoteStyle.radiation,
  HazardType.leadDust => MoteStyle.lead,
  HazardType.volcanicAsh || HazardType.volcanicEruption => MoteStyle.ash,
  HazardType.fire => MoteStyle.smoke,
  _ => null,
};

/// One drifting particle.
class Mote {
  const Mote({required this.at, required this.opacity, required this.size, required this.seed});

  final LatLng at;

  /// 0 to 1: faded in at the source, out at the far end.
  final double opacity;

  /// Relative size, 0.5 to about 1.6: puffs swell as they drift.
  final double size;

  /// 0 to 1, fixed per mote, for per-mote variation (twinkle phase).
  final double seed;
}

/// A short streak of moving air: where it is and which way it points.
class Streak {
  const Streak({required this.from, required this.to, required this.opacity});
  final LatLng from, to;
  final double opacity;
}

/// Seconds a mote takes to cross the whole plume: 6 s in a gale, 14 s in
/// a breeze.
double crossingSeconds(double windKmh) => (14 - windKmh / 5).clamp(6.0, 14.0);

const _distance = Distance();

/// A tiny deterministic random source (xorshift), seeded per hazard, so
/// the same hazard always animates the same way.
class _Random {
  _Random(int seed) : _state = seed == 0 ? 0x9E3779B9 : seed & 0x7fffffff;
  int _state;
  double next() {
    _state ^= (_state << 13) & 0x7fffffff;
    _state ^= _state >> 17;
    _state ^= (_state << 5) & 0x7fffffff;
    return (_state & 0xffffff) / 0x1000000;
  }
}

int _seedOf(String id) => id.codeUnits.fold(17, (h, c) => (h * 31 + c) & 0x7fffffff);

/// The part of a plume worth animating, in metres along its axis: all of
/// it by default, or just the stretch on screen ([window], from the
/// painter), so a 60 km plume seen at street level still gets its motes
/// where you're looking. Null when nothing of it is in the window.
({double from, double to})? _span(double length, ({double from, double to})? window) {
  if (window == null) return (from: 0, to: length);
  final from = math.max(0.0, window.from), to = math.min(length, window.to);
  return to - from < 1 ? null : (from: from, to: to);
}

/// The [count] motes of [hazard]'s plume at [seconds], inside its 6 h band
/// (and within [window] metres along it, when given).
List<Mote> plumeMotes(Hazard hazard, double seconds, {int count = 60, ({double from, double to})? window}) {
  final axis = plumeAxis(hazard);
  final style = moteStyleFor(hazard.type);
  if (axis == null || style == null) return const [];
  final span = _span(axis.lengthMeters, window);
  if (span == null) return const [];
  // Crossing time scales with the stretch shown, so motes move at the
  // same speed on screen whether the whole plume is in view or not.
  final period = crossingSeconds(hazard.wind!.speedKmh) * (span.to - span.from) / axis.lengthMeters;
  final random = _Random(_seedOf(hazard.id));
  final motes = <Mote>[];
  for (var i = 0; i < count; i++) {
    final start = random.next();
    // Two draws averaged: motes crowd the middle of the plume, as smoke does.
    final lateral = (random.next() + random.next()) - 1;
    final pace = 0.8 + 0.4 * random.next();
    final seed = random.next();
    final local = (start + seconds * pace / math.max(period, 0.5)) % 1.0;
    final along = span.from + local * (span.to - span.from);
    final u = along / axis.lengthMeters; // how far down the whole plume
    final half = axis.sourceMeters + along * axis.widening;
    final centre = _distance.offset(axis.origin, along, axis.towardDegrees);
    final at = _distance.offset(centre, lateral * half * 0.92, axis.towardDegrees + 90);
    // Fade in at the source and out at the far end (of the whole plume,
    // and of the stretch shown). Lead settles out of the air early, so its
    // motes fade sooner.
    final fadeEnd = style == MoteStyle.lead ? 0.7 : 1.0;
    final opacity = u > fadeEnd ? 0.0 : math.sin(math.pi * math.min(u / fadeEnd, 1)) * _edgeFade(local, window);
    final swell = switch (style) {
      MoteStyle.chemical || MoteStyle.smoke || MoteStyle.gas => 0.6 + u,
      _ => 0.7 + 0.3 * seed,
    };
    motes.add(Mote(at: at, opacity: opacity, size: swell, seed: seed));
  }
  return motes;
}

/// Wind streaks over and around [hazard]'s plume, moving with the wind:
/// the wind itself, made visible. Each streak is a short segment along the
/// wind, sliding downwind and fading at both ends of its run.
List<Streak> windStreaks(Hazard hazard, double seconds, {int count = 24, ({double from, double to})? window}) {
  final axis = plumeAxis(hazard);
  if (axis == null) return const [];
  // The streaks cover a field a little wider and longer than the plume,
  // starting upwind of the source: air moves everywhere, not just where
  // the smoke is.
  final field = _span(
    axis.lengthMeters * 1.35,
    window == null ? null : (from: window.from + axis.lengthMeters * 0.15, to: window.to + axis.lengthMeters * 0.15),
  );
  if (field == null) return const [];
  final upwind = axis.lengthMeters * 0.15;
  final period = crossingSeconds(hazard.wind!.speedKmh) * 0.8 * (field.to - field.from) / (axis.lengthMeters * 1.35);
  final random = _Random(_seedOf(hazard.id) ^ 0x5bd1e995);
  final streakLength = math.max((field.to - field.from) * 0.06, 120.0);
  final streaks = <Streak>[];
  for (var i = 0; i < count; i++) {
    final start = random.next();
    final lateral = random.next() * 2 - 1;
    final u = (start + seconds / math.max(period, 0.5)) % 1.0;
    final along = field.from + u * (field.to - field.from) - upwind;
    final half = axis.sourceMeters + math.max(along, 0) * axis.widening;
    final centre = _distance.offset(axis.origin, along, axis.towardDegrees);
    final from = _distance.offset(centre, lateral * half * 1.6, axis.towardDegrees + 90);
    final to = _distance.offset(from, streakLength, axis.towardDegrees);
    streaks.add(Streak(from: from, to: to, opacity: math.sin(math.pi * u)));
  }
  return streaks;
}

/// Motes fade near the ends of a [window], so wrapping round from one end
/// to the other never pops (the painter's window reaches past the screen).
double _edgeFade(double local, ({double from, double to})? window) {
  if (window == null) return 1;
  return math.min(1.0, math.min(local, 1 - local) / 0.08);
}

/// The radii, in metres, of a tsunami's wave fronts at [seconds], with how
/// strongly each shows: [fronts] waves expanding from the origin to the
/// 120-minute ring and starting again, fading as they spread. Empty for a
/// tsunami reported where waves hit (no origin to spread from).
List<({double radiusMeters, double opacity})> tsunamiFronts(Hazard hazard, double seconds, {int fronts = 3}) {
  final tsunami = hazard.tsunami;
  if (hazard.type != HazardType.tsunami || tsunami == null) return const [];
  final reach = tsunami.reachMeters(TsunamiDetails.ringMinutes.last);
  const period = 9.0; // seconds for a front to cross to the last ring
  return [
    for (var k = 0; k < fronts; k++)
      () {
        final phase = (seconds / period + k / fronts) % 1.0;
        return (radiusMeters: phase * reach, opacity: math.pow(1 - phase, 1.4).toDouble());
      }(),
  ];
}

/// The danger zone radius around an eruption's vent, for scaling its
/// animation; null for other types.
double? ventZoneMeters(Hazard hazard) => hazard.type == HazardType.volcanicEruption ? eruptionDangerMeters : null;
