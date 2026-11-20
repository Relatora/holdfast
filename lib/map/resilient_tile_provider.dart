import 'dart:typed_data';

import 'package:pmtiles/pmtiles.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

/// The few things the map needs from a tile archive. Kept minimal so tests
/// can substitute a fake without a real PMTiles file.
abstract interface class TileArchive {
  int get minZoom;
  int get maxZoom;

  /// The tile's bytes. Throws [MissingTileException] when the archive simply
  /// has no tile there (outside the region), and anything else on failure.
  Future<List<int>> tileBytes(int z, int x, int y);
}

/// The archive has no tile at this position. Not an error: regions only
/// cover their bounding box.
class MissingTileException implements Exception {
  const MissingTileException();
}

/// [TileArchive] backed by a PMTiles file or URL.
class PmTilesTileArchive implements TileArchive {
  PmTilesTileArchive(this._archive);

  static Future<TileArchive> open(String source) async =>
      PmTilesTileArchive(await PmTilesArchive.from(source));

  final PmTilesArchive _archive;

  @override
  int get minZoom => _archive.minZoom;

  @override
  int get maxZoom => _archive.maxZoom;

  @override
  Future<List<int>> tileBytes(int z, int x, int y) async {
    try {
      final tile = await _archive.tile(ZXY(z, x, y).toTileId());
      return tile.bytes();
    } on TileNotFoundException {
      throw const MissingTileException();
    }
  }
}

/// A tile provider that recovers from failed archive reads.
///
/// Why this exists: the `pmtiles` package caches directory reads as futures
/// and never evicts one that failed. One failed range request (a dropped
/// connection, or a pool timeout during the burst of requests a camera move
/// causes) then fails every tile under that directory for the rest of the
/// session, and the map stays blank.
///
/// So on any failure other than "no tile here", this provider opens a fresh
/// archive, with fresh caches, and retries once. Concurrent failures share a
/// single reopen.
class ResilientTileProvider extends VectorTileProvider {
  ResilientTileProvider._(this._open, this._archive);

  /// Opens the first archive; [open] is called again whenever a read fails.
  static Future<ResilientTileProvider> open(Future<TileArchive> Function() open) async =>
      ResilientTileProvider._(open, await open());

  final Future<TileArchive> Function() _open;
  TileArchive _archive;
  Future<TileArchive>? _reopening;

  /// How many times the archive has been reopened. Exposed for tests.
  int reopenCount = 0;

  /// Tiles requested so far; the basemap layer watches for the first one.
  int requestCount = 0;

  @override
  int get maximumZoom => _archive.maxZoom;

  @override
  int get minimumZoom => _archive.minZoom;

  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    requestCount++;
    for (var attempt = 0;; attempt++) {
      final archive = _archive;
      try {
        return Uint8List.fromList(await archive.tileBytes(tile.z, tile.x, tile.y));
      } on MissingTileException {
        throw ProviderException(
          message: 'No tile at $tile in this region',
          statusCode: 404,
          retryable: Retryable.none,
        );
      } catch (error) {
        if (attempt > 0) {
          throw ProviderException(message: 'Reading $tile failed: $error', retryable: Retryable.retry);
        }
        await _reopenAfterFailureOf(archive);
      }
    }
  }

  Future<void> _reopenAfterFailureOf(TileArchive failed) async {
    // Another tile already replaced the archive that failed: just retry.
    if (!identical(failed, _archive)) return;
    try {
      final pending = _reopening ??= _open().whenComplete(() => _reopening = null);
      final fresh = await pending;
      if (identical(failed, _archive)) {
        _archive = fresh;
        reopenCount++;
      }
    } catch (_) {
      // Couldn't reopen (server unreachable): the retry reports the failure.
    }
  }
}
