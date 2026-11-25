import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'region_files.dart';

/// Web build: nothing is stored; the map streams tiles from the server with
/// HTTP range requests, and the POI pack is fetched on demand.
class PlatformRegionFiles implements RegionFiles {
  // Takes the same arguments as the real one; nothing here downloads.
  PlatformRegionFiles({http.Client Function()? newClient});

  @override
  bool get storesOffline => false;

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
    // "Downloading" on the web just means "start streaming this region".
    onProgress(1, 1);
  }

  @override
  Future<bool> isDownloaded(String regionId) async => false;

  @override
  Future<String> basemapSource(String regionId) =>
      throw UnsupportedError('The web build streams regions instead of storing them');

  @override
  Future<String?> readPois(String regionId) async => null;

  @override
  Future<Uint8List?> readPack(String regionId, SidePack pack) async => null;

  @override
  Future<void> savePack(String regionId, SidePack pack, Uint8List bytes) async {}

  @override
  Future<void> delete(String regionId) async {}
}
