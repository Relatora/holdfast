import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/pois/poi.dart';
import 'package:holdfast/pois/poi_index.dart';

void main() {
  // Parliament Hill, Ottawa, as the reference point.
  const lat = 45.4236, lon = -75.7009;

  final index = PoiIndex.fromPack({
    'pois': [
      {'id': 'n1', 'cat': 'bigbox', 'name': 'Canadian Tire', 'lat': 45.4290, 'lon': -75.6890, 'tags': {'brand': 'Canadian Tire'}},
      {'id': 'n2', 'cat': 'medical', 'name': 'Rideau Pharmacy', 'lat': 45.4270, 'lon': -75.6920},
      {'id': 'n3', 'cat': 'water', 'name': '', 'lat': 45.4240, 'lon': -75.7000},
      {'id': 'n4', 'cat': 'bigbox', 'name': 'Walmart', 'lat': 45.3500, 'lon': -75.8000},
      {'id': 'n5', 'cat': 'spaceport', 'name': 'Unknown category', 'lat': 0, 'lon': 0},
    ],
  });

  test('skips categories this version does not know', () {
    expect(index.pois, hasLength(4));
  });

  test('nearest returns closest first', () {
    final hits = index.nearest(lat, lon, limit: 2);
    expect(hits.map((h) => h.poi.id), ['n3', 'n2']);
  });

  test('nearest can be limited to categories', () {
    final hits = index.nearest(lat, lon, categories: {PoiCategory.bigbox});
    expect(hits.first.poi.title, 'Canadian Tire');
    expect(hits.last.poi.title, 'Walmart');
  });

  test('nearestPerCategory gives one place per category', () {
    final hits = index.nearestPerCategory(lat, lon);
    expect(hits.map((h) => h.poi.category).toSet(), hasLength(3));
    expect(hits.firstWhere((h) => h.poi.category == PoiCategory.bigbox).poi.title, 'Canadian Tire');
  });

  test('search matches name and brand, case-insensitively', () {
    expect(index.filter(query: 'canadian').single.id, 'n1');
    expect(index.filter(query: 'WALMART').single.id, 'n4');
  });

  test('unnamed places fall back to the category label', () {
    expect(index.pois.firstWhere((p) => p.id == 'n3').title, 'Drinking water');
  });

  test('distances are formatted for humans', () {
    expect(formatDistance(842), '840 m');
    expect(formatDistance(2440), '2.4 km');
    expect(formatDistance(38200), '38 km');
  });

  test('haversine distance is about right', () {
    // Ottawa to Montréal is roughly 166 km in a straight line.
    final meters = distanceMeters(45.4215, -75.6972, 45.5017, -73.5673);
    expect(meters, closeTo(166000, 3000));
  });
}
