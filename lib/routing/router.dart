/// Offline directions over a [RoutingGraph]: walk, bike, car and train.
///
/// Plain Dart, no Flutter: the same rules give the same route in a test, on
/// a phone and on a desktop.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../pois/poi.dart' show distanceMeters;
import 'routing_graph.dart';

enum TravelMode {
  walk('Walk'),
  bike('Bike'),
  car('Car'),

  /// Walk to a station, ride the rail network, walk from the station.
  train('Train');

  const TravelMode(this.label);
  final String label;
}

/// How a leg is travelled; a train route has walk and rail legs.
enum LegKind { walk, bike, car, rail }

/// An area the route must keep out of, e.g. a reported flood.
class Avoid {
  const Avoid(this.center, this.radiusMeters);
  final LatLng center;
  final double radiusMeters;
}

enum Turn { start, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn, arrive }

class RouteStep {
  const RouteStep({required this.instruction, required this.meters, required this.turn, required this.at});
  final String instruction;
  final double meters;
  final Turn turn;

  /// Where the step begins, so the UI can show it on the map.
  final LatLng at;
}

class RouteLeg {
  const RouteLeg({
    required this.kind,
    required this.points,
    required this.meters,
    required this.duration,
    required this.steps,
  });
  final LegKind kind;
  final List<LatLng> points;
  final double meters;
  final Duration duration;
  final List<RouteStep> steps;
}

class RoutePlan {
  const RoutePlan({required this.mode, required this.legs, this.avoided = 0, this.throughHazard = false});
  final TravelMode mode;
  final List<RouteLeg> legs;

  /// Hazard areas the route was planned around.
  final int avoided;

  /// No route avoided every hazard, so this one passes through at least one.
  final bool throughHazard;

  double get meters => legs.fold(0, (sum, leg) => sum + leg.meters);
  Duration get duration => legs.fold(Duration.zero, (sum, leg) => sum + leg.duration);
  List<RouteStep> get steps => [for (final leg in legs) ...leg.steps];
}

