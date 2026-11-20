import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/map/resilient_tile_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

/// An archive that fails reads after it has been "poisoned", like a pmtiles
/// archive whose directory cache holds a failed future.
class FakeArchive implements TileArchive {
  FakeArchive({this.poisoned = false});

  bool poisoned;
  int reads = 0;

  @override
  int get minZoom => 0;

  @override
  int get maxZoom => 14;

  @override
  Future<List<int>> tileBytes(int z, int x, int y) async {
    reads++;
    if (poisoned) throw StateError('cached directory read failed');
    if (z > 12) throw const MissingTileException();
    return [z, x, y];
  }
}

void main() {
  final tile = TileIdentity(10, 30, 37);

  test('serves tiles from the archive', () async {
    final provider = await ResilientTileProvider.open(() async => FakeArchive());
    expect(await provider.provide(tile), [10, 30, 37]);
  });

  test('a missing tile is a non-retryable 404, not a failure', () async {
    final provider = await ResilientTileProvider.open(() async => FakeArchive());
    await expectLater(
      provider.provide(TileIdentity(13, 1, 1)),
      throwsA(isA<ProviderException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.retryable, 'retryable', Retryable.none)),
    );
    expect(provider.reopenCount, 0);
  });

  test('a poisoned archive is replaced and the tile still loads', () async {
    final archives = [FakeArchive(poisoned: true), FakeArchive()];
    var opened = 0;
    final provider = await ResilientTileProvider.open(() async => archives[opened++]);

    expect(await provider.provide(tile), [10, 30, 37]);
    expect(provider.reopenCount, 1);
  });

  test('many tiles failing at once share a single reopen', () async {
    var opened = 0;
    final provider = await ResilientTileProvider.open(() async {
      opened++;
      return FakeArchive(poisoned: opened == 1);
    });

    final results = await Future.wait([
      for (var x = 0; x < 20; x++) provider.provide(TileIdentity(10, x, 1)),
    ]);
    expect(results, hasLength(20));
    expect(opened, 2, reason: 'one initial open plus one shared reopen');
  });

  test('gives up with a retryable error if the fresh archive also fails', () async {
    final provider = await ResilientTileProvider.open(() async => FakeArchive(poisoned: true));
    await expectLater(
      provider.provide(tile),
      throwsA(isA<ProviderException>().having((e) => e.retryable, 'retryable', Retryable.retry)),
    );
  });
}
