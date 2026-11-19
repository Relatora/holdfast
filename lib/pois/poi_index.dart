import 'poi.dart';

/// A place plus how far it is from the point that was asked about.
typedef PoiHit = ({Poi poi, double meters});

/// In-memory search over one region's POI pack.
///
/// A city pack holds a few thousand places, so a linear scan answers
/// "nearest" in well under a millisecond and keeps this class trivially
/// correct. Province-sized packs (tens of thousands of places) are where an
/// SQLite R-tree index takes over; that swap only has to keep this API.
class PoiIndex {
  PoiIndex(List<Poi> pois) : pois = List.unmodifiable(pois);

  /// Parses the JSON written by `tool/import_pois.py`.
  factory PoiIndex.fromPack(Map<String, Object?> pack) {
    final raw = (pack['pois'] as List<Object?>?) ?? const [];
    return PoiIndex([
      for (final item in raw) ?Poi.fromJson((item! as Map).cast<String, Object?>()),
    ]);
  }

  static final empty = PoiIndex(const []);

  final List<Poi> pois;

  bool get isEmpty => pois.isEmpty;

  /// Places of the given [categories] (all when empty) whose title contains
  /// [query], case-insensitively.
  List<Poi> filter({Set<PoiCategory> categories = const {}, String query = ''}) {
    final needle = query.trim().toLowerCase();
    return [
      for (final poi in pois)
        if ((categories.isEmpty || categories.contains(poi.category)) &&
            (needle.isEmpty ||
                poi.title.toLowerCase().contains(needle) ||
                (poi.tags['brand']?.toLowerCase().contains(needle) ?? false)))
          poi,
    ];
  }

  /// The [limit] closest places to a point, nearest first.
  List<PoiHit> nearest(
    double latitude,
    double longitude, {
    int limit = 10,
    Set<PoiCategory> categories = const {},
  }) {
    final hits = [
      for (final poi in pois)
        if (categories.isEmpty || categories.contains(poi.category))
          (poi: poi, meters: distanceMeters(latitude, longitude, poi.latitude, poi.longitude)),
    ]..sort((a, b) => a.meters.compareTo(b.meters));
    return hits.take(limit).toList();
  }

  /// The single closest place in each category: the "what's nearest of
  /// everything" summary the radar shows.
  List<PoiHit> nearestPerCategory(double latitude, double longitude) {
    final best = <PoiCategory, PoiHit>{};
    for (final poi in pois) {
      final meters = distanceMeters(latitude, longitude, poi.latitude, poi.longitude);
      final current = best[poi.category];
      if (current == null || meters < current.meters) {
        best[poi.category] = (poi: poi, meters: meters);
      }
    }
    return best.values.toList()..sort((a, b) => a.meters.compareTo(b.meters));
  }
}
