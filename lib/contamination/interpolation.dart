/// An estimated contamination zone between soil samples: where the
/// readings suggest the ground is elevated or worse, shaded by level.
///
/// Plain Dart. Inverse-distance weighting (IDW) on a regular grid: each
/// cell takes a weighted mean of every sample, weighted by 1/distance², so
/// the nearest samples dominate. The mean is taken of the *logarithm* of
/// the readings, because contamination spans orders of magnitude: halfway
/// between 50 and 5,000 ppm is better guessed as 500 than as 2,525.
///
/// Honest limits, which the map labels say ("Estimated from N samples"):
/// * It needs at least [minSamples] readings of one contaminant; with
///   fewer, only the dots are drawn.
/// * Cells further than twice the typical spacing between samples from
///   any sample are left blank: no guessing into unsampled ground.
/// * IDW never invents a value outside the measured range, so a zone is
///   never worse than the worst sample (nor better than the best).
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'contaminants.dart';
import 'sample.dart';

const minSamples = 3;

/// One grid cell of an estimated zone.
class ZoneCell {
  const ZoneCell({required this.south, required this.west, required this.north, required this.east, required this.value});

  final double south, west, north, east;

  /// The interpolated reading, in the contaminant's unit.
  final double value;

  LatLng get center => LatLng((south + north) / 2, (west + east) / 2);
  List<LatLng> get outline => [LatLng(north, west), LatLng(north, east), LatLng(south, east), LatLng(south, west)];
}

class EstimatedZone {
  const EstimatedZone({required this.contaminant, required this.sampleCount, required this.cells});

  final Contaminant contaminant;
  final int sampleCount;

  /// Cells at Elevated or above (Normal cells are left out: nothing to show).
  final List<ZoneCell> cells;

  ContaminationLevel levelOf(ZoneCell cell) => contaminant.levelFor(cell.value);
}

/// Estimated zones, one per contaminant with enough [samples]. A dose-rate
/// reading is a snapshot rather than ground contamination, so it gets dots
/// only.
List<EstimatedZone> estimateZones(Iterable<Sample> samples, {int maxCellsAcross = 48}) {
  final byContaminant = <Contaminant, List<Sample>>{};
  for (final s in samples) {
    if (s.contaminant == Contaminant.doseRate) continue;
    byContaminant.putIfAbsent(s.contaminant, () => []).add(s);
  }
  return [
    for (final MapEntry(key: contaminant, value: group) in byContaminant.entries)
      if (group.length >= minSamples)
        if (_zone(contaminant, group, maxCellsAcross) case final zone? when zone.cells.isNotEmpty) zone,
  ];
}

EstimatedZone? _zone(Contaminant contaminant, List<Sample> group, int maxCellsAcross) {
  // Local flat coordinates in metres around the group's middle: accurate
  // to well under a percent across the few kilometres samples span.
  final lat0 = group.map((s) => s.latitude).reduce((a, b) => a + b) / group.length;
  final metresPerDegLat = 110540.0;
  final metresPerDegLon = 111320.0 * math.cos(lat0 * math.pi / 180);
  double x(double lon) => lon * metresPerDegLon;
  double y(double lat) => lat * metresPerDegLat;

  final points = [for (final s in group) (x: x(s.longitude), y: y(s.latitude), log: _log(s.value), value: s.value)];

  // Typical spacing: the median distance from each sample to its nearest
  // neighbour. Beyond twice that, there's no data to estimate from.
  final nearest = [
    for (final (i, p) in points.indexed)
      points.indexed
          .where((e) => e.$1 != i)
          .map((e) => _dist(p.x, p.y, e.$2.x, e.$2.y))
          .reduce(math.min),
  ]..sort();
  final spacing = math.max(nearest[nearest.length ~/ 2], 25.0);
  final reach = 2 * spacing;

  final minX = points.map((p) => p.x).reduce(math.min) - reach;
  final maxX = points.map((p) => p.x).reduce(math.max) + reach;
  final minY = points.map((p) => p.y).reduce(math.min) - reach;
  final maxY = points.map((p) => p.y).reduce(math.max) + reach;
  // Cells a third of the spacing, but never more than maxCellsAcross a side.
  final cell = math.max(spacing / 3, math.max(maxX - minX, maxY - minY) / maxCellsAcross);

  final cells = <ZoneCell>[];
  for (var cy = minY; cy < maxY; cy += cell) {
    for (var cx = minX; cx < maxX; cx += cell) {
      final mx = cx + cell / 2, my = cy + cell / 2;
      var weightSum = 0.0, logSum = 0.0, closest = double.infinity;
      double? exact;
      for (final p in points) {
        final d = _dist(mx, my, p.x, p.y);
        closest = math.min(closest, d);
        if (d < 1) {
          exact = p.value;
          break;
        }
        final w = 1 / (d * d);
        weightSum += w;
        logSum += w * p.log;
      }
      if (closest > reach) continue;
      final value = exact ?? _unlog(logSum / weightSum);
      if (contaminant.levelFor(value) == ContaminationLevel.normal) continue;
      cells.add(ZoneCell(
        south: cy / metresPerDegLat,
        north: (cy + cell) / metresPerDegLat,
        west: cx / metresPerDegLon,
        east: (cx + cell) / metresPerDegLon,
        value: value,
      ));
    }
  }
  return EstimatedZone(contaminant: contaminant, sampleCount: group.length, cells: cells);
}

double _dist(double ax, double ay, double bx, double by) => math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

// Readings can be zero; the offset keeps the logarithm finite without
// moving any reading that matters.
const _offset = 1e-3;
double _log(double v) => math.log(v + _offset);
double _unlog(double l) => math.max(0, math.exp(l) - _offset);
