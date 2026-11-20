/// Supply locations ("points of interest") and the categories people filter
/// them by.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// What a place can supply in an emergency.
///
/// The ids match the `cat` values written by `tool/import_pois.py`, which
/// is where OpenStreetMap tags are mapped onto these categories.
enum PoiCategory {
  bigbox('bigbox', 'Big-box', 'Big-box & general store', Icons.store_mall_directory_rounded, Color(0xFFE0A030)),
  grocery('grocery', 'Food', 'Grocery', Icons.shopping_basket_rounded, Color(0xFF5DAA5A)),
  hardware('hardware', 'Tools', 'Hardware', Icons.handyman_rounded, Color(0xFFB07A4F)),
  outdoor('outdoor', 'Outdoor', 'Outdoor & sporting', Icons.forest_rounded, Color(0xFF3E8E7E)),
  medical('medical', 'Medical', 'Medical', Icons.local_hospital_rounded, Color(0xFFE0565B)),
  water('water', 'Water', 'Drinking water', Icons.water_drop_rounded, Color(0xFF3A8FD6)),
  fuel('fuel', 'Fuel', 'Fuel & propane', Icons.local_gas_station_rounded, Color(0xFF8E6BD8)),
  shelter('shelter', 'Shelter', 'Shelter & safety', Icons.night_shelter_rounded, Color(0xFF6B7F99));

  const PoiCategory(this.id, this.shortLabel, this.label, this.icon, this.color);

  final String id;

  /// Fits on a filter chip.
  final String shortLabel;

  /// Used as a place's title when it has no name in OpenStreetMap.
  final String label;
  final IconData icon;

  /// Brand colour on light and dark maps. Night vision overrides it with red.
  final Color color;

  static PoiCategory? tryParse(String id) {
    for (final category in values) {
      if (category.id == id) return category;
    }
    return null;
  }
}

/// One place from a region's POI pack.
class Poi {
  const Poi({
    required this.id,
    required this.category,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.tags = const {},
  });

  /// OpenStreetMap element id, e.g. `n123` (node) or `w456` (way).
  final String id;
  final PoiCategory category;
  final String name;
  final double latitude;
  final double longitude;

  /// The handful of OSM tags the import keeps: brand, hours, phone, address.
  final Map<String, String> tags;

  /// What to show as a title: the name, else the brand, else the category.
  String get title => name.isNotEmpty ? name : (tags['brand'] ?? category.label);

  /// One-line street address when the data has one.
  String? get address {
    final street = tags['addr:street'];
    if (street == null) return null;
    final number = tags['addr:housenumber'];
    final city = tags['addr:city'];
    return [if (number != null) '$number $street' else street, ?city].join(', ');
  }

  static Poi? fromJson(Map<String, Object?> json) {
    final category = PoiCategory.tryParse(json['cat'] as String? ?? '');
    if (category == null) return null; // newer pack with a category we don't know
    return Poi(
      id: json['id']! as String,
      category: category,
      name: (json['name'] as String?) ?? '',
      latitude: (json['lat']! as num).toDouble(),
      longitude: (json['lon']! as num).toDouble(),
      tags: ((json['tags'] as Map?) ?? const {}).cast<String, String>(),
    );
  }

  /// The same shape [fromJson] reads, so a place can be saved on its own
  /// (a starred place outlives the region pack it came from).
  Map<String, Object?> toJson() => {
        'id': id,
        'cat': category.id,
        if (name.isNotEmpty) 'name': name,
        'lat': latitude,
        'lon': longitude,
        if (tags.isNotEmpty) 'tags': tags,
      };
}

/// Great-circle distance in metres (haversine). Accurate to well under 1%
/// at city scale, which is all "nearest supplies" needs.
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadius = 6371000.0;
  double rad(double deg) => deg * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadius * math.asin(math.sqrt(a));
}

/// "850 m", "2.4 km", "38 km".
String formatDistance(double meters) {
  if (meters < 1000) return '${(meters / 10).round() * 10} m';
  if (meters < 10000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${(meters / 1000).round()} km';
}
