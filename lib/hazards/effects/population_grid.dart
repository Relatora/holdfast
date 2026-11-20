/// People per grid cell for one region, decoded from the
/// `<id>.population.bin` pack written by `tool/build_population.py` (GHSL
/// GHS-POP 2025, 30″ cells, CC BY 4.0).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../pois/poi.dart' show distanceMeters;

class PopulationFormatException implements Exception {
  const PopulationFormatException(this.message);
  final String message;
  @override
  String toString() => 'PopulationFormatException: $message';
}

class PopulationGrid {
  PopulationGrid._(this.west, this.north, this.cellDegrees, this.columns, this.rows, this._people);

  /// Top-left corner of the first cell, and cell size, in degrees.
  final double west, north, cellDegrees;
  final int columns, rows;

  /// People per cell, row by row from the north.
  final Int32List _people;

  static const attribution = 'Population: GHSL GHS-POP 2025, European Commission JRC (CC BY 4.0)';

  int get totalPeople => _people.fold(0, (sum, v) => sum + v);

  factory PopulationGrid.decode(Uint8List bytes) {
    if (bytes.length < 4 || ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'HFPP') {
      throw const PopulationFormatException('Not a Holdfast population pack');
    }
    var offset = 4;
    int uint() {
      var result = 0, scale = 1; // arithmetic, not bit ops: see RoutingGraph
      while (true) {
        if (offset >= bytes.length) throw const PopulationFormatException('Population pack is truncated');
        final byte = bytes[offset++];
        result += (byte & 0x7f) * scale;
        if (byte < 0x80) return result;
        scale *= 128;
      }
    }

    final version = uint();
    if (version != 1) throw PopulationFormatException('Population pack version $version; this app reads 1');
    final header = ByteData.sublistView(bytes, offset, offset + 24);
    final west = header.getFloat64(0, Endian.little);
    final north = header.getFloat64(8, Endian.little);
    final cell = header.getFloat64(16, Endian.little);
    offset += 24;
    final columns = uint(), rows = uint();
    final people = Int32List(columns * rows);
    for (var i = 0; i < people.length; i++) {
      people[i] = uint();
    }
    return PopulationGrid._(west, north, cell, columns, rows, people);
  }

  /// People within [radiusMeters] of a point.
  ///
  /// Cells are about a kilometre across, so a cell counts in full when its
  /// centre is inside the circle. Circles smaller than a couple of cells
  /// would then count all or nothing, so they use the local density times
  /// the circle's area instead.
  double within(double latitude, double longitude, double radiusMeters) {
    final cellMetres = cellDegrees * 111320 * math.cos(latitude * math.pi / 180);
    final col = ((longitude - west) / cellDegrees).floor();
    final row = ((north - latitude) / cellDegrees).floor();

    if (radiusMeters < cellMetres * 1.5) {
      if (col < 0 || row < 0 || col >= columns || row >= rows) return 0;
      final cellArea = cellMetres * cellDegrees * 110540;
      return _people[row * columns + col] / cellArea * math.pi * radiusMeters * radiusMeters;
    }

    final spanCols = (radiusMeters / cellMetres).ceil() + 1;
    final spanRows = (radiusMeters / (cellDegrees * 110540)).ceil() + 1;
    var sum = 0.0;
    for (var r = math.max(0, row - spanRows); r <= math.min(rows - 1, row + spanRows); r++) {
      final cellLat = north - (r + 0.5) * cellDegrees;
      for (var c = math.max(0, col - spanCols); c <= math.min(columns - 1, col + spanCols); c++) {
        final count = _people[r * columns + c];
        if (count == 0) continue;
        final cellLon = west + (c + 0.5) * cellDegrees;
        if (distanceMeters(latitude, longitude, cellLat, cellLon) <= radiusMeters) sum += count;
      }
    }
    return sum;
  }
}