/// Why no route was found, in words for the user.
class NoRouteException implements Exception {
  const NoRouteException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Router {
  Router(this.graph);

  final RoutingGraph graph;

  /// Rough average train speed between stations, including stops. With no
  /// network there are no live timetables, so train times are estimates.
  static const trainSpeedKmh = 60.0;

  /// Added to a train route for waiting on the platform.
  static const boardingWait = Duration(minutes: 8);

  /// Furthest a start or end point may be from the network.
  static const maxSnapMeters = 2000.0;

  // ---- Public API ----------------------------------------------------------

  /// Whether [point] is close enough to this map's paths to start a route
  /// from. False for a GPS position outside the downloaded region.
  bool covers(LatLng point) => _nearestVertex(point, _Profile.walk) != null;

  /// Plans a route. Tries to keep out of every [avoid] area; if that leaves
  /// no route at all, returns the best route anyway, flagged
  /// [RoutePlan.throughHazard], because a warned route beats none.
  RoutePlan plan(LatLng from, LatLng to, TravelMode mode, {List<Avoid> avoid = const []}) {
    final blocked = _blockedEdges(avoid);
    try {
      final plan = _plan(from, to, mode, blocked);
      return RoutePlan(mode: mode, legs: plan, avoided: avoid.length);
    } on NoRouteException {
      if (avoid.isEmpty) rethrow;
      final plan = _plan(from, to, mode, null);
      return RoutePlan(mode: mode, legs: plan, throughHazard: true);
    }
  }

  List<RouteLeg> _plan(LatLng from, LatLng to, TravelMode mode, Uint8List? blocked) => switch (mode) {
        TravelMode.walk => [_leg(from, to, _Profile.walk, blocked)],
        TravelMode.bike => [_leg(from, to, _Profile.bike, blocked)],
        TravelMode.car => [_leg(from, to, _Profile.car, blocked)],
        TravelMode.train => _trainLegs(from, to, blocked),
      };

  // ---- Single-mode legs ----------------------------------------------------

  RouteLeg _leg(LatLng from, LatLng to, _Profile profile, Uint8List? blocked) {
    final start = _nearestVertex(from, profile);
    final end = _nearestVertex(to, profile);
    if (start == null || end == null) {
      throw NoRouteException('No ${profile.noun} within ${maxSnapMeters ~/ 1000} km of the '
          '${start == null ? 'start' : 'destination'}.');
    }
    final path = _astar(start, end, profile, blocked);
    if (path == null) {
      throw NoRouteException('No ${profile.noun} connects these two points in this map.');
    }
    return _toLeg(path, profile, from, to);
  }

  // ---- Train ---------------------------------------------------------------

  /// Walk → train → walk, or with one change of line: walk → train → short
  /// walk between stations → train → walk. A change is needed when lines
  /// share no track; Ottawa's O-Train Lines 1 and 2, for one, only meet at
  /// Bayview by a walk between platforms.
  List<RouteLeg> _trainLegs(LatLng from, LatLng to, Uint8List? blocked) {
    final usable = _stationVertices();
    if (usable.isEmpty) throw const NoRouteException('This map has no train stations.');

    List<(Station, int)> nearest(LatLng point) {
      final sorted = [...usable]..sort((a, b) => _metres(point, a.$1.position).compareTo(_metres(point, b.$1.position)));
      return sorted.take(3).where((s) => _metres(point, s.$1.position) < 8000).toList();
    }

    final origins = nearest(from), destinations = nearest(to);
    if (origins.isEmpty) throw const NoRouteException('No train station within 8 km of the start.');
    if (destinations.isEmpty) throw const NoRouteException('No train station within 8 km of the destination.');

    // Walking legs are the expensive searches (the whole street network),
    // so each is planned once and reused across station combinations.
    final walks = <(LatLng, LatLng), RouteLeg?>{};
    RouteLeg? walk(LatLng a, LatLng b) => walks.putIfAbsent((a, b), () {
          try {
            return _leg(a, b, _Profile.walk, blocked);
          } on NoRouteException {
            return null;
          }
        });

    RouteLeg? ride((Station, int) board, (Station, int) alight) {
      final path = _astar(board.$2, alight.$2, _Profile.rail, null);
      return path == null
          ? null
          : _toLeg(path, _Profile.rail, board.$1.position, alight.$1.position, boardAt: board.$1, alightAt: alight.$1);
    }

    List<RouteLeg>? best;
    var bestSeconds = double.infinity;
    void consider(List<RouteLeg?> legs) {
      if (legs.contains(null)) return;
      final seconds = legs.fold<int>(0, (sum, leg) => sum + leg!.duration.inSeconds).toDouble();
      if (seconds < bestSeconds) {
        bestSeconds = seconds;
        best = legs.cast<RouteLeg>();
      }
    }

    final network = _railNetworks();
    for (final board in origins) {
      for (final alight in destinations) {
        if (identical(board.$1, alight.$1)) continue;
        final walkIn = walk(from, board.$1.position), walkOut = walk(alight.$1.position, to);
        if (walkIn == null || walkOut == null) continue;
        if (network[board.$2] == network[alight.$2]) {
          consider([walkIn, ride(board, alight), walkOut]);
          continue;
        }
        // Different networks: change at any pair of stations, one on each,
        // close enough to walk between.
        for (final change in usable.where((s) => network[s.$2] == network[board.$2])) {
          for (final onward in usable.where((s) => network[s.$2] == network[alight.$2])) {
            if (_metres(change.$1.position, onward.$1.position) > maxTransferMeters) continue;
            consider([
              walkIn,
              ride(board, change),
              walk(change.$1.position, onward.$1.position),
              ride(onward, alight),
              walkOut,
            ]);
          }
        }
      }
    }
    if (best == null) {
      throw const NoRouteException('No rail line links stations near the start and the destination.');
    }
    return best!;
  }

  /// Furthest apart two stations can be and still count as a change of line.
  static const maxTransferMeters = 500.0;

  List<(Station, int)>? _stations;

  /// Stations paired with the closest rail vertex, if one is within 400 m.
  List<(Station, int)> _stationVertices() => _stations ??= [
        for (final station in graph.stations)
          if (_nearestVertex(station.position, _Profile.rail, within: 400) case final v?) (station, v),
      ];

  Int32List? _networks;

  /// Labels each vertex with its connected rail network (-1 for none), so
  /// the planner knows when a trip needs a change of line.
  Int32List _railNetworks() {
    final existing = _networks;
    if (existing != null) return existing;
    final label = Int32List(graph.vertexCount)..fillRange(0, graph.vertexCount, -1);
    var next = 0;
    for (var e = 0; e < graph.edgeCount; e++) {
      if (graph.edgeModes[e] & ModeBits.rail == 0 || label[graph.edgeFrom[e]] != -1) continue;
      final stack = [graph.edgeFrom[e]];
      label[graph.edgeFrom[e]] = next;
      while (stack.isNotEmpty) {
        final v = stack.removeLast();
        for (var i = graph.adjacencyStart[v]; i < graph.adjacencyStart[v + 1]; i++) {
          final edge = graph.adjacency[i] >> 1;
          if (graph.edgeModes[edge] & ModeBits.rail == 0) continue;
          final w = (graph.adjacency[i] & 1) == 1 ? graph.edgeFrom[edge] : graph.edgeTo[edge];
          if (label[w] == -1) {
            label[w] = next;
            stack.add(w);
          }
        }
      }
      next++;
    }
    return _networks = label;
  }

  // ---- Search --------------------------------------------------------------

  /// A* with travel time in seconds as the cost and straight-line distance
  /// at the profile's top speed as the (admissible) heuristic. Returns the
  /// path as half-edges (see [RoutingGraph.adjacency]).
  List<int>? _astar(int start, int goal, _Profile profile, Uint8List? blocked) {
    if (start == goal) return const [];
    final n = graph.vertexCount;
    final cost = Float64List(n)..fillRange(0, n, double.infinity);
    final via = Int32List(n)..fillRange(0, n, -1);
    final done = Uint8List(n);
    final goalPoint = graph.vertex(goal);
    double estimate(int v) => _metresV(v, goalPoint) / profile.topSpeed;

    final open = _MinHeap()..push(estimate(start), start);
    cost[start] = 0;
    while (open.isNotEmpty) {
      final v = open.pop();
      if (v == goal) break;
      if (done[v] == 1) continue;
      done[v] = 1;
      for (var i = graph.adjacencyStart[v]; i < graph.adjacencyStart[v + 1]; i++) {
        final half = graph.adjacency[i];
        final edge = half >> 1;
        final backwards = (half & 1) == 1;
        if (!profile.allows(graph, edge, backwards)) continue;
        if (blocked != null && blocked[edge] == 1) continue;
        final next = backwards ? graph.edgeFrom[edge] : graph.edgeTo[edge];
        final candidate = cost[v] + graph.lengthMeters(edge) / profile.speed(graph, edge);
        if (candidate < cost[next]) {
          cost[next] = candidate;
          via[next] = half;
          open.push(candidate + estimate(next), next);
        }
      }
    }
    if (via[goal] == -1) return null;

    final path = <int>[];
    for (var v = goal; v != start;) {
      final half = via[v];
      path.add(half);
      v = (half & 1) == 1 ? graph.edgeTo[half >> 1] : graph.edgeFrom[half >> 1];
    }
    return path.reversed.toList();
  }

  // ---- Snapping ------------------------------------------------------------

  final Map<_Profile, Map<int, List<int>>> _grids = {};

  /// Grid cells of ~1 km holding the vertices a profile can use.
  static const _cell = 0.01;
  static int _key(double lat, double lon) => ((lat / _cell).floor() << 16) ^ ((lon / _cell).floor() & 0xffff);

  int? _nearestVertex(LatLng point, _Profile profile, {double within = maxSnapMeters}) {
    final grid = _grids.putIfAbsent(profile, () {
      final cells = <int, List<int>>{};
      for (var e = 0; e < graph.edgeCount; e++) {
        if (graph.edgeModes[e] & profile.bit == 0) continue;
        for (final v in [graph.edgeFrom[e], graph.edgeTo[e]]) {
          cells.putIfAbsent(_key(graph.vertexLat[v] / 1e6, graph.vertexLon[v] / 1e6), () => []).add(v);
        }
      }
      return cells;
    });
    final rings = (within / 1000 / (_cell * 111)).ceil() + 1;
    final baseLat = (point.latitude / _cell).floor(), baseLon = (point.longitude / _cell).floor();
    int? best;
    var bestMetres = within;
    for (var dLat = -rings; dLat <= rings; dLat++) {
      for (var dLon = -rings; dLon <= rings; dLon++) {
        final key = ((baseLat + dLat) << 16) ^ ((baseLon + dLon) & 0xffff);
        for (final v in grid[key] ?? const <int>[]) {
          final m = _metresV(v, point);
          if (m < bestMetres) {
            bestMetres = m;
            best = v;
          }
        }
      }
    }
    return best;
  }

  // ---- Hazards -------------------------------------------------------------

  /// Marks every edge with a vertex or shape point inside an avoid area.
  /// A cheap bounding-box test runs first, so only nearby points pay for a
  /// real distance check.
  Uint8List? _blockedEdges(List<Avoid> avoid) {
    if (avoid.isEmpty) return null;
    final blocked = Uint8List(graph.edgeCount);
    for (final area in avoid) {
      final dLat = area.radiusMeters / 111000 * 1e6;
      final dLon = dLat / math.max(0.1, math.cos(area.center.latitude * math.pi / 180));
      final cLat = area.center.latitude * 1e6, cLon = area.center.longitude * 1e6;
      bool inside(int lat, int lon) =>
          (lat - cLat).abs() <= dLat &&
          (lon - cLon).abs() <= dLon &&
          distanceMeters(lat / 1e6, lon / 1e6, area.center.latitude, area.center.longitude) <= area.radiusMeters;
      for (var e = 0; e < graph.edgeCount; e++) {
        if (blocked[e] == 1) continue;
        final a = graph.edgeFrom[e], b = graph.edgeTo[e];
        var hit = inside(graph.vertexLat[a], graph.vertexLon[a]) || inside(graph.vertexLat[b], graph.vertexLon[b]);
        for (var i = graph.shapeStart[e]; !hit && i < graph.shapeStart[e + 1]; i++) {
          hit = inside(graph.shapeLat[i], graph.shapeLon[i]);
        }
        if (hit) blocked[e] = 1;
      }
    }
    return blocked;
  }

  // ---- Turning a path into a leg -------------------------------------------

  RouteLeg _toLeg(List<int> path, _Profile profile, LatLng from, LatLng to, {Station? boardAt, Station? alightAt}) {
    final points = <LatLng>[from];
    var meters = 0.0, seconds = 0.0;
    final groups = <_Group>[];
    for (final half in path) {
      final edge = half >> 1;
      final backwards = (half & 1) == 1;
      final shape = graph.shape(edge, backwards: backwards);
      points.addAll(shape);
      final length = graph.lengthMeters(edge);
      meters += length;
      seconds += length / profile.speed(graph, edge);
      final label = graph.nameOf(edge) ?? graph.classOf(edge).description;
      if (groups.isNotEmpty && groups.last.label == label) {
        groups.last
          ..meters += length
          ..end = shape;
      } else {
        groups.add(_Group(label, graph.nameOf(edge) != null, length, shape, shape));
      }
    }
    points.add(to);

    // The walk from the exact start point to the network, and from the
    // network to the exact destination, at the profile's speed.
    final snap = (path.isEmpty ? _metres(from, to) : _metres(from, points[1]) + _metres(points[points.length - 2], to));
    meters += snap;
    seconds += snap / profile.snapSpeed;

    final steps = boardAt != null
        ? [
            RouteStep(instruction: 'Board at ${boardAt.name}', meters: 0, turn: Turn.start, at: boardAt.position),
            RouteStep(
              instruction: 'Ride the train ${_distance(meters)} to ${alightAt!.name} '
                  '(estimated: no live timetables offline)',
              meters: meters,
              turn: Turn.straight,
              at: boardAt.position,
            ),
            RouteStep(instruction: 'Get off at ${alightAt.name}', meters: 0, turn: Turn.arrive, at: alightAt.position),
          ]
        : _steps(groups, to);

    var duration = Duration(seconds: seconds.round());
    if (boardAt != null) duration += boardingWait;
    return RouteLeg(kind: profile.kind, points: points, meters: meters, duration: duration, steps: steps);
  }

  List<RouteStep> _steps(List<_Group> groups, LatLng to) {
    if (groups.isEmpty) {
      return [RouteStep(instruction: 'Head straight to the destination', meters: 0, turn: Turn.arrive, at: to)];
    }
    final steps = <RouteStep>[];
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      final onto = g.named ? g.label : 'the ${g.label}';
      if (i == 0) {
        steps.add(RouteStep(
          instruction: 'Head ${_compass(_bearing(g.start.first, g.start[1]))} on $onto',
          meters: g.meters,
          turn: Turn.start,
          at: g.start.first,
        ));
        continue;
      }
      final prev = groups[i - 1].end;
      final turn = _turn(_bearing(prev[prev.length - 2], prev.last), _bearing(g.start.first, g.start[1]));
      final verb = switch (turn) {
        Turn.straight => 'Continue onto',
        Turn.slightLeft => 'Bear left onto',
        Turn.left => 'Turn left onto',
        Turn.sharpLeft => 'Turn sharp left onto',
        Turn.slightRight => 'Bear right onto',
        Turn.right => 'Turn right onto',
        Turn.sharpRight => 'Turn sharp right onto',
        _ => 'Make a U-turn onto',
      };
      steps.add(RouteStep(instruction: '$verb $onto', meters: g.meters, turn: turn, at: g.start.first));
    }
    steps.add(RouteStep(instruction: 'Arrive at your destination', meters: 0, turn: Turn.arrive, at: to));
    return steps;
  }

