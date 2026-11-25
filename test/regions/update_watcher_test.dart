import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/notify/notifications.dart';
import 'package:holdfast/regions/region.dart';
import 'package:holdfast/regions/region_files.dart';
import 'package:holdfast/regions/region_store.dart';
import 'package:holdfast/regions/update_watcher.dart';
import 'package:holdfast/settings/app_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Region region(String id, String name) =>
    Region(id: id, name: name, level: RegionLevel.city, west: 0, south: 0, east: 1, north: 1, approxBytes: 1);

final ottawa = region('ottawa', 'Ottawa');
final sarnia = region('sarnia', 'Sarnia');
final toronto = region('toronto', 'Toronto');
final noon = DateTime.utc(2026, 11, 25, 12);

UpdateNotice? decide(
  List<Region> waiting, {
  Set<String> announced = const {},
  DateTime? lastNotice,
  UpdateNoticeFrequency frequency = UpdateNoticeFrequency.everyUpdate,
  DateTime? now,
}) =>
    UpdateWatcher.decide(
      waiting: [for (final r in waiting) (key: '${r.id}@v2', region: r)],
      announced: announced,
      lastNotice: lastNotice,
      frequency: frequency,
      now: now ?? noon,
    );

/// Records notifications instead of showing them. Like Android, it drops a
/// notification shown before permission was granted.
class _Recorder implements Notifications {
  final shown = <String>[];
  int permissionRequests = 0;
  bool granted = false;

  /// Completes the pending permission request when the test says so.
  Completer<bool>? answer;

  @override
  Future<void> show(NoticeKind kind, {required String title, required String body}) async {
    if (granted) shown.add(title);
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    final allowed = await (answer?.future ?? Future.value(true));
    granted = allowed;
    return allowed;
  }
}

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(utf8.encode('''
{"regions": [
  {"id": "ottawa", "name": "Ottawa", "level": "city", "bbox": [-76.4, 45.2, -75.3, 45.6], "approxBytes": 1000}
]}'''));
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
    Map<SidePack, Uri> packs = const {},
    required void Function(int received, int total) onProgress,
    required DownloadCancel cancel,
    bool restart = false,
  }) async => stored.add(regionId);

  @override
  Future<bool> isDownloaded(String regionId) async => stored.contains(regionId);

  @override
  Future<String> basemapSource(String regionId) async => regionId;

  @override
  Future<String?> readPois(String regionId) async => null;

  @override
  Future<Uint8List?> readPack(String regionId, SidePack pack) async => null;

  @override
  Future<void> savePack(String regionId, SidePack pack, Uint8List bytes) async {}

  @override
  Future<void> delete(String regionId) async => stored.remove(regionId);
}

void main() {
  group('when to notify', () {
    test('every update: a new build is announced at once, and only once', () {
      final notice = decide([ottawa]);
      expect(notice?.title, 'Newer map for Ottawa');
      expect(notice?.keys, ['ottawa@v2']);
      expect(decide([ottawa], announced: {'ottawa@v2'}), isNull);
    });

    test('names two maps, and counts more', () {
      expect(decide([ottawa, sarnia])?.title, 'Newer maps for Ottawa and Sarnia');
      expect(decide([ottawa, sarnia, toronto])?.title, 'Newer maps for 3 of your maps');
    });

    test('a daily summary waits a day after the last one, then covers everything new', () {
      final daily = UpdateNoticeFrequency.daily;
      final lastNotice = noon.subtract(const Duration(hours: 5));
      expect(decide([sarnia], lastNotice: lastNotice, frequency: daily), isNull);

      final later = noon.add(const Duration(hours: 20));
      final notice = decide([ottawa, sarnia], announced: {'ottawa@v2'}, lastNotice: lastNotice, frequency: daily, now: later);
      expect(notice?.keys, ['sarnia@v2'], reason: 'Ottawa was announced already');
    });

    test('a weekly summary waits a week', () {
      final weekly = UpdateNoticeFrequency.weekly;
      expect(decide([ottawa], lastNotice: noon.subtract(const Duration(days: 6)), frequency: weekly), isNull);
      expect(decide([ottawa], lastNotice: noon.subtract(const Duration(days: 8)), frequency: weekly), isNotNull);
    });

    test('never means never', () {
      expect(decide([ottawa, sarnia], frequency: UpdateNoticeFrequency.never), isNull);
    });
  });

  group('watching', () {
    late DateTime built;
    late RegionStore store;
    late AppSettings settings;
    late _Recorder notifications;
    late UpdateWatcher watcher;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      built = DateTime.utc(2026, 11, 1);
      final server = MockClient((request) async {
        if (!request.url.path.endsWith('/index.json')) return http.Response('', 200);
        return http.Response(
          jsonEncode({
            'regions': {
              'ottawa': {'pmtilesBytes': 1000, 'builtAt': built.toIso8601String()},
            },
          }),
          200,
        );
      });
      store = RegionStore(files: _Files(), client: server);
      await store.load(bundle: _Bundle());
      settings = await AppSettings.load();
      notifications = _Recorder();
      watcher = UpdateWatcher(regions: store, settings: settings, notifications: notifications)..start();
    });

    tearDown(() => watcher.dispose());

    test('asks for permission once, when the first map arrives', () async {
      expect(notifications.permissionRequests, 0, reason: 'never at start-up');
      await store.download(store.byId('ottawa')!);
      await pumpEventQueue();
      expect(notifications.permissionRequests, 1);
      await store.refreshHosted();
      await pumpEventQueue();
      expect(notifications.permissionRequests, 1);
    });

    test('a notification waits for the permission answer, so it is not dropped', () async {
      notifications.answer = Completer<bool>();
      await store.download(store.byId('ottawa')!); // first map: the request goes out
      built = DateTime.utc(2026, 12, 1);
      await store.refreshHosted(); // a newer build while the dialog is still open
      await pumpEventQueue();
      expect(notifications.shown, isEmpty);

      notifications.answer!.complete(true);
      await pumpEventQueue();
      expect(notifications.shown, ['Newer map for Ottawa']);
    });

    test('notifies when the server has a newer build, once per build', () async {
      await store.download(store.byId('ottawa')!);
      await pumpEventQueue();
      expect(notifications.shown, isEmpty);

      built = DateTime.utc(2026, 12, 1);
      await store.refreshHosted();
      await pumpEventQueue();
      expect(notifications.shown, ['Newer map for Ottawa']);

      await store.refreshHosted(); // the same build again
      await pumpEventQueue();
      expect(notifications.shown, hasLength(1));
    });
  });
}
