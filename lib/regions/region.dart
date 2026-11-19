/// Downloadable map regions, from a single city up to the whole planet.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// How big a region is. People pick a level first, then a region in it.
enum RegionLevel {
  city('Cities', 'A metro area. Quick to download.'),
  province('Provinces & states', 'Good for a road trip or evacuation.'),
  country('Countries', 'Plan for several gigabytes.'),
  continent('Continents', 'Tens of gigabytes. Desktop or large phones.'),
  world('Whole world', 'The full planet. Over 100 GB.');

  const RegionLevel(this.label, this.hint);
  final String label;
  final String hint;
}

/// One entry of `assets/regions/catalog.json`.
class Region {
  const Region({
    required this.id,
    required this.name,
    required this.level,
    required this.west,
    required this.south,
    required this.east,
    required this.north,
    required this.approxBytes,
    this.parentId,
    this.remoteUrl,
  });

  final String id;
  final String name;
  final RegionLevel level;

  /// Bounding box in degrees.
  final double west, south, east, north;

  /// Planning estimate shown before the server reports the real size.
  final int approxBytes;

  /// The containing region (a city's province, a province's country).
  final String? parentId;

  /// An absolute basemap URL that overrides the region server. Only the
  /// whole-world entry uses it, pointing at the daily Protomaps planet build.
  final String? remoteUrl;

  LatLng get center => LatLng((south + north) / 2, (west + east) / 2);

  /// Zoom level at which the box roughly fills a phone-width screen.
  ///
  /// At zoom z one 256 px tile spans 360 / 2^z degrees, and a phone screen
  /// is about 1.5 tiles wide, so z = log2(360 * 1.5 / span).
  double get fitZoom {
    final span = (east - west).abs().clamp(0.01, 360.0);
    return (math.log(360 * 1.5 / span) / math.ln2).clamp(1.0, 14.0);
  }

  bool contains(double latitude, double longitude) =>
      latitude >= south && latitude <= north && longitude >= west && longitude <= east;

  factory Region.fromJson(Map<String, Object?> json) {
    final bbox = (json['bbox']! as List).cast<num>();
    return Region(
      id: json['id']! as String,
      name: json['name']! as String,
      level: RegionLevel.values.byName(json['level']! as String),
      west: bbox[0].toDouble(),
      south: bbox[1].toDouble(),
      east: bbox[2].toDouble(),
      north: bbox[3].toDouble(),
      approxBytes: (json['approxBytes']! as num).toInt(),
      parentId: json['parent'] as String?,
      remoteUrl: json['remoteUrl'] as String?,
    );
  }
}

/// Human-readable byte size: "21 MB", "1.8 GB", "140 GB".
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value >= 10 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
