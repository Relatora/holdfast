import 'dart:typed_data';

import 'region_files.dart';

/// Placeholder for platforms with neither `dart:io` nor JS interop. Never
/// used in practice; it only satisfies the conditional import.
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
  }) =>
      throw UnsupportedError('No storage on this platform');

  @override
  Future<bool> isDownloaded(String regionId) async => false;

  @override
  Future<String> basemapSource(String regionId) => throw UnsupportedError('No storage on this platform');

  @override
  Future<String?> readPois(String regionId) async => null;

  @override
  Future<Uint8List?> readRouting(String regionId) async => null;

  @override
  Future<void> saveRouting(String regionId, Uint8List bytes) async {}

  @override
  Future<void> delete(String regionId) async {}
}
