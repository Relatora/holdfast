import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/routing/router.dart';
import 'package:holdfast/routing/routing_graph.dart';
import 'package:latlong2/latlong.dart';

import 'pack_builder.dart';

/// A one-block town, about 1.1 km a side:
///
///     NW ──── North St ──── NE
///     │ (West Ave bulges     │
///     │  out a little, so    East Ave
///     │  it is the longer    │
///     │  way round)          │
///     SW ──── South St ──── SE
const sw = LatLng(45.000, -75.000), se = LatLng(45.000, -74.986);
const ne = LatLng(45.010, -74.986), nw = LatLng(45.010, -75.000);

PackBuilder town({int eastOneway = 0}) {
  final b = PackBuilder();
  final vSW = b.vertex(sw.latitude, sw.longitude), vSE = b.vertex(se.latitude, se.longitude);
  final vNE = b.vertex(ne.latitude, ne.longitude), vNW = b.vertex(nw.latitude, nw.longitude);
  b
    ..edge(vSW, vSE, name: 'South St')
    // Drawn north to south, so a one-way flag means "southbound only".
    ..edge(vNE, vSE, name: 'East Ave', oneway: eastOneway)
    ..edge(vNW, vNE, name: 'North St')
    ..edge(vSW, vNW, name: 'West Ave', shape: const [LatLng(45.005, -75.002)]);
  return b;
}

Router routerFor(PackBuilder b) => Router(RoutingGraph.decode(b.build()));

