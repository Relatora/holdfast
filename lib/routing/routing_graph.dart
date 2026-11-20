/// The offline road and rail network for one region, decoded from the
/// `<id>.routing.bin` pack written by `tool/build_routing.py`.
///
/// Plain Dart with typed arrays: a city's network is a few hundred thousand
/// vertices and edges, and parallel `Int32List`s keep that compact (and
/// fast to scan) where a list of objects would not.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

/// Mode bits on an edge. Must match `tool/build_routing.py`.
abstract final class ModeBits {
  static const foot = 1;
  static const bike = 2;
  static const car = 4;
  static const rail = 8;
}

/// One-way flags: the edge may only be travelled from → to by that mode.
abstract final class OnewayBits {
  static const car = 1;
  static const bike = 2;
}

/// Road classes, indexed exactly as `CLASSES` in `tool/build_routing.py`.
enum RoadClass {
  motorway, trunk, primary, secondary, tertiary, unclassified, residential,
  motorwayLink, trunkLink, primaryLink, secondaryLink, tertiaryLink,
  livingStreet, service, pedestrian, track, footway, path, cycleway, steps,
  bridleway, road, rail;

  /// What to call an unnamed stretch in step-by-step directions.
  String get description => switch (this) {
        RoadClass.footway || RoadClass.pedestrian => 'footpath',
        RoadClass.path || RoadClass.bridleway || RoadClass.track => 'trail',
        RoadClass.cycleway => 'bike path',
        RoadClass.steps => 'stairs',
        RoadClass.service => 'service road',
        RoadClass.motorwayLink || RoadClass.trunkLink || RoadClass.primaryLink ||
        RoadClass.secondaryLink || RoadClass.tertiaryLink =>
          'ramp',
        RoadClass.rail => 'rail line',
        _ => 'road',
      };
}

/// A railway station or halt.
class Station {
  const Station(this.name, this.position);
  final String name;
  final LatLng position;
}

class RoutingFormatException implements Exception {
  const RoutingFormatException(this.message);
  final String message;
  @override
  String toString() => 'RoutingFormatException: $message';
}

class RoutingGraph {
  RoutingGraph._({
    required this.names,
    required this.vertexLat,
    required this.vertexLon,
    required this.edgeFrom,
    required this.edgeTo,
    required this.edgeLengthDm,
    required this.edgeModes,
    required this.edgeOneway,
    required this.edgeClass,
    required this.edgeMaxSpeed,
    required this.edgeName,
    required this.shapeStart,
    required this.shapeLat,
    required this.shapeLon,
    required this.stations,
  }) {
    _buildAdjacency();
  }

  static const _magic = 'HFRT';
  static const supportedVersion = 1;

  /// Street names; an edge's [edgeName] is an index into this plus one.
  final List<String> names;

  /// Vertex positions in micro-degrees.
  final Int32List vertexLat, vertexLon;

  final Int32List edgeFrom, edgeTo, edgeLengthDm, edgeName;
  final Uint8List edgeModes, edgeOneway, edgeClass, edgeMaxSpeed;

  /// Edge e's shape points are shapeLat/Lon[shapeStart[e] .. shapeStart[e+1]].
  final Int32List shapeStart, shapeLat, shapeLon;

  final List<Station> stations;

  /// Compressed adjacency: vertex v's half-edges are
  /// adjacency[adjacencyStart[v] .. adjacencyStart[v+1]], each encoded as
  /// `edge * 2 + (1 if travelled backwards, to → from)`.
  late final Int32List adjacencyStart, adjacency;

  int get vertexCount => vertexLat.length;
  int get edgeCount => edgeFrom.length;

  LatLng vertex(int v) => LatLng(vertexLat[v] / 1e6, vertexLon[v] / 1e6);

  String? nameOf(int edge) => edgeName[edge] == 0 ? null : names[edgeName[edge] - 1];

  RoadClass classOf(int edge) => RoadClass.values[edgeClass[edge]];

  double lengthMeters(int edge) => edgeLengthDm[edge] / 10;

  /// The edge's full polyline in the direction it is travelled.
  List<LatLng> shape(int edge, {bool backwards = false}) {
    final points = [
      vertex(edgeFrom[edge]),
      for (var i = shapeStart[edge]; i < shapeStart[edge + 1]; i++) LatLng(shapeLat[i] / 1e6, shapeLon[i] / 1e6),
      vertex(edgeTo[edge]),
    ];
    return backwards ? points.reversed.toList() : points;
  }

