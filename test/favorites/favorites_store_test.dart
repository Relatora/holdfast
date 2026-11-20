import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/favorites/favorites_store.dart';
import 'package:holdfast/pois/poi.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pharmacy = Poi(
  id: 'n1',
  category: PoiCategory.medical,
  name: 'Corner Pharmacy',
  latitude: 45.42,
  longitude: -75.69,
  tags: {'opening_hours': 'Mo-Fr 09:00-18:00'},
);

const _hardware = Poi(id: 'w2', category: PoiCategory.hardware, name: '', latitude: 45.4, longitude: -75.7);

Future<FavoritesStore> _fresh([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return FavoritesStore.from(await SharedPreferences.getInstance());
}

/// A second store over the same preferences: what the next app launch sees.
Future<FavoritesStore> _reopen() async => FavoritesStore.from(await SharedPreferences.getInstance());

void main() {
  group('starred places', () {
    test('toggle stars, then unstars, and reports the new state', () async {
      final store = await _fresh();
      expect(store.toggleStar(_pharmacy), isTrue);
      expect(store.isStarred('n1'), isTrue);
      expect(store.toggleStar(_pharmacy), isFalse);
      expect(store.isStarred('n1'), isFalse);
    });

    test('newest first, and the full place survives a restart', () async {
      final store = await _fresh();
      store
        ..toggleStar(_pharmacy)
        ..toggleStar(_hardware);

      final reopened = await _reopen();
      expect(reopened.places.map((p) => p.id), ['w2', 'n1']);
      final pharmacy = reopened.places.last;
      expect(pharmacy.title, 'Corner Pharmacy');
      expect(pharmacy.category, PoiCategory.medical);
      expect(pharmacy.latitude, 45.42);
      expect(pharmacy.tags['opening_hours'], 'Mo-Fr 09:00-18:00');
      // A nameless place keeps falling back to its category label.
      expect(reopened.places.first.title, 'Hardware');
    });

    test('a corrupt stored entry is skipped, not fatal', () async {
      final store = await _fresh({
        'favoritePlaces': ['{not json', '{"id":"n9","cat":"water","lat":1,"lon":2}'],
      });
      expect(store.places.map((p) => p.id), ['n9']);
    });

    test('notifies listeners on every change', () async {
      final store = await _fresh();
      var notified = 0;
      store.addListener(() => notified++);
      store
        ..toggleStar(_pharmacy)
        ..unstar('n1');
      expect(notified, 2);
    });
  });

  group('saved searches', () {
    test('trims, collapses spaces and ignores empty queries', () async {
      final store = await _fresh();
      store
        ..saveSearch('   ')
        ..saveSearch('  canadian   tire ');
      expect(store.searches, ['canadian tire']);
      expect(store.isSaved('Canadian Tire'), isTrue);
      expect(store.isSaved(''), isFalse);
    });

    test('saving again moves it to the top without a duplicate', () async {
      final store = await _fresh();
      store
        ..saveSearch('pharmacy')
        ..saveSearch('water')
        ..saveSearch('PHARMACY');
      expect(store.searches, ['PHARMACY', 'water']);
    });

    test('keeps only the newest ${FavoritesStore.maxSearches}', () async {
      final store = await _fresh();
      for (var i = 0; i < FavoritesStore.maxSearches + 3; i++) {
        store.saveSearch('query $i');
      }
      expect(store.searches, hasLength(FavoritesStore.maxSearches));
      expect(store.searches.first, 'query ${FavoritesStore.maxSearches + 2}');
      expect(store.searches, isNot(contains('query 0')));
    });

    test('remove ignores case and persists', () async {
      final store = await _fresh();
      store
        ..saveSearch('Walmart')
        ..saveSearch('fuel')
        ..removeSearch('walmart');
      expect((await _reopen()).searches, ['fuel']);
    });
  });
}
