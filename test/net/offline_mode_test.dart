import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_repository.dart';
import 'package:holdfast/net/network_gate.dart';
import 'package:holdfast/regions/region_files.dart';
import 'package:holdfast/regions/region_store.dart';
import 'package:holdfast/sync/sync_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A server that answers everything and counts what it was asked.
class _Server {
  final requests = <String>[];

  http.Response handle(http.Request request) {
    requests.add('${request.method} ${request.url.path}');
    if (request.url.path.endsWith('/index.json')) {
      return http.Response(
        jsonEncode({
          'regions': {
            'ottawa': {'pmtilesBytes': 1000},
          },
        }),
        200,
      );
    }
    if (request.url.path.endsWith('/v1/events') && request.method == 'GET') {
      return http.Response('{"events": [], "cursor": 0}', 200);
    }
    return http.Response('{}', 200);
  }
}

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(utf8.encode('''
{"regions": [
  {"id": "ottawa", "name": "Ottawa", "level": "city", "bbox": [-76.4, 45.2, -75.3, 45.6], "approxBytes": 1000}
]}'''));
}

class _NoFiles implements RegionFiles {
  int downloads = 0;

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
  }) async => downloads++;

  @override
  Future<bool> isDownloaded(String regionId) async => false;

  @override
  Future<String> basemapSource(String regionId) async => regionId;

  @override
  Future<String?> readPois(String regionId) async => null;

  @override
  Future<Uint8List?> readPack(String regionId, SidePack pack) async => null;

  @override
  Future<void> savePack(String regionId, SidePack pack, Uint8List bytes) async {}

  @override
  Future<void> delete(String regionId) async {}
}

/// Lets queued microtasks and timers of zero length run.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Server server;
  late NetworkGate gate;
  late http.Client client;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = _Server();
    gate = NetworkGate(online: false);
    client = GatedClient(gate, MockClient((r) async => server.handle(r)));
  });

  group('GatedClient', () {
    test('refuses every request in offline mode, without touching the network', () async {
      await expectLater(client.get(Uri.parse('http://test/x')), throwsA(isA<OfflineModeException>()));
      expect(server.requests, isEmpty);
    });

    test('passes requests through when online', () async {
      gate.online = true;
      final response = await client.get(Uri.parse('http://test/x'));
      expect(response.statusCode, 200);
      expect(server.requests, ['GET /x']);
    });
  });

  group('hazard reports', () {
    test('wait on the device in offline mode and send as soon as it ends', () async {
      final repo = HazardRepository(deviceId: 'me', sync: SyncClient('http://test', client: client), network: gate);
      await repo.load();
      await repo.report(type: HazardType.flood, severity: HazardSeverity.high, latitude: 45, longitude: -75);
      await settle();

      expect(server.requests, isEmpty);
      expect(repo.syncStatus, SyncStatus.paused);
      expect(repo.hazards, hasLength(1), reason: 'the report is on the map all the same');

      gate.online = true;
      await settle();
      while (repo.syncStatus == SyncStatus.syncing) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(server.requests, contains('POST /v1/events'));
      expect(repo.syncStatus, SyncStatus.synced);
      repo.dispose();
    });
  });

  group('maps', () {
    test('offline mode asks the server nothing and downloads nothing', () async {
      final files = _NoFiles();
      final store = RegionStore(files: files, client: client, network: gate);
      await store.load(bundle: _Bundle());
      final ottawa = store.byId('ottawa')!;

      expect(server.requests, isEmpty);
      expect(store.unavailableReason(ottawa), UnavailableReason.offlineMode);
      await store.download(ottawa);
      expect(files.downloads, 0);

      gate.online = true;
      await settle();
      expect(server.requests, ['GET /regions/index.json']);
      expect(store.stateOf(ottawa).phase, RegionPhase.available);
    });
  });
}
