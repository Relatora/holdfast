import 'dart:convert';
import 'dart:typed_data';

import 'package:holdfast/pois/poi.dart' show distanceMeters;
import 'package:holdfast/routing/routing_graph.dart';
import 'package:latlong2/latlong.dart';

/// Writes small routing packs in the format of `tool/build_routing.py`, so
/// tests can describe a street network in a few lines and exercise the
/// real decoder at the same time.
class PackBuilder {
  final _names = <String>[];
  final _vertices = <LatLng>[];
  final _edges = <_Edge>[];
  final _stations = <(String, LatLng)>[];

  int vertex(double lat, double lon) {
    _vertices.add(LatLng(lat, lon));
    return _vertices.length - 1;
  }

  void edge(
    int from,
    int to, {
    int modes = ModeBits.foot | ModeBits.bike | ModeBits.car,
    int oneway = 0,
    RoadClass cls = RoadClass.residential,
    int maxSpeed = 0,
    String? name,
    List<LatLng> shape = const [],
  }) {
    final points = [_vertices[from], ...shape, _vertices[to]];
    var length = 0.0;
    for (var i = 0; i + 1 < points.length; i++) {
      length += distanceMeters(points[i].latitude, points[i].longitude, points[i + 1].latitude, points[i + 1].longitude);
    }
    var nameId = 0;
    if (name != null) {
      var index = _names.indexOf(name);
      if (index < 0) {
        _names.add(name);
        index = _names.length - 1;
      }
      nameId = index + 1;
    }
    _edges.add(_Edge(from, to, (length * 10).round(), modes, oneway, cls.index, maxSpeed, nameId, shape));
  }

  void station(String name, double lat, double lon) => _stations.add((name, LatLng(lat, lon)));

  Uint8List build() {
    final out = BytesBuilder()..add(ascii.encode('HFRT'));
    void uint(int value) {
      do {
        var byte = value & 0x7f;
        value >>= 7;
        if (value != 0) byte |= 0x80;
        out.addByte(byte);
      } while (value != 0);
    }

    void sint(int value) => uint(value >= 0 ? value << 1 : ((-value) << 1) - 1);
    void text(String value) {
      final raw = utf8.encode(value);
      uint(raw.length);
      out.add(raw);
    }

    int micro(double degrees) => (degrees * 1e6).round();

    uint(RoutingGraph.supportedVersion);
    uint(_names.length);
    _names.forEach(text);

    uint(_vertices.length);
    var pLat = 0, pLon = 0;
    for (final v in _vertices) {
      sint(micro(v.latitude) - pLat);
      sint(micro(v.longitude) - pLon);
      pLat = micro(v.latitude);
      pLon = micro(v.longitude);
    }

    uint(_edges.length);
    for (final e in _edges) {
      for (final value in [e.from, e.to, e.lengthDm, e.modes, e.oneway, e.cls, e.speed, e.name, e.shape.length]) {
        uint(value);
      }
      var lat = micro(_vertices[e.from].latitude), lon = micro(_vertices[e.from].longitude);
      for (final p in e.shape) {
        sint(micro(p.latitude) - lat);
        sint(micro(p.longitude) - lon);
        lat = micro(p.latitude);
        lon = micro(p.longitude);
      }
    }

    uint(_stations.length);
    for (final (name, p) in _stations) {
      sint(micro(p.latitude));
      sint(micro(p.longitude));
      text(name);
    }
    return out.toBytes();
  }
}

class _Edge {
  _Edge(this.from, this.to, this.lengthDm, this.modes, this.oneway, this.cls, this.speed, this.name, this.shape);
  final int from, to, lengthDm, modes, oneway, cls, speed, name;
  final List<LatLng> shape;
}
