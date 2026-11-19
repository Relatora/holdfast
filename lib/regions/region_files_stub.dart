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
  Future<void> delete(String regionId) async {}
}
