import 'dart:typed_data';

import 'region_files.dart';

/// Web build: nothing is stored; the map streams tiles from the server with
/// HTTP range requests, and the POI pack is fetched on demand.
class PlatformRegionFiles implements RegionFiles {
  @override
  bool get storesOffline => false;

  @override
  Future<void> download({
    required String regionId,
    required Uri basemap,
    Uri? pois,
    Uri? routing,
    required void Function(int received, int total) onProgress,
    required DownloadCancel cancel,
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
  Future<Uint8List?> readRouting(String regionId) async => null;

  @override
  Future<void> saveRouting(String regionId, Uint8List bytes) async {}

  @override
  Future<void> delete(String regionId) async {}
}
