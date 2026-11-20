import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/favorites/favorites_store.dart';
import 'package:holdfast/home/map_overlays.dart';
import 'package:holdfast/pois/poi.dart';
import 'package:holdfast/pois/poi_index.dart';
import 'package:holdfast/settings/app_settings.dart';
import 'package:holdfast/theme/app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _index = PoiIndex(const [
  Poi(id: 'n1', category: PoiCategory.medical, name: 'Corner Pharmacy', latitude: 45.42, longitude: -75.69),
  Poi(id: 'n2', category: PoiCategory.bigbox, name: 'Canadian Tire', latitude: 45.41, longitude: -75.70),
]);

void main() {
  late AppSettings settings;
  late FavoritesStore favorites;
  late List<Poi> selected;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load();
    favorites = FavoritesStore.from(await SharedPreferences.getInstance());
    selected = [];
  });

  Future<void> openSearch(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: favorites),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: PlaceSearchBar(index: _index, onSelected: selected.add, onOpenSettings: () {}),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SearchBar));
    await tester.pumpAndSettle();
  }

  testWidgets('an empty search explains favourites', (tester) async {
    await openSearch(tester);
    expect(find.text('No favourites yet'), findsOneWidget);
  });

  testWidgets('a star fills in immediately, without another keystroke', (tester) async {
    await openSearch(tester);
    await tester.enterText(find.byType(TextField).last, 'pharm');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Star this place'));
    await tester.pump();

    expect(favorites.isStarred('n1'), isTrue);
    expect(find.byTooltip('Remove from starred places'), findsOneWidget);
  });

  testWidgets('a saved search shows as a chip and reruns on tap', (tester) async {
    await openSearch(tester);
    await tester.enterText(find.byType(TextField).last, 'canadian');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save this search'));
    await tester.pump();
    expect(find.text('Search saved'), findsOneWidget);

    // Clear the query: the favourites view lists the saved search.
    await tester.enterText(find.byType(TextField).last, '');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InputChip, 'canadian'));
    await tester.pumpAndSettle();

    expect(find.text('Canadian Tire'), findsOneWidget);
  });

  testWidgets('a starred place is listed and selecting it reports the place', (tester) async {
    favorites.toggleStar(_index.byId('n2')!);
    await openSearch(tester);

    expect(find.text('Starred places'), findsOneWidget);
    await tester.tap(find.text('Canadian Tire'));
    await tester.pumpAndSettle();

    expect(selected.map((p) => p.id), ['n2']);
  });
}
