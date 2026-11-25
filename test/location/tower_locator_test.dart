import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/location/cell_pack.dart';
import 'package:holdfast/location/locator.dart';
import 'package:holdfast/location/tower_locator.dart';
import 'package:holdfast/pois/poi.dart' show distanceMeters;
import 'package:latlong2/latlong.dart';

const _serving = CellKey(CellRadio.lte, 302, 610, 21500, 26880003);
const _neighbour = CellKey(CellRadio.lte, 302, 610, 21500, 26880004);
const _portHuron = CellKey(CellRadio.gsm, 310, 410, 4500, 1234);
const _fiveG = CellKey(CellRadio.nr, 302, 220, 77, 68719476000);

class _FakeScanner implements CellScanner {
  _FakeScanner(this.cells);
  final List<HeardCell> cells;
  @override
  Future<List<HeardCell>> scan() async => cells;
}

double metresBetween(LatLng a, LatLng b) => distanceMeters(a.latitude, a.longitude, b.latitude, b.longitude);

void main() {
  final time = DateTime.utc(2026, 11, 25, 9);

  group('the pack written by tool/build_cells.py', () {
    // Built from a synthetic OpenCelliD CSV: four good cells, plus a
    // one-sample cell, a cell outside Sarnia and a CDMA cell, all dropped.
    final pack = CellPack.decode(File('test/fixtures/sarnia_sample.cells.bin').readAsBytesSync());

    test('keeps only well-sampled GSM/UMTS/LTE/NR cells inside the region', () {
      expect(pack.length, 4);
      expect(pack[const CellKey(CellRadio.lte, 302, 610, 21500, 99)], isNull, reason: 'one sample');
      expect(pack[const CellKey(CellRadio.lte, 302, 610, 21500, 100)], isNull, reason: 'in Ottawa');
    });

    test('round-trips positions, ranges and 36-bit 5G cell ids', () {
      final serving = pack[_serving]!;
      expect(serving.at.latitude, closeTo(42.9745, 1e-5));
      expect(serving.at.longitude, closeTo(-82.4066, 1e-5));
      expect(serving.rangeMeters, 1200);
      expect(pack[_portHuron]!.rangeMeters, 3500, reason: 'a US tower heard across the river');
      expect(pack[_fiveG]!.at.latitude, closeTo(42.96, 1e-5));
    });

    test('the same numbers under another radio are another cell', () {
      expect(pack[const CellKey(CellRadio.gsm, 302, 610, 21500, 26880003)], isNull);
    });

    test('rejects what is not a cell pack', () {
      expect(() => CellPack.decode(File('test/fixtures/sarnia_sample.cells.bin').readAsBytesSync().sublist(0, 9)),
          throwsA(isA<CellPackFormatException>()));
    });
  });

  group('estimateFromCells', () {
    final pack = CellPack.of({
      _serving: const CellSite(LatLng(42.9745, -82.4066), 1200),
      _neighbour: const CellSite(LatLng(42.9800, -82.3900), 900),
      _portHuron: const CellSite(LatLng(42.9710, -82.4250), 3500),
    });

    test('one known cell: its position, as wide as it reaches', () {
      final fix = estimateFromCells([const HeardCell(_portHuron, dbm: -90)], [pack], time: time)!;
      expect(fix.at, const LatLng(42.9710, -82.4250));
      expect(fix.accuracyMeters, 3500);
      expect(fix.source, FixSource.towers);
      expect(fix.approximate, isTrue);
    });

    test('a single short-range cell still claims at least 500 m', () {
      final small = CellPack.of({_serving: const CellSite(LatLng(42.9745, -82.4066), 150)});
      expect(estimateFromCells([const HeardCell(_serving)], [small], time: time)!.accuracyMeters,
          minTowerAccuracyMeters);
    });

    test('several cells: pulled towards the strongest', () {
      final fix = estimateFromCells([
        const HeardCell(_serving, dbm: -70, serving: true),
        const HeardCell(_neighbour, dbm: -95),
        const HeardCell(_portHuron, dbm: -105),
      ], [pack], time: time)!;
      final toServing = metresBetween(fix.at, const LatLng(42.9745, -82.4066));
      final toNeighbour = metresBetween(fix.at, const LatLng(42.9800, -82.3900));
      expect(toServing, lessThan(toNeighbour));
      expect(toServing, lessThan(300), reason: '25 dB stronger: about 18 times the pull');
      expect(fix.accuracyMeters, greaterThanOrEqualTo(minTowerAccuracyMeters));
    });

    test('equal signals: the middle, with the spread as accuracy', () {
      final fix = estimateFromCells([
        const HeardCell(_serving, dbm: -80),
        const HeardCell(_neighbour, dbm: -80),
      ], [pack], time: time)!;
      final apart = metresBetween(const LatLng(42.9745, -82.4066), const LatLng(42.9800, -82.3900));
      expect(metresBetween(fix.at, const LatLng(42.9745, -82.4066)), closeTo(apart / 2, 20));
      expect(fix.accuracyMeters, closeTo(apart / 2, 20));
    });

    test('unknown cells are ignored; none known is no fix', () {
      const unknown = HeardCell(CellKey(CellRadio.lte, 302, 610, 1, 2), dbm: -50);
      expect(estimateFromCells([unknown], [pack], time: time), isNull);
      final fix = estimateFromCells([unknown, const HeardCell(_portHuron, dbm: -90)], [pack], time: time)!;
      expect(fix.at, const LatLng(42.9710, -82.4250), reason: 'the strong unknown cell must not pull');
    });

    test('a cell is looked up in every downloaded pack', () {
      final ottawa = CellPack.of({});
      expect(estimateFromCells([const HeardCell(_serving)], [ottawa, pack], time: time), isNotNull);
    });
  });

  test('TowerLocator: nothing heard or no packs is no fix, without reading packs needlessly', () async {
    var loads = 0;
    Future<List<CellPack>> load() async {
      loads++;
      return [CellPack.of({_serving: const CellSite(LatLng(42.9745, -82.4066), 1200)})];
    }

    expect(await TowerLocator(loadPacks: load, scanner: _FakeScanner(const [])).locate(), isNull);
    expect(loads, 0);
    final fix = await TowerLocator(
      loadPacks: load,
      scanner: _FakeScanner(const [HeardCell(_serving, dbm: -80)]),
      clock: () => time,
    ).locate();
    expect(fix!.time, time);
  });
}
