import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'region_files.dart';

/// Placeholder for platforms with neither `dart:io` nor JS interop. Never
/// used in practice; it only satisfies the conditional import.
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
  }) =>
      throw UnsupportedError('No storage on this platform');

  @override
  Future<bool> isDownloaded(String regionId) async => false;

  @override
  Future<String> basemapSource(String regionId) => throw UnsupportedError('No storage on this platform');

  @override
  Future<String?> readPois(String regionId) async => null;

  @override
  Future<Uint8List?> readPack(String regionId, SidePack pack) async => null;

  @override
  Future<void> savePack(String regionId, SidePack pack, Uint8List bytes) async {}

  @override
  Future<void> delete(String regionId) async {}
}
