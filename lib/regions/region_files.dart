/// Platform-specific storage for downloaded regions.
///
/// Phones and desktops save regions as real files so they work with no
/// connection. Browsers can't hold multi-gigabyte files reliably, so the web
/// build streams tiles from the server instead; it exists for previews and
/// demos, and says so in the UI.
library;

import 'dart:typed_data';

import 'region_files_stub.dart'
    if (dart.library.io) 'region_files_io.dart'
    if (dart.library.js_interop) 'region_files_web.dart' as impl;

/// Lets a running download be stopped from the UI.
class DownloadCancel {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners) {
      listener();
    }
  }

  void onCancel(void Function() listener) => _listeners.add(listener);
}

/// Thrown when a download stops because the user cancelled it.
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();
}

/// Small binary files that travel with a region's map, each built by a tool
/// in `tool/` and decoded by the app.
enum SidePack {
  /// Road and rail network for directions (`RoutingGraph`).
  routing('routing.bin', 'routingBytes'),

  /// People per grid cell, for casualty estimates (`PopulationGrid`).
  population('population.bin', 'populationBytes');

  const SidePack(this.extension, this.indexKey);

  /// File name after the region id: `<id>.<extension>`.
  final String extension;

  /// The size field for this pack in the server's `index.json`.
  final String indexKey;

  String fileName(String regionId) => '$regionId.$extension';
}

abstract class RegionFiles {
  factory RegionFiles() = impl.PlatformRegionFiles;

  /// False on the web, where regions are streamed rather than stored.
  bool get storesOffline;

  /// Downloads a region's basemap and, when the server has them, its POI
  /// pack and side [packs]. [onProgress] receives basemap bytes so far and
  /// the expected total.
  /// Partial downloads resume where they stopped.
  Future<void> download({
    required String regionId,
    required Uri basemap,
    Uri? pois,
    Map<SidePack, Uri> packs = const {},
    required void Function(int received, int total) onProgress,
    required DownloadCancel cancel,
  });

  Future<bool> isDownloaded(String regionId);

  /// A path or URL that `PmTilesArchive.from` can open.
  Future<String> basemapSource(String regionId);

  /// The region's POI pack JSON, or null if it has none.
  Future<String?> readPois(String regionId);

  /// One of the region's side packs, or null if it has none.
  Future<Uint8List?> readPack(String regionId, SidePack pack);

  /// Stores a side pack fetched after the region itself was downloaded
  /// (maps saved before that pack existed), so it works offline next time.
  Future<void> savePack(String regionId, SidePack pack, Uint8List bytes);

  Future<void> delete(String regionId);
}
