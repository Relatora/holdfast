import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_details.dart';

Hazard _hazard(HazardType type, {Map<String, Object?> details = const {}}) => Hazard(
      id: 'h1',
      type: type,
      severity: HazardSeverity.high,
      latitude: 45.42,
      longitude: -75.69,
      reportedBy: 'a',
      reportedAt: DateTime.utc(2026, 11, 20),
      details: details,
    );

void main() {
  group('types and categories', () {
    test('every type belongs to a category, and every category but Other has types', () {
      for (final category in HazardCategory.values) {
        if (category == HazardCategory.other) continue;
        expect(category.types, isNotEmpty, reason: category.name);
      }
      expect(HazardType.values.map((t) => t.category).toSet(), HazardCategory.values.toSet());
    });

    test('a type from a newer app becomes "Other hazard", not a mislabelled one', () {
      expect(HazardType.parse('meteorStrike'), HazardType.other);
      expect(HazardType.parse('tsunami'), HazardType.tsunami);
    });

    test('wind only matters for hazards that drift', () {
      expect(HazardType.radiation.spreadsWithWind, isTrue);
      expect(HazardType.volcanicAsh.spreadsWithWind, isTrue);
      expect(HazardType.police.spreadsWithWind, isFalse);
      expect(HazardType.lava.spreadsWithWind, isFalse, reason: 'lava follows the ground, not the wind');
    });
  });

  group('details', () {
    test('survive a round trip through JSON, as they do through sync', () {
      final original = _hazard(
        HazardType.nuclearDetonation,
        details: hazardDetails(
          nuclear: const NuclearDetails(yieldKt: 15, preset: NuclearPreset.hiroshima, burst: BurstType.surface),
          wind: const Wind(fromDegrees: 315, speedKmh: 25, source: WindSource.forecast),
        ),
      );
      final copy = Hazard.fromJson(original.toJson());
      expect(copy.nuclear?.yieldKt, 15);
      expect(copy.nuclear?.preset, NuclearPreset.hiroshima);
      expect(copy.nuclear?.burst, BurstType.surface);
      expect(copy.wind?.fromCompass, 'NW');
      expect(copy.wind?.source, WindSource.forecast);
      expect(copy.radiation, isNull);
    });

    test('unknown keys from a newer app are kept', () {
      final hazard = _hazard(HazardType.fire, details: {'futureThing': 42});
      expect(Hazard.fromJson(hazard.toJson()).details['futureThing'], 42);
    });

    test('malformed details are ignored rather than crashing', () {
      final hazard = _hazard(HazardType.radiation, details: {'radiation': 'loud', 'wind': {'from': 'west'}});
      expect(hazard.radiation, isNull);
      expect(hazard.wind, isNull);
    });
  });

  group('radiation levels', () {
    test('a meter reading picks the right level', () {
      expect(RadiationLevel.forReading(0.1), RadiationLevel.normal);
      expect(RadiationLevel.forReading(2), RadiationLevel.elevated);
      expect(RadiationLevel.forReading(250), RadiationLevel.high);
      expect(RadiationLevel.forReading(5000), RadiationLevel.veryHigh);
      expect(RadiationLevel.forReading(2e5), RadiationLevel.dangerous);
    });

    test('levels map onto marker severity, worst = extreme', () {
      expect(RadiationLevel.dangerous.severity, HazardSeverity.extreme);
      expect(RadiationLevel.normal.severity, HazardSeverity.low);
    });
  });

  test('wind reads naturally', () {
    const wind = Wind(fromDegrees: 90, speedKmh: 30);
    expect(wind.fromCompass, 'E');
    expect(wind.towardDegrees, 270, reason: 'an east wind carries things west');
    expect(wind.strength, 'moderate');
    expect(wind.summary, '30 km/h from E');
  });

  test('yields read naturally', () {
    expect(const NuclearDetails(yieldKt: 0.3).yieldLabel, '0.3 kt');
    expect(const NuclearDetails(yieldKt: 15).yieldLabel, '15 kt');
    expect(const NuclearDetails(yieldKt: 1200).yieldLabel, '1.2 Mt');
    expect(const NuclearDetails(yieldKt: 50000).yieldLabel, '50 Mt');
  });
}
