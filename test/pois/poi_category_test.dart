import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/pois/poi.dart';

void main() {
  test('every category id parses back to itself', () {
    for (final category in PoiCategory.values) {
      expect(PoiCategory.tryParse(category.id), category);
    }
  });

  test('airports from a supply pack become airport places', () {
    final poi = Poi.fromJson({'id': 'w1', 'cat': 'airport', 'name': '', 'lat': 42.99, 'lon': -82.31});
    expect(poi?.category, PoiCategory.airport);
    // Small strips are often unnamed in OSM; they still get a readable title.
    expect(poi?.title, 'Airport & airfield');
  });

  test('category ids are unique, since packs store them', () {
    final ids = PoiCategory.values.map((c) => c.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
  });
}