  static Turn _turn(double before, double after) {
    final delta = ((after - before + 540) % 360) - 180; // -180..180, + is right
    final a = delta.abs();
    if (a < 20) return Turn.straight;
    if (a > 160) return Turn.uTurn;
    final right = delta > 0;
    if (a < 45) return right ? Turn.slightRight : Turn.slightLeft;
    if (a < 120) return right ? Turn.right : Turn.left;
    return right ? Turn.sharpRight : Turn.sharpLeft;
  }

  static double _bearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180, lat2 = b.latitude * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static String _compass(double bearing) =>
      const ['north', 'northeast', 'east', 'southeast', 'south', 'southwest', 'west', 'northwest'][((bearing + 22.5) % 360 ~/ 45)];

  static String _distance(double meters) =>
      meters < 1000 ? '${(meters / 10).round() * 10} m' : '${(meters / 1000).toStringAsFixed(1)} km';

  double _metres(LatLng a, LatLng b) => distanceMeters(a.latitude, a.longitude, b.latitude, b.longitude);
  double _metresV(int v, LatLng p) =>
      distanceMeters(graph.vertexLat[v] / 1e6, graph.vertexLon[v] / 1e6, p.latitude, p.longitude);
}

/// Consecutive edges with the same street name, merged into one step.
class _Group {
  _Group(this.label, this.named, this.meters, this.start, this.end);
  final String label;
  final bool named;
  double meters;
  final List<LatLng> start;
  List<LatLng> end;
}

