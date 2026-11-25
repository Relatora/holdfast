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

/// Several archives read as one: the downloaded maps first, in order, then
/// (online) the streamed planet build for whatever they don't cover.
///
/// This is what lets an online map show the whole world while every tile
/// inside a downloaded region still comes from the device: a tile reaches
/// the network only when no local archive has it.
///
/// The stream is opened on first use, not up front, so an unreachable
/// server never delays or breaks the local maps. If opening it fails, the
/// layer treats the streamed area as empty and tries again after
/// [remoteRetry].
class LayeredTileArchive implements TileArchive {
  LayeredTileArchive(
    this._local, {
    Future<TileArchive> Function()? openRemote,
    this.remoteMaxZoom = 15,
    this.remoteRetry = const Duration(seconds: 30),
    DateTime Function()? clock,
  })  : // A named parameter can't be private, so it can't set the field.
        // ignore: prefer_initializing_formals
        _openRemote = openRemote,
        _clock = clock ?? DateTime.now;

  /// Opens [local] (paths or URLs) now and [remote] when first needed.
  static Future<TileArchive> open(List<String> local, {String? remote}) async => LayeredTileArchive(
        [for (final source in local) await PmTilesTileArchive.open(source)],
        openRemote: remote == null ? null : () => PmTilesTileArchive.open(remote),
      );

  final List<TileArchive> _local;
  final Future<TileArchive> Function()? _openRemote;

  /// The streamed build's top zoom, known before it is opened. Protomaps
  /// planet builds go to z15.
  final int remoteMaxZoom;
  final Duration remoteRetry;
  final DateTime Function() _clock;

  Future<TileArchive>? _remote;
  DateTime? _remoteFailedAt;

  @override
  int get minZoom => _local.isEmpty ? 0 : _local.map((a) => a.minZoom).reduce((a, b) => a < b ? a : b);

  /// The lowest top zoom of all layers. Past it the map layer over-zooms,
  /// so inside a downloaded region the camera never asks for a zoom only
  /// the stream has, which would send local areas to the network.
  @override
  int get maxZoom => [
        for (final a in _local) a.maxZoom,
        if (_openRemote != null) remoteMaxZoom,
      ].fold(remoteMaxZoom, (a, b) => a < b ? a : b);

  @override
  Future<List<int>> tileBytes(int z, int x, int y) async {
    for (final archive in _local) {
      try {
        return await archive.tileBytes(z, x, y);
      } on MissingTileException {
        continue; // not in this region; try the next
      }
    }
    final remote = await _remoteArchive();
    if (remote == null) throw const MissingTileException();
    return remote.tileBytes(z, x, y);
  }

  Future<TileArchive?> _remoteArchive() async {
    final open = _openRemote;
    if (open == null) return null;
    if (_remote == null) {
      final failedAt = _remoteFailedAt;
      if (failedAt != null && _clock().difference(failedAt) < remoteRetry) return null;
      _remote = open();
    }
    try {
      return await _remote;
    } catch (_) {
      _remote = null;
      _remoteFailedAt = _clock();
      return null;
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
