/// Typed views over [Hazard.details]: the extra facts some hazard types
/// carry. Plain Dart (no Flutter), like the rest of the hazard model.
///
/// Each class reads itself from the details map and writes itself back, so
/// a report from a newer app with extra keys round-trips through an older
/// one without losing them.
library;

import 'hazard.dart';

/// Wind at the hazard: where it blows *from* and how hard. Meteorological
/// convention: a north wind (0°) blows *from* the north, carrying smoke
/// south.
class Wind {
  const Wind({required this.fromDegrees, required this.speedKmh, this.source = WindSource.manual});

  final double fromDegrees;
  final double speedKmh;
  final WindSource source;

  /// Where the wind carries things, 0–360°.
  double get towardDegrees => (fromDegrees + 180) % 360;

  static const _compass = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];

  /// "NW", the 8-point compass direction it blows from.
  String get fromCompass => _compass[((fromDegrees % 360 + 22.5) ~/ 45) % 8];

  /// Plain-language strength, after the Beaufort scale.
  String get strength => switch (speedKmh) {
        < 6 => 'calm',
        < 20 => 'light',
        < 39 => 'moderate',
        < 62 => 'strong',
        _ => 'gale',
      };

  String get summary => '${speedKmh.round()} km/h from $fromCompass';

  Map<String, Object?> toJson() => {'from': fromDegrees, 'kmh': speedKmh, 'source': source.name};

  static Wind? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final from = raw['from'], kmh = raw['kmh'];
    if (from is! num || kmh is! num) return null;
    return Wind(
      fromDegrees: from.toDouble(),
      speedKmh: kmh.toDouble(),
      source: WindSource.values.asNameMap()[raw['source']] ?? WindSource.manual,
    );
  }
}

enum WindSource {
  /// Entered by the reporter.
  manual,

  /// A weather forecast for the hazard's position (online only).
  forecast,
}

/// Radiation, in levels a non-specialist can act on. Each maps to a dose
/// rate range and one instruction; the numbers are for people with a meter,
/// the advice is for everyone.
enum RadiationLevel {
  normal('Normal', '< 0.3 µSv/h', 'Natural background. No action needed.', 0, 0.3),
  elevated('Elevated', '0.3–10 µSv/h', 'Limit time outdoors. Stay informed.', 0.3, 10),
  high('High', '10 µSv/h – 1 mSv/h', 'Shelter indoors, away from windows. Close vents.', 10, 1000),
  veryHigh(
    'Very high',
    '1–100 mSv/h',
    'Shelter in a basement or the middle of a large building. Follow evacuation orders.',
    1000,
    100000,
  ),
  dangerous('Dangerous', '> 100 mSv/h', 'Leave the area now, or take the deepest shelter you can reach.', 100000, double.infinity);

  const RadiationLevel(this.label, this.range, this.advice, this.minUSvH, this.maxUSvH);

  final String label;

  /// Dose rate band, for people with a meter.
  final String range;
  final String advice;
  final double minUSvH, maxUSvH;

  /// The level a meter reading (µSv/h) falls in.
  static RadiationLevel forReading(double microSievertPerHour) =>
      values.lastWhere((l) => microSievertPerHour >= l.minUSvH, orElse: () => normal);

  /// The report severity a level implies, so the map's marker matches.
  HazardSeverity get severity => switch (this) {
        RadiationLevel.normal || RadiationLevel.elevated => HazardSeverity.low,
        RadiationLevel.high => HazardSeverity.moderate,
        RadiationLevel.veryHigh => HazardSeverity.high,
        RadiationLevel.dangerous => HazardSeverity.extreme,
      };
}

class RadiationDetails {
  const RadiationDetails({required this.level, this.reading});

  final RadiationLevel level;

  /// A meter reading in µSv/h, when the reporter has one.
  final double? reading;

  Map<String, Object?> toJson() => {'level': level.name, if (reading != null) 'uSvH': reading};

  static RadiationDetails? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final level = RadiationLevel.values.asNameMap()[raw['level']];
    if (level == null) return null;
    return RadiationDetails(level: level, reading: (raw['uSvH'] as num?)?.toDouble());
  }
}

/// Air burst (detonated above ground: widest blast damage, little fallout)
/// or surface burst (smaller blast radius, heavy local fallout downwind).
enum BurstType {
  air('Air burst'),
  surface('Ground burst');

  const BurstType(this.label);
  final String label;
}

/// Representative weapons by yield, for people who know what was reported
/// ("it was a big one") better than a number. Publicly documented yields.
enum NuclearPreset {
  tactical('Small tactical', 0.3),
  hiroshima('Hiroshima-class', 15),
  w76('Submarine warhead', 100),
  w87('ICBM warhead', 300),
  b83('Large bomb', 1200),
  tsar('Largest ever tested', 50000);

  const NuclearPreset(this.label, this.yieldKt);
  final String label;
  final double yieldKt;
}

class NuclearDetails {
  const NuclearDetails({required this.yieldKt, this.preset, this.burst = BurstType.air});

  /// Yield in kilotons of TNT.
  final double yieldKt;

  /// The preset picked, if the yield came from one.
  final NuclearPreset? preset;
  final BurstType burst;

  /// "15 kt" / "1.2 Mt".
  String get yieldLabel {
    if (yieldKt >= 1000) {
      final mt = yieldKt / 1000;
      return '${mt == mt.roundToDouble() ? mt.toStringAsFixed(0) : mt.toStringAsFixed(1)} Mt';
    }
    return '${yieldKt < 1 ? yieldKt.toStringAsFixed(1) : yieldKt.toStringAsFixed(0)} kt';
  }

  Map<String, Object?> toJson() => {'kt': yieldKt, if (preset != null) 'preset': preset!.name, 'burst': burst.name};

  static NuclearDetails? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kt = raw['kt'];
    if (kt is! num || kt <= 0) return null;
    return NuclearDetails(
      yieldKt: kt.toDouble(),
      preset: NuclearPreset.values.asNameMap()[raw['preset']],
      burst: BurstType.values.asNameMap()[raw['burst']] ?? BurstType.air,
    );
  }
}

/// Typed access to a hazard's details.
extension HazardDetailsX on Hazard {
  Wind? get wind => Wind.fromJson(details['wind']);

  /// When a planned release happens (a controlled detonation, a burn), if
  /// the report is about one. Ignored when missing or unreadable.
  DateTime? get startsAt => switch (details['startsAt']) {
        final String raw => DateTime.tryParse(raw),
        _ => null,
      };

  /// True while a planned release is still ahead.
  bool plannedAt(DateTime now) => startsAt?.isAfter(now) ?? false;
  RadiationDetails? get radiation => RadiationDetails.fromJson(details['radiation']);
  NuclearDetails? get nuclear => NuclearDetails.fromJson(details['nuclear']);
}

/// Builds the details map for a new report.
Map<String, Object?> hazardDetails({
  Wind? wind,
  RadiationDetails? radiation,
  NuclearDetails? nuclear,
  DateTime? startsAt,
}) =>
    {
      if (wind != null) 'wind': wind.toJson(),
      if (startsAt != null) 'startsAt': startsAt.toUtc().toIso8601String(),
      if (radiation != null) 'radiation': radiation.toJson(),
      if (nuclear != null) 'nuclear': nuclear.toJson(),
    };
