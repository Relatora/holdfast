import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../pois/poi.dart' show distanceMeters;
import 'cell_pack.dart';
import 'locator.dart';

/// A cell the phone can hear right now.
class HeardCell {
  const HeardCell(this.key, {this.dbm, this.serving = false});

  final CellKey key;

  /// Received signal strength, when the modem reports it.
  final int? dbm;

  /// The cell the phone is registered with (always the strongest usable).
  final bool serving;
}

/// Lists the cells the device hears. Only Android exposes this; elsewhere
/// the list is empty and the rough fallback is the system's own.
abstract interface class CellScanner {
  Future<List<HeardCell>> scan();
}

/// [CellScanner] over the `holdfast/cells` channel in `MainActivity.kt`,
/// which reads `TelephonyManager.getAllCellInfo()`. Works with no SIM data
/// and no network: towers are heard regardless. Needs location on and the
/// location permission, which the GPS attempt has already asked for.
class PlatformCellScanner implements CellScanner {
  const PlatformCellScanner();

  static const _channel = MethodChannel('holdfast/cells');

  @override
  Future<List<HeardCell>> scan() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return const [];
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('scan') ?? const [];
    return [
      for (final cell in raw)
        if (CellRadio.values.asNameMap()[cell['radio']] case final radio?)
          HeardCell(
            CellKey(
              radio,
              (cell['mcc']! as num).toInt(),
              (cell['mnc']! as num).toInt(),
              (cell['area']! as num).toInt(),
              (cell['cell']! as num).toInt(),
            ),
            dbm: (cell['dbm'] as num?)?.toInt(),
            serving: cell['serving'] == true,
          ),
    ];
  }
}

/// The smallest error circle claimed for a tower estimate. Cell positions
/// are averaged measurements, and a phone can hear a cell from well beyond
/// where it was measured; anything tighter would overstate it.
const minTowerAccuracyMeters = 500.0;

/// Signal assumed for a cell whose strength isn't reported: weak, so a
/// measured strong cell still dominates.
const _unknownDbm = -110;

/// Estimates a position from the [heard] cells found in [packs], or null
/// when none of them is in any pack.
///
/// A weighted centroid: each known cell pulls the estimate towards its
/// position, in proportion to its received amplitude (10^(dBm/20)), so a
/// cell 20 dB stronger counts ten times as much. Stronger usually means
/// closer; terrain and buildings make that rough, which the accuracy says.
///
/// Accuracy is the larger of [minTowerAccuracyMeters], the weighted spread
/// of the cells around the estimate, and, with a single cell, how far that
/// cell reaches.
Fix? estimateFromCells(List<HeardCell> heard, List<CellPack> packs, {required DateTime time}) {
  final known = <({CellSite site, double weight})>[];
  final seen = <CellKey>{};
  for (final cell in heard) {
    if (!seen.add(cell.key)) continue;
    CellSite? site;
    for (final pack in packs) {
      site = pack[cell.key];
      if (site != null) break;
    }
    if (site == null) continue;
    known.add((site: site, weight: math.pow(10, (cell.dbm ?? _unknownDbm) / 20).toDouble()));
  }
  if (known.isEmpty) return null;

  if (known.length == 1) {
    final only = known.single.site;
    return Fix(
      at: only.at,
      accuracyMeters: math.max(minTowerAccuracyMeters, only.rangeMeters),
      source: FixSource.towers,
      time: time,
    );
  }

  final total = known.fold(0.0, (sum, k) => sum + k.weight);
  // Averaging latitude and longitude directly is fine over a city's few
  // kilometres; no region spans the antimeridian.
  final lat = known.fold(0.0, (sum, k) => sum + k.site.at.latitude * k.weight) / total;
  final lon = known.fold(0.0, (sum, k) => sum + k.site.at.longitude * k.weight) / total;
  final spread = math.sqrt(known.fold(0.0, (sum, k) {
        final d = distanceMeters(lat, lon, k.site.at.latitude, k.site.at.longitude);
        return sum + d * d * k.weight;
      }) /
      total);
  return Fix(
    at: LatLng(lat, lon),
    accuracyMeters: math.max(minTowerAccuracyMeters, spread),
    source: FixSource.towers,
    time: time,
  );
}

/// Offline positioning from cell towers: scans, then looks the cells up in
/// the downloaded regions' tower packs. Plugged into [DeviceLocator] as a
/// rough source, ahead of the system's network location.
class TowerLocator {
  TowerLocator({required this.loadPacks, this.scanner = const PlatformCellScanner(), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// The tower packs of every downloaded region that has one.
  final Future<List<CellPack>> Function() loadPacks;
  final CellScanner scanner;
  final DateTime Function() _clock;

  /// A position, or null when no heard cell is in any pack.
  Future<Fix?> locate() async {
    final heard = await scanner.scan();
    if (heard.isEmpty) return null;
    final packs = await loadPacks();
    if (packs.isEmpty) return null;
    return estimateFromCells(heard, packs, time: _clock());
  }
}
