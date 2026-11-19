import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/regions/region.dart';

void main() {
  // Read the real shipped catalog so a typo in it fails CI, not a user.
  final json = jsonDecode(File('assets/regions/catalog.json').readAsStringSync()) as Map<String, Object?>;
  final regions = [
    for (final item in json['regions']! as List<Object?>) Region.fromJson((item! as Map).cast<String, Object?>()),
  ];

  test('offers every level from a city up to the whole world', () {
    expect(regions.map((r) => r.level).toSet(), RegionLevel.values.toSet());
  });

  test('ids are unique and parents exist', () {
    final ids = regions.map((r) => r.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    for (final region in regions.where((r) => r.parentId != null)) {
      expect(ids, contains(region.parentId), reason: '${region.id} has unknown parent');
    }
  });

  test('bounding boxes are well-formed', () {
    for (final r in regions) {
      expect(r.west, lessThan(r.east), reason: r.id);
      expect(r.south, lessThan(r.north), reason: r.id);
    }
  });

  test('cities sit inside their province', () {
    final byId = {for (final r in regions) r.id: r};
    for (final city in regions.where((r) => r.level == RegionLevel.city)) {
      final province = byId[city.parentId]!;
      expect(province.contains(city.center.latitude, city.center.longitude), isTrue, reason: city.id);
    }
  });

  test('a city fits a phone screen at a street-level-ish zoom', () {
    final ottawa = regions.firstWhere((r) => r.id == 'ottawa');
    expect(ottawa.fitZoom, inInclusiveRange(8.5, 10));
    final world = regions.firstWhere((r) => r.id == 'world');
    expect(world.fitZoom, lessThan(2));
  });

  test('formatBytes reads naturally', () {
    expect(formatBytes(21300000), '21 MB');
    expect(formatBytes(1800000000), '1.8 GB');
    expect(formatBytes(139600000000), '140 GB');
    expect(formatBytes(512), '512 B');
  });
}
