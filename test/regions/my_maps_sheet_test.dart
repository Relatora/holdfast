import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/regions/my_maps_sheet.dart';
import 'package:holdfast/regions/region_files.dart';
import 'package:holdfast/regions/region_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _catalog = '''
{"regions": [
  {"id": "ottawa", "name": "Ottawa–Gatineau", "level": "city", "bbox": [-76.4, 45.2, -75.3, 45.6], "approxBytes": 21000000},
  {"id": "sarnia", "name": "Sarnia–Port Huron", "level": "city", "bbox": [-82.5, 42.9, -82.2, 43.1], "approxBytes": 2400000},
  {"id": "toronto", "name": "Greater Toronto Area", "level": "city", "bbox": [-80, 43.3, -78.6, 44.3], "approxBytes": 52000000}
]}''';

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(utf8.encode(_catalog));
}

class _Files implements RegionFiles {
  final stored = <String>{};
  @override
  bool get storesOffline => true;
  @override
  Future<void> download({
    required String regionId,
    required Uri basemap,
    Uri? pois,
    Uri? routing,
    required void Function(int received, int total) onProgress,
    required DownloadCancel cancel,
  }) async =>
      stored.add(regionId);
  @override
  Future<bool> isDownloaded(String regionId) async => stored.contains(regionId);
  @override
  Future<String> basemapSource(String regionId) async => regionId;
  @override
  Future<String?> readPois(String regionId) async => null;
  @override
  Future<Uint8List?> readRouting(String regionId) async => null;
  @override
  Future<void> saveRouting(String regionId, Uint8List bytes) async {}
  @override
  Future<void> delete(String regionId) async => stored.remove(regionId);
}

void main() {
  late RegionStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final index = jsonEncode({
      'regions': {
        'ottawa': {'pmtilesBytes': 21294091},
        'sarnia': {'pmtilesBytes': 2434593},
      },
    });
    store = RegionStore(
      files: _Files(),
      client: MockClient((r) async => http.Response(index, 200)),
    );
    await store.load(bundle: _Bundle());
    await store.download(store.byId('ottawa')!);
    await store.download(store.byId('sarnia')!);
    await store.activate(store.byId('sarnia')!);
  });

  Future<MyMapsChoice?> open(WidgetTester tester, Future<void> Function() pick) async {
    MyMapsChoice? result;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: store,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showMyMaps(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await pick();
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('lists downloaded maps only, the one on screen first', (tester) async {
    await open(tester, () async {});
    final titles = tester.widgetList<ListTile>(find.byType(ListTile)).map((t) => (t.title! as Text).data).toList();
    expect(titles, ['Sarnia–Port Huron', 'Ottawa–Gatineau']);
    expect(find.text('Greater Toronto Area'), findsNothing, reason: 'not downloaded');
    expect(find.textContaining('On the map now'), findsOneWidget);
  });

  testWidgets('tapping a map returns it to go there', (tester) async {
    final choice = await open(tester, () => tester.tap(find.text('Ottawa–Gatineau')));
    expect(choice, isA<GoToMap>().having((c) => c.region.id, 'region', 'ottawa'));
  });

  testWidgets('offers a way to manage maps', (tester) async {
    final choice = await open(tester, () => tester.tap(find.text('Download or manage maps')));
    expect(choice, isA<ManageMaps>());
  });
}
