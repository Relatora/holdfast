import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pois/poi.dart';

/// Starred places and saved searches, kept on the device.
///
/// Both lists are short and curated by hand, so they live in
/// [SharedPreferences] next to the other settings rather than in a database.
/// That keeps them safe from anything that goes wrong with a map download, the same reasoning as `AppSettings`.
///
/// Starred places are stored as full snapshots, not bare ids: a POI pack
/// belongs to one region, and a favourite must stay listed after its region
/// is switched away from or deleted. Callers that have the live region
/// should prefer its copy (see `PoiIndex.byId`) so refreshed data wins.
class FavoritesStore extends ChangeNotifier {
  FavoritesStore._(this._prefs, this._places, this._searches);

  static Future<FavoritesStore> load() async => FavoritesStore.from(await SharedPreferences.getInstance());

  /// Reads the stored lists. A corrupt entry is dropped rather than
  /// failing start-up: losing one favourite beats losing the app.
  factory FavoritesStore.from(SharedPreferences prefs) {
    final places = <Poi>[];
    for (final raw in prefs.getStringList(_kPlaces) ?? const <String>[]) {
      try {
        final poi = Poi.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
        if (poi != null) places.add(poi);
      } on Object {
        // Skip it; the next save rewrites the list without it.
      }
    }
    return FavoritesStore._(prefs, places, [...?prefs.getStringList(_kSearches)]);
  }

  static const _kPlaces = 'favoritePlaces';
  static const _kSearches = 'savedSearches';

  /// Saved searches beyond this are dropped, oldest first. The list is meant
  /// to be scanned at a glance, not scrolled.
  static const maxSearches = 12;

  final SharedPreferences _prefs;
  final List<Poi> _places;
  final List<String> _searches;

  /// Starred places, most recently starred first.
  List<Poi> get places => List.unmodifiable(_places);

  /// Saved search queries, most recently saved first.
  List<String> get searches => List.unmodifiable(_searches);

  bool isStarred(String poiId) => _places.any((p) => p.id == poiId);

  /// Stars [poi] if it isn't starred, otherwise unstars it. Returns whether
  /// it is starred afterwards, so the caller can say so.
  bool toggleStar(Poi poi) {
    final index = _places.indexWhere((p) => p.id == poi.id);
    if (index >= 0) {
      _places.removeAt(index);
    } else {
      _places.insert(0, poi);
    }
    _savePlaces();
    return index < 0;
  }

  void unstar(String poiId) {
    _places.removeWhere((p) => p.id == poiId);
    _savePlaces();
  }

  /// Normalises a query the way it is matched: trimmed, single-spaced.
  static String _clean(String query) => query.trim().replaceAll(RegExp(r'\s+'), ' ');

  bool isSaved(String query) {
    final key = _clean(query).toLowerCase();
    return key.isNotEmpty && _searches.any((s) => s.toLowerCase() == key);
  }

  /// Saves [query] at the top of the list. Saving it again (in any case)
  /// moves it to the top and keeps the newest spelling.
  void saveSearch(String query) {
    final cleaned = _clean(query);
    if (cleaned.isEmpty) return;
    _searches
      ..removeWhere((s) => s.toLowerCase() == cleaned.toLowerCase())
      ..insert(0, cleaned);
    if (_searches.length > maxSearches) _searches.removeRange(maxSearches, _searches.length);
    _saveSearches();
  }

  void removeSearch(String query) {
    final key = _clean(query).toLowerCase();
    _searches.removeWhere((s) => s.toLowerCase() == key);
    _saveSearches();
  }

  // Writes are fire-and-forget: SharedPreferences updates its in-memory copy
  // synchronously, so reads are consistent even before the disk write ends.
  void _savePlaces() {
    _prefs.setStringList(_kPlaces, [for (final p in _places) jsonEncode(p.toJson())]);
    notifyListeners();
  }

  void _saveSearches() {
    _prefs.setStringList(_kSearches, _searches);
    notifyListeners();
  }
}
