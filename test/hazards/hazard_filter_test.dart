import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_filter.dart';
import 'package:holdfast/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Hazard _at(String id, HazardType type, double lat, {HazardSeverity severity = HazardSeverity.moderate, int hour = 0}) =>
    Hazard(
      id: id,
      type: type,
      severity: severity,
      latitude: lat,
      longitude: -75.69,
      reportedBy: 'a',
      reportedAt: DateTime.utc(2026, 11, 20, hour),
    );

void main() {
  final flood = _at('flood', HazardType.flood, 45.43, severity: HazardSeverity.high, hour: 1);
  final police = _at('police', HazardType.police, 45.50, severity: HazardSeverity.low, hour: 5);
  final fire = _at('fire', HazardType.fire, 45.60, severity: HazardSeverity.extreme, hour: 3);
  final all = [fire, police, flood];

  test('an empty filter shows everything; otherwise only the chosen categories', () {
    expect(all.where((h) => passesFilter(h, {})), hasLength(3));
    expect(all.where((h) => passesFilter(h, {HazardCategory.water})).map((h) => h.id), ['flood']);
    expect(
      all.where((h) => passesFilter(h, {HazardCategory.water, HazardCategory.people})).map((h) => h.id),
      ['police', 'flood'],
    );
  });

  test('sorts by distance, severity or time', () {
    List<String> ids(HazardSort s) => sortHazards(all, s, latitude: 45.42, longitude: -75.69).map((h) => h.id).toList();
    expect(ids(HazardSort.nearest), ['flood', 'police', 'fire']);
    expect(ids(HazardSort.severity), ['fire', 'flood', 'police']);
    expect(ids(HazardSort.newest), ['police', 'fire', 'flood']);
  });

  test('counts per category for the chips', () {
    expect(countByCategory(all), {
      HazardCategory.fire: 1,
      HazardCategory.people: 1,
      HazardCategory.water: 1,
    });
  });

  test('the shortlist is remembered', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    expect(settings.hazardCategories, isEmpty);
    settings.hazardCategories = {HazardCategory.water, HazardCategory.chemical};
    final again = await AppSettings.load();
    expect(again.hazardCategories, {HazardCategory.water, HazardCategory.chemical});
  });
}