/// Who may use an edge, in which direction, and how fast they go on it.
enum _Profile {
  walk(ModeBits.foot, LegKind.walk, 'walkable path'),
  bike(ModeBits.bike, LegKind.bike, 'bikeable road'),
  car(ModeBits.car, LegKind.car, 'drivable road'),
  rail(ModeBits.rail, LegKind.rail, 'rail line');

  const _Profile(this.bit, this.kind, this.noun);
  final int bit;
  final LegKind kind;
  final String noun;

  bool allows(RoutingGraph graph, int edge, bool backwards) {
    if (graph.edgeModes[edge] & bit == 0) return false;
    if (!backwards) return true;
    final oneway = graph.edgeOneway[edge];
    return switch (this) {
      _Profile.car => oneway & OnewayBits.car == 0,
      _Profile.bike => oneway & OnewayBits.bike == 0,
      _ => true, // pedestrians and trains aren't bound by one-way streets
    };
  }

  /// Metres per second on an edge.
  double speed(RoutingGraph graph, int edge) {
    final cls = graph.classOf(edge);
    return switch (this) {
      _Profile.walk => cls == RoadClass.steps ? 0.8 : 1.35, // ~4.9 km/h
      _Profile.bike => switch (cls) {
          RoadClass.footway || RoadClass.pedestrian || RoadClass.steps => 2.8, // slow, shared space
          RoadClass.track || RoadClass.path => 3.6,
          _ => 4.6, // ~16.5 km/h
        },
      _Profile.car => _carSpeed(graph.edgeMaxSpeed[edge], cls),
      _Profile.rail => Router.trainSpeedKmh / 3.6,
    };
  }