  void _buildAdjacency() {
    final counts = Int32List(vertexCount + 1);
    for (var e = 0; e < edgeCount; e++) {
      counts[edgeFrom[e] + 1]++;
      counts[edgeTo[e] + 1]++;
    }
    for (var v = 0; v < vertexCount; v++) {
      counts[v + 1] += counts[v];
    }
    final fill = Int32List.fromList(counts);
    final half = Int32List(edgeCount * 2);
    for (var e = 0; e < edgeCount; e++) {
      half[fill[edgeFrom[e]]++] = e * 2;
      half[fill[edgeTo[e]]++] = e * 2 + 1;
    }
    adjacencyStart = counts;
    adjacency = half;
  }

  /// Decodes a routing pack. Throws [RoutingFormatException] on a file this
  /// version doesn't understand rather than misreading it.
  factory RoutingGraph.decode(Uint8List bytes) {
    final r = _Reader(bytes);
    if (bytes.length < 4 || ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != _magic) {
      throw const RoutingFormatException('Not a Holdfast routing pack');
    }
    r.offset = 4;
    final version = r.uint();
    if (version != supportedVersion) {
      throw RoutingFormatException('Routing pack version $version; this app reads $supportedVersion');
    }

    final names = List.generate(r.uint(), (_) => r.text());

    final vertexCount = r.uint();
    final vLat = Int32List(vertexCount), vLon = Int32List(vertexCount);
    var lat = 0, lon = 0;
    for (var v = 0; v < vertexCount; v++) {
      lat += r.sint();
      lon += r.sint();
      vLat[v] = lat;
      vLon[v] = lon;
    }

    final edgeCount = r.uint();
    final from = Int32List(edgeCount), to = Int32List(edgeCount), length = Int32List(edgeCount);
    final modes = Uint8List(edgeCount), oneway = Uint8List(edgeCount), cls = Uint8List(edgeCount);
    final speed = Uint8List(edgeCount);
    final name = Int32List(edgeCount);
    final shapeStart = Int32List(edgeCount + 1);
    final sLat = <int>[], sLon = <int>[];
    for (var e = 0; e < edgeCount; e++) {
      from[e] = r.uint();
      to[e] = r.uint();
      length[e] = r.uint();
      modes[e] = r.uint();
      oneway[e] = r.uint();
      cls[e] = r.uint();
      speed[e] = r.uint();
      name[e] = r.uint();
      final points = r.uint();
      var pLat = vLat[from[e]], pLon = vLon[from[e]];
      for (var i = 0; i < points; i++) {
        pLat += r.sint();
        pLon += r.sint();
        sLat.add(pLat);
        sLon.add(pLon);
      }
      shapeStart[e + 1] = sLat.length;
    }

    final stations = List.generate(r.uint(), (_) {
      final lat = r.sint(), lon = r.sint();
      return Station(r.text(), LatLng(lat / 1e6, lon / 1e6));
    });

    return RoutingGraph._(
      names: names,
      vertexLat: vLat,
      vertexLon: vLon,
      edgeFrom: from,
      edgeTo: to,
      edgeLengthDm: length,
      edgeModes: modes,
      edgeOneway: oneway,
      edgeClass: cls,
      edgeMaxSpeed: speed,
      edgeName: name,
      shapeStart: shapeStart,
      shapeLat: Int32List.fromList(sLat),
      shapeLon: Int32List.fromList(sLon),
      stations: stations,
    );
  }
}

/// LEB128 varints, zigzag for signed values.
///
/// Decoded with arithmetic, not bit operators, on purpose: compiled to
/// JavaScript, Dart's `^`, `|` and `<<` produce *unsigned* 32-bit results,
/// so the classic `(raw >> 1) ^ -(raw & 1)` turns -75.7° into +4219°.
/// Values stored into an Int32List wrap back by luck; plain ints (station
/// positions) don't, which put every station off the planet on the web.
class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int offset = 0;

  int uint() {
    var result = 0, scale = 1;
    while (true) {
      if (offset >= bytes.length) throw const RoutingFormatException('Routing pack is truncated');
      final byte = bytes[offset++];
      result += (byte & 0x7f) * scale;
      if (byte < 0x80) return result;
      scale *= 128;
    }
  }

  int sint() {
    final raw = uint();
    final half = raw ~/ 2;
    return raw.isOdd ? -half - 1 : half;
  }

  String text() {
    final length = uint();
    if (offset + length > bytes.length) throw const RoutingFormatException('Routing pack is truncated');
    final value = utf8.decode(bytes.sublist(offset, offset + length));
    offset += length;
    return value;
  }
}
