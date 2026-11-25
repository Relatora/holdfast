import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/map/resilient_tile_provider.dart';

/// Holds tiles for a square block of x (and any y) at every zoom: enough to
/// stand for "a region" in these tests.
class _Region implements TileArchive {
  _Region(this.name, {required this.fromX, required this.toX, this.top = 14});

  final String name;
  final int fromX, toX, top;
  int reads = 0;

  @override
  int get minZoom => 0;

  @override
  int get maxZoom => top;

  @override
  Future<List<int>> tileBytes(int z, int x, int y) async {
    reads++;
    if (x < fromX || x > toX) throw const MissingTileException();
    return name.codeUnits;
  }
}

String text(List<int> bytes) => String.fromCharCodes(bytes);

void main() {
  test('downloaded maps answer first; only what they lack is streamed', () async {
    final ottawa = _Region('ottawa', fromX: 0, toX: 9);
    final planet = _Region('planet', fromX: 0, toX: 999);
    var opened = 0;
    final layers = LayeredTileArchive([ottawa], openRemote: () async {
      opened++;
      return planet;
    });

    expect(text(await layers.tileBytes(10, 5, 5)), 'ottawa');
    expect(opened, 0, reason: 'nothing outside a saved region was asked for yet');
    expect(text(await layers.tileBytes(10, 500, 5)), 'planet');
    expect(planet.reads, 1);
  });

  test('with overlapping maps, the first listed (the one on screen) wins', () async {
    final ottawa = _Region('ottawa', fromX: 0, toX: 9);
    final ontario = _Region('ontario', fromX: 0, toX: 99);
    final layers = LayeredTileArchive([ottawa, ontario]);
    expect(text(await layers.tileBytes(10, 5, 5)), 'ottawa');
    expect(text(await layers.tileBytes(10, 50, 5)), 'ontario');
  });

  test('without a stream, outside every map is simply empty', () async {
    final layers = LayeredTileArchive([_Region('ottawa', fromX: 0, toX: 9)]);
    await expectLater(layers.tileBytes(10, 500, 5), throwsA(isA<MissingTileException>()));
  });

  test('an unreachable stream leaves local maps working and is retried later', () async {
    var now = DateTime.utc(2026, 11, 25);
    var attempts = 0;
    var online = false;
    final layers = LayeredTileArchive(
      [_Region('ottawa', fromX: 0, toX: 9)],
      openRemote: () async {
        attempts++;
        if (!online) throw Exception('no route to host');
        return _Region('planet', fromX: 0, toX: 999);
      },
      clock: () => now,
    );

    await expectLater(layers.tileBytes(10, 500, 5), throwsA(isA<MissingTileException>()));
    await expectLater(layers.tileBytes(10, 501, 5), throwsA(isA<MissingTileException>()));
    expect(attempts, 1, reason: 'a burst of tiles must not retry the connection each time');
    expect(text(await layers.tileBytes(10, 5, 5)), 'ottawa');

    online = true;
    now = now.add(const Duration(seconds: 31));
    expect(text(await layers.tileBytes(10, 500, 5)), 'planet');
    expect(attempts, 2);
  });

  test('the top zoom is the lowest of all layers, so saved areas never zoom into the stream', () {
    final layers = LayeredTileArchive(
      [_Region('ottawa', fromX: 0, toX: 9, top: 14)],
      openRemote: () async => _Region('planet', fromX: 0, toX: 999, top: 15),
    );
    expect(layers.maxZoom, 14);
    expect(LayeredTileArchive(const [], openRemote: () async => _Region('planet', fromX: 0, toX: 1)).maxZoom, 15);
  });
}