  static double _carSpeed(int posted, RoadClass cls) {
    // Posted limits are a ceiling, not an average: take 90% of them.
    if (posted > 0) return posted * 0.9 / 3.6;
    final kmh = switch (cls) {
      RoadClass.motorway => 100,
      RoadClass.trunk => 80,
      RoadClass.primary => 60,
      RoadClass.secondary => 50,
      RoadClass.tertiary => 45,
      RoadClass.unclassified => 40,
      RoadClass.motorwayLink => 60,
      RoadClass.trunkLink || RoadClass.primaryLink => 45,
      RoadClass.secondaryLink || RoadClass.tertiaryLink => 35,
      RoadClass.livingStreet => 10,
      RoadClass.service => 15,
      _ => 30,
    };
    return kmh / 3.6;
  }

  /// Fastest possible speed, for the A* heuristic (must never overestimate
  /// progress, or the route stops being the fastest).
  double get topSpeed => switch (this) {
        _Profile.walk => 1.35,
        _Profile.bike => 4.6,
        _Profile.car => 140 / 3.6,
        _Profile.rail => Router.trainSpeedKmh / 3.6,
      };

  /// Speed off the network: the stretch from the exact start point to the
  /// nearest road is on foot, or at a crawl for vehicles.
  double get snapSpeed => this == _Profile.car ? 5 : 1.35;
}

/// Binary min-heap of (priority, vertex) without per-entry objects.
class _MinHeap {
  final _priority = <double>[];
  final _value = <int>[];

  bool get isNotEmpty => _value.isNotEmpty;

  void push(double priority, int value) {
    _priority.add(priority);
    _value.add(value);
    var i = _value.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_priority[parent] <= _priority[i]) break;
      _swap(i, parent);
      i = parent;
    }
  }

  int pop() {
    final top = _value.first;
    final lastP = _priority.removeLast(), lastV = _value.removeLast();
    if (_value.isNotEmpty) {
      _priority[0] = lastP;
      _value[0] = lastV;
      var i = 0;
      while (true) {
        final l = 2 * i + 1, r = l + 1;
        var m = i;
        if (l < _value.length && _priority[l] < _priority[m]) m = l;
        if (r < _value.length && _priority[r] < _priority[m]) m = r;
        if (m == i) break;
        _swap(i, m);
        i = m;
      }
    }
    return top;
  }

  void _swap(int a, int b) {
    final p = _priority[a];
    _priority[a] = _priority[b];
    _priority[b] = p;
    final v = _value[a];
    _value[a] = _value[b];
    _value[b] = v;
  }
}
