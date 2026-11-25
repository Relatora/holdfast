import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/config.dart';
import 'package:holdfast/regions/region_files.dart';
import 'package:holdfast/regions/region_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _catalog = '''
{"regions": [
  {"id": "ontario", "name": "Ontario", "level": "province", "parent": "canada", "bbox": [-95, 41, -74, 57], "approxBytes": 2300000000},
  {"id": "ottawa", "name": "Ottawa–Gatineau", "level": "city", "parent": "ontario", "bbox": [-76.4, 45.2, -75.3, 45.6], "approxBytes": 21000000},
  {"id": "sarnia", "name": "Sarnia–Port Huron", "level": "city", "parent": "ontario", "bbox": [-82.5, 42.9, -82.2, 43.1], "approxBytes": 2400000},
  {"id": "europe", "name": "Europe", "level": "continent", "bbox": [-25, 34, 45, 72], "approxBytes": 46000000000}
]}''';

/// Serves the catalog from memory instead of the app's asset bundle.
class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(utf8.encode(_catalog));
}

/// Records downloads instead of writing files.
class _FakeFiles implements RegionFiles {
  final downloaded = <String>[];

  /// The `restart` flag of every download, in order.
  final restarts = <bool>[];

  /// When set, the next download throws this instead of finishing.
  Object? failNext;

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
  }) async {
    restarts.add(restart);
    onProgress(1, 2);
    if (failNext case final error?) {
      failNext = null;
      throw error;
    }
    onProgress(2, 2);
    if (!downloaded.contains(regionId)) downloaded.add(regionId);
  }

  @override
  Future<bool> isDownloaded(String regionId) async => downloaded.contains(regionId);

  @override
  Future<String> basemapSource(String regionId) async => regionId;

  @override
  Future<String?> readPois(String regionId) async => null;

  @override
  Future<Uint8List?> readPack(String regionId, SidePack pack) async => null;

  @override
  Future<void> savePack(String regionId, SidePack pack, Uint8List bytes) async {}

  @override
  Future<void> delete(String regionId) async => downloaded.remove(regionId);
}

/// A region server with Ottawa hosted, a 3 GB prepare limit and a job that
/// finishes on the third status check.
class _FakeServer {
  final hosted = <String, int>{'ottawa': 21294091};

  /// Build times sent in index.json; regions without one are sent without
  /// (like a server older than 0.4).
  final builtAt = <String, DateTime>{};

  /// Hosted regions whose supply list is missing.
  final mapOnly = <String>{};
  final requests = <String>[];
  int statusChecks = 0;

  http.Response handle(http.Request request) {
    final path = request.url.path.replaceFirst(Uri.parse(Config.regionsUrl).path, '');
    requests.add('${request.method} $path');
    if (path == '/index.json') {
      return http.Response(
        jsonEncode({
          'regions': {
            for (final e in hosted.entries)
              e.key: {
                'pmtilesBytes': e.value,
                if (builtAt[e.key] case final built?) 'builtAt': built.toIso8601String(),
                if (!mapOnly.contains(e.key)) ...{'poisBytes': 1000, 'routingBytes': 1000, 'populationBytes': 100},
              },
          },
          'prepare': {'enabled': true, 'maxBytes': 3000000000},
          'jobs': {},
        }),
        200,
      );
    }
    if (path == '/sarnia/prepare') {
      if (request.method == 'GET') statusChecks++;
      final done = statusChecks >= 3;
      if (done) {
        hosted['sarnia'] = 2434593;
        mapOnly.remove('sarnia');
      }
      return http.Response(
        jsonEncode({
          'regionId': 'sarnia',
          'state': done ? 'done' : 'running',
          'step': 'map',
          'bytesDone': statusChecks * 800000,
          'bytesTotal': 2400000,
        }),
        request.method == 'POST' ? 202 : 200,
      );
    }
    return http.Response('{"error": "not found"}', 404);
  }
}

void main() {
  late _FakeServer server;
  late _FakeFiles files;
  late RegionStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    RegionStore.pollInterval = Duration.zero;
    server = _FakeServer();
    files = _FakeFiles();
    store = RegionStore(files: files, client: MockClient((r) async => server.handle(r)));
    await store.load(bundle: _Bundle());
  });

  test('regions the server lacks are preparable unless over its limit', () {
    expect(store.stateOf(store.byId('ottawa')!).phase, RegionPhase.available);
    expect(store.stateOf(store.byId('sarnia')!).phase, RegionPhase.preparable);
    expect(store.stateOf(store.byId('ontario')!).phase, RegionPhase.preparable);
    final europe = store.byId('europe')!;
    expect(store.stateOf(europe).phase, RegionPhase.unavailable);
    expect(store.unavailableReason(europe), UnavailableReason.tooBig);
  });

  test('downloading an unhosted region prepares it on the server first', () async {
    final phases = <RegionPhase>[];
    store.addListener(() => phases.add(store.stateOf(store.byId('sarnia')!).phase));

    await store.download(store.byId('sarnia')!);

    expect(server.requests.first, 'GET /index.json');
    expect(server.requests, contains('POST /sarnia/prepare'));
    expect(server.statusChecks, 3);
    expect(phases, containsAllInOrder([RegionPhase.preparing, RegionPhase.downloading, RegionPhase.ready]));
    expect(files.downloaded, ['sarnia']);
    expect(store.sizeOf(store.byId('sarnia')!), 2434593, reason: 'the real size replaces the estimate');
  });

  test('a hosted city missing its supply list asks the server to finish it', () async {
    server.hosted.remove('ottawa');
    server.hosted['sarnia'] = 2434593;
    server.mapOnly.add('sarnia');
    await store.refreshHosted();

    await store.download(store.byId('sarnia')!);

    expect(server.requests, contains('POST /sarnia/prepare'));
    expect(files.downloaded, ['sarnia']);
  });

  test('a hosted region downloads without asking for preparation', () async {
    await store.download(store.byId('ottawa')!);
    expect(server.requests.where((r) => r.contains('prepare')), isEmpty);
    expect(files.downloaded, ['ottawa']);
  });

  test('a refused preparation leaves the region failed with the reason', () async {
    server.hosted.clear();
    final store2 = RegionStore(
      files: files,
      client: MockClient((r) async => r.url.path.endsWith('/prepare')
          ? http.Response('{"error": "europe is larger than this server prepares"}', 413)
          : server.handle(r)),
    );
    await store2.load(bundle: _Bundle());
    // Pretend the limit allowed it, so the request is actually sent.
    store2.prepareMaxBytes = 1 << 62;

    await store2.download(store2.byId('europe')!);

    final state = store2.stateOf(store2.byId('europe')!);
    expect(state.phase, RegionPhase.failed);
    expect(state.error, contains('larger than this server'));
  });

  test('search matches a region or its parent, without regard to case', () {
    expect(store.search('SARN').map((r) => r.id), ['sarnia']);
    expect(store.search('ontario').map((r) => r.id), ['ontario', 'ottawa', 'sarnia']);
    expect(store.search('  '), isEmpty);
  });

  group('updates', () {
    final october = DateTime.utc(2026, 10, 1);
    final november = DateTime.utc(2026, 11, 20);

    Future<void> serverRebuildsOttawa() async {
      server.builtAt['ottawa'] = november;
      await store.refreshHosted();
    }

    setUp(() async {
      server.builtAt['ottawa'] = october;
      await store.refreshHosted();
    });

    test('a newer server build is offered as an update, and applying it reloads the map', () async {
      final ottawa = store.byId('ottawa')!;
      await store.download(ottawa);
      expect(store.builtAt(ottawa), october);
      expect(store.updateAvailable(ottawa), isFalse);
      final keyBefore = store.dataKey(ottawa);

      await serverRebuildsOttawa();
      expect(store.updateAvailable(ottawa), isTrue);
      expect(store.updatable, [ottawa]);

      final phases = <RegionPhase>[];
      store.addListener(() => phases.add(store.stateOf(ottawa).phase));
      await store.updateAll();

      expect(phases, contains(RegionPhase.updating));
      expect(phases, isNot(contains(RegionPhase.downloading)), reason: 'an update never hides the map');
      expect(store.stateOf(ottawa).phase, RegionPhase.ready);
      expect(store.builtAt(ottawa), november);
      expect(store.updateAvailable(ottawa), isFalse);
      expect(store.dataKey(ottawa), isNot(keyBefore), reason: 'caches must load the new files');
    });

    test('a failed update keeps the old map and says why', () async {
      final ottawa = store.byId('ottawa')!;
      await store.download(ottawa);
      await serverRebuildsOttawa();

      files.failNext = StateError('connection reset');
      await store.update(ottawa);

      expect(store.stateOf(ottawa).phase, RegionPhase.ready);
      expect(store.updateError(ottawa), contains('connection reset'));
      expect(store.updateAvailable(ottawa), isTrue, reason: 'still offered, to try again');
      expect(store.builtAt(ottawa), october);
    });

    test('a partial download of an older build starts over instead of resuming', () async {
      final ottawa = store.byId('ottawa')!;
      files.failNext = const DownloadCancelledException();
      await store.download(ottawa); // stopped part way, against October's build
      await store.download(ottawa); // same build: resume
      expect(files.restarts, [false, false]);

      await store.remove(ottawa);
      files.failNext = const DownloadCancelledException();
      await store.download(ottawa); // October again, stopped
      await serverRebuildsOttawa();
      await store.download(ottawa); // November: the October bytes must go
      expect(files.restarts.last, isTrue);
    });

    test('maps downloaded before builds were tracked are taken to be current', () async {
      SharedPreferences.setMockInitialValues({
        'readyRegions': ['ottawa'],
      });
      files.downloaded.add('ottawa');
      final upgraded = RegionStore(files: files, client: MockClient((r) async => server.handle(r)));
      await upgraded.load(bundle: _Bundle());
      final ottawa = upgraded.byId('ottawa')!;
      expect(upgraded.updateAvailable(ottawa), isFalse);
      expect(upgraded.builtAt(ottawa), october);

      server.builtAt['ottawa'] = november;
      await upgraded.refreshHosted();
      expect(upgraded.updateAvailable(ottawa), isTrue);
    });

    test('a server that sends no build times offers no updates', () async {
      final ottawa = store.byId('ottawa')!;
      await store.download(ottawa);
      server.builtAt.clear();
      await store.refreshHosted();
      expect(store.updateAvailable(ottawa), isFalse);
    });
  });

  test('On this device lists stored maps with the active one first', () async {
    expect(store.deviceRegions, isEmpty);
    await store.download(store.byId('ottawa')!);
    await store.download(store.byId('sarnia')!);
    await store.activate(store.byId('sarnia')!);
    expect(store.deviceRegions.map((r) => r.id), ['sarnia', 'ottawa']);
  });
}