void main() {
  group('decoding', () {
    test('round-trips names, positions and shapes', () {
      final graph = RoutingGraph.decode(town().build());
      expect(graph.vertexCount, 4);
      expect(graph.edgeCount, 4);
      expect(graph.nameOf(0), 'South St');
      expect(graph.vertex(2).latitude, closeTo(45.010, 1e-6));
      expect(graph.shape(3).length, 3, reason: 'West Ave keeps its bend');
      expect(graph.lengthMeters(0), closeTo(1100, 15));
    });

    test('rejects files that are not routing packs', () {
      expect(() => RoutingGraph.decode(Uint8List.fromList([1, 2, 3, 4, 5])), throwsA(isA<RoutingFormatException>()));
    });
  });

  group('single-mode routes', () {
    test('takes the shorter way round, with readable steps', () {
      final plan = routerFor(town()).plan(sw, ne, TravelMode.walk);
      expect(plan.steps.map((s) => s.instruction), [
        'Head east on South St',
        'Turn left onto East Ave',
        'Arrive at your destination',
      ]);
      expect(plan.meters, closeTo(2210, 30));
      // Walking 2.2 km takes about 27 minutes.
      expect(plan.duration.inMinutes, inInclusiveRange(25, 30));
    });

    test('cars obey one-way streets; people on foot do not', () {
      final router = routerFor(town(eastOneway: OnewayBits.car));
      final drive = router.plan(sw, ne, TravelMode.car);
      expect(drive.steps.first.instruction, 'Head north on West Ave');
      expect(drive.steps[1].instruction, 'Turn right onto North St');

      final walk = router.plan(sw, ne, TravelMode.walk);
      expect(walk.steps.first.instruction, 'Head east on South St');
    });

    test('a motorway is for cars only', () {
      final b = town();
      b.edge(0, 2, modes: ModeBits.car, cls: RoadClass.motorway, name: 'Highway 402');
      final router = routerFor(b);
      expect(router.plan(sw, ne, TravelMode.car).steps.first.instruction, contains('Highway 402'));
      expect(router.plan(sw, ne, TravelMode.bike).steps.first.instruction, isNot(contains('Highway 402')));
    });

    test('a start far from any road is reported, not guessed', () {
      expect(
        () => routerFor(town()).plan(const LatLng(46, -75), ne, TravelMode.walk),
        throwsA(isA<NoRouteException>().having((e) => e.message, 'message', contains('start'))),
      );
    });
  });

  group('hazards', () {
    test('routes around an area to avoid', () {
      final plan = routerFor(town()).plan(sw, ne, TravelMode.walk, avoid: [Avoid(se, 150)]);
      expect(plan.steps.first.instruction, 'Head north on West Ave');
      expect(plan.avoided, 1);
      expect(plan.throughHazard, isFalse);
    });

    test('when nothing avoids it, still routes, but says so', () {
      // Both ways into NE pass through this circle.
      final plan = routerFor(town()).plan(sw, ne, TravelMode.walk, avoid: [Avoid(ne, 150)]);
      expect(plan.throughHazard, isTrue);
      expect(plan.meters, greaterThan(2000));
    });
  });

  group('train', () {
    PackBuilder railTown() {
      final b = town();
      // A rail line north to a second station 11 km away, with a street there.
      final r1 = b.vertex(45.0004, -75.0004), r2 = b.vertex(45.1000, -75.0004);
      b.edge(r1, r2, modes: ModeBits.rail, cls: RoadClass.rail, name: 'Northern Line');
      final o1 = b.vertex(45.1000, -75.000), o2 = b.vertex(45.1010, -75.000);
      b
        ..edge(o1, o2, name: 'Station Rd')
        ..station('Alpha', 45.0003, -75.0003)
        ..station('Omega', 45.1001, -75.0003);
      return b;
    }

    test('walks to a station, rides, and walks on', () {
      final plan = routerFor(railTown()).plan(sw, const LatLng(45.1010, -75.000), TravelMode.train);
      expect(plan.legs.map((l) => l.kind), [LegKind.walk, LegKind.rail, LegKind.walk]);
      final ride = plan.legs[1];
      expect(ride.steps.first.instruction, 'Board at Alpha');
      expect(ride.steps.last.instruction, 'Get off at Omega');
      expect(ride.meters, closeTo(11070, 100));
      // 11 km at 60 km/h is 11 minutes, plus the wait on the platform.
      expect(ride.duration.inMinutes, inInclusiveRange(18, 21));
    });

    test('changes line when two lines share no track', () {
      final b = town();
      // Line A runs north to Junction A; Line B leaves from Junction B,
      // 150 m east, the way Ottawa's O-Train lines meet at Bayview.
      final a1 = b.vertex(45.0004, -75.0004), a2 = b.vertex(45.0500, -75.0004);
      final b1 = b.vertex(45.0500, -74.9985), b2 = b.vertex(45.1000, -74.9985);
      b
        ..edge(a1, a2, modes: ModeBits.rail, cls: RoadClass.rail)
        ..edge(b1, b2, modes: ModeBits.rail, cls: RoadClass.rail);
      // Streets at the change and at the destination.
      final m1 = b.vertex(45.0501, -75.0002), m2 = b.vertex(45.0501, -74.9987);
      final d1 = b.vertex(45.1001, -74.9983), d2 = b.vertex(45.1010, -74.9983);
      b
        ..edge(m1, m2, name: 'Transfer Walk')
        ..edge(d1, d2, name: 'Last St')
        ..station('Alpha', 45.0003, -75.0003)
        ..station('Junction A', 45.0501, -75.0003)
        ..station('Junction B', 45.0501, -74.9986)
        ..station('Omega', 45.1001, -74.9986);

      final plan = routerFor(b).plan(sw, const LatLng(45.1010, -74.9983), TravelMode.train);
      expect(plan.legs.map((l) => l.kind), [LegKind.walk, LegKind.rail, LegKind.walk, LegKind.rail, LegKind.walk]);
      expect(plan.legs[1].steps.last.instruction, 'Get off at Junction A');
      expect(plan.legs[3].steps.first.instruction, 'Board at Junction B');
    });

    test('a map without stations says so', () {
      expect(
        () => routerFor(town()).plan(sw, ne, TravelMode.train),
        throwsA(isA<NoRouteException>().having((e) => e.message, 'message', contains('no train stations'))),
      );
    });
  });

  // Cross-checks the Python writer against this decoder on real data, when
  // a routing pack has been built locally (regions/ is not in git).
  final sarnia = File('regions/sarnia.routing.bin');
  test('real Sarnia pack: decodes and routes across town', () {
    final router = Router(RoutingGraph.decode(sarnia.readAsBytesSync()));
    // Downtown Sarnia to Lambton College, about 4.6 km apart.
    const downtown = LatLng(42.9745, -82.4066), college = LatLng(42.9923, -82.3550);
    for (final mode in [TravelMode.walk, TravelMode.bike, TravelMode.car]) {
      final plan = router.plan(downtown, college, mode);
      expect(plan.meters, inInclusiveRange(4500, 9000), reason: mode.name);
      expect(plan.steps.length, greaterThan(2), reason: mode.name);
    }
  }, skip: sarnia.existsSync() ? false : 'run tool/build_routing.py sarnia first');

  final ottawa = File('regions/ottawa.routing.bin');
  test('real Ottawa pack: the train goes by O-Train between two stations', () {
    final router = Router(RoutingGraph.decode(ottawa.readAsBytesSync()));
    expect(router.graph.stations, isNotEmpty);
    // Tunney's Pasture to Blair, the two ends of Line 1 (about 12 km).
    const tunneys = LatLng(45.4036, -75.7352), blair = LatLng(45.4310, -75.6086);
    final plan = router.plan(tunneys, blair, TravelMode.train);
    expect(plan.legs.map((l) => l.kind), [LegKind.walk, LegKind.rail, LegKind.walk]);
    expect(plan.legs[1].meters, greaterThan(8000));
  }, skip: ottawa.existsSync() ? false : 'run tool/build_routing.py ottawa first');

  test('real Ottawa pack: Line 1 to Line 2 changes trains', () {
    final router = Router(RoutingGraph.decode(ottawa.readAsBytesSync()));
    // Tunney's Pasture (Line 1) to Greenboro (Line 2): the lines only meet
    // at Bayview, by a walk between platforms.
    const tunneys = LatLng(45.4036, -75.7352), greenboro = LatLng(45.3600, -75.6593);
    final plan = router.plan(tunneys, greenboro, TravelMode.train);
    final rides = plan.legs.where((l) => l.kind == LegKind.rail).toList();
    expect(rides, hasLength(2));
    // ignore: avoid_print
    print([for (final s in plan.steps) s.instruction].where((s) => !s.startsWith('Head') && !s.contains('onto')).join(' | '));
  }, skip: ottawa.existsSync() ? false : 'run tool/build_routing.py ottawa first');
}
