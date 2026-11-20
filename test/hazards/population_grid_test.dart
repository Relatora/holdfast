import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/effects/nuclear_effects.dart';
import 'package:holdfast/hazards/effects/population_grid.dart';
import 'package:holdfast/hazards/hazard_details.dart';

/// Writes a pack in the format of `tool/build_population.py`.
Uint8List pack({required double west, required double north, required double cell, required List<List<int>> rows}) {
  final out = BytesBuilder()..add(ascii.encode('HFPP'));
  void uint(int v) {
    do {
      var b = v & 0x7f;
      v >>= 7;
      if (v != 0) b |= 0x80;
      out.addByte(b);
    } while (v != 0);
  }

  uint(1);
  final header = ByteData(24)
    ..setFloat64(0, west, Endian.little)
    ..setFloat64(8, north, Endian.little)
    ..setFloat64(16, cell, Endian.little);
  out.add(header.buffer.asUint8List());
  uint(rows.first.length);
  uint(rows.length);
  for (final row in rows) {
    row.forEach(uint);
  }
  return out.toBytes();
}

void main() {
  // A 5 × 5 town of 1/120° cells (~650 m × 925 m at 45°), 1000 people in
  // the middle cell and 100 in each of the others.
  final grid = PopulationGrid.decode(pack(
    west: -75.0,
    north: 45.0,
    cell: 1 / 120,
    rows: [
      for (var r = 0; r < 5; r++) [for (var c = 0; c < 5; c++) r == 2 && c == 2 ? 1000 : 100],
    ],
  ));
  // Centre of the middle cell.
  const lat = 45.0 - 2.5 / 120, lon = -75.0 + 2.5 / 120;

  test('decodes the header and every cell', () {
    expect(grid.columns, 5);
    expect(grid.rows, 5);
    expect(grid.totalPeople, 1000 + 24 * 100);
  });

  test('a wide circle counts whole cells; outside the grid counts nobody', () {
    expect(grid.within(lat, lon, 5000), grid.totalPeople);
    expect(grid.within(50, -75, 5000), 0);
  });

  test('a small circle uses the local density instead of all-or-nothing', () {
    final small = grid.within(lat, lon, 200);
    expect(small, greaterThan(0));
    expect(small, lessThan(1000), reason: 'a 200 m circle is a fraction of a ~0.6 km² cell');
  });

  test('rejects files that are not population packs', () {
    expect(() => PopulationGrid.decode(Uint8List.fromList([1, 2, 3, 4, 5])), throwsA(isA<PopulationFormatException>()));
  });

  final ottawa = File('regions/ottawa.population.bin');
  test('real Ottawa pack: a downtown 15 kt air burst', () {
    final grid = PopulationGrid.decode(ottawa.readAsBytesSync());
    expect(grid.totalPeople, inInclusiveRange(1200000, 1700000), reason: 'Ottawa–Gatineau is ~1.5 million');
    // Parliament Hill.
    const hill = (lat: 45.4236, lon: -75.7009);
    final rings = nuclearEffects(const NuclearDetails(yieldKt: 15));
    final estimate = estimateCasualties(rings, (r) => grid.within(hill.lat, hill.lon, r));
    final reached = grid.within(hill.lat, hill.lon, rings.last.radiusMeters);
    expect(estimate.deaths, inInclusiveRange(10000, 150000));
    expect(estimate.deaths + estimate.injured, lessThanOrEqualTo(reached));
  }, skip: ottawa.existsSync() ? false : 'run tool/build_population.py ottawa first');
}
