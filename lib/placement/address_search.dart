/// Finding a place by what people type: a street, a crossing ("Main St &
/// 2nd Ave"), a named place, or, with a connection, a full address.
///
/// Offline first. The downloaded map already holds every street name (the
/// routing pack) and every named place (the POI pack), so streets,
/// crossings and places are found with no network at all. House numbers
/// aren't in the packs; with a connection, and only when online mode
/// allows, the query goes to Photon (photon.komoot.io), a free geocoder
/// built on OpenStreetMap.
///
/// Plain Dart apart from the HTTP client, so the matching is tested
/// directly.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../pois/poi.dart';
import '../routing/routing_graph.dart';

/// Where a result came from, which the list shows.
enum AddressSource { street, crossing, place, online }

class AddressResult {
  const AddressResult({required this.title, required this.subtitle, required this.point, required this.source});

  final String title;
  final String subtitle;
  final LatLng point;
  final AddressSource source;
}

/// Street-name words people abbreviate, both ways round: "st" and
/// "street" match each other.
const _abbreviations = {
  'st': 'street',
  'ave': 'avenue',
  'av': 'avenue',
  'rd': 'road',
  'dr': 'drive',
  'blvd': 'boulevard',
  'ln': 'lane',
  'ct': 'court',
  'cres': 'crescent',
  'cr': 'crescent',
  'hwy': 'highway',
  'pkwy': 'parkway',
  'pl': 'place',
  'sq': 'square',
  'ter': 'terrace',
  'cir': 'circle',
  'n': 'north',
  's': 'south',
  'e': 'east',
  'w': 'west',
  'mt': 'mount',
  'ste': 'sainte',
};

/// Lower case, no punctuation, abbreviations spelled out, so "Main St."
/// and "main street" are the same words.
List<String> normalizeWords(String text) => [
      for (final word in text.toLowerCase().replaceAll(RegExp(r"[^\p{L}\p{N}\s]", unicode: true), ' ').split(RegExp(r'\s+')))
        if (word.isNotEmpty) _abbreviations[word] ?? word,
    ];

/// True when every query word starts a word of [name], in any order:
/// "main" finds "Main Street", "2nd ave" finds "2nd Avenue".
bool wordsMatch(List<String> query, List<String> name) =>
    query.isNotEmpty && query.every((q) => name.any((w) => w.startsWith(q)));

/// The street names of one region's routing pack, with where each street
/// runs, for street and crossing lookups.
class StreetIndex {
  StreetIndex(this.graph) {
    for (var e = 0; e < graph.edgeCount; e++) {
      final id = graph.edgeName[e];
      if (id == 0) continue;
      (_edgesByName[id - 1] ??= []).add(e);
    }
    _words = [for (final name in graph.names) normalizeWords(name)];
  }

  final RoutingGraph graph;
  final _edgesByName = <int, List<int>>{};
  late final List<List<String>> _words;

  /// Streets whose name matches [query], each placed at its point nearest
  /// [near] (a long road is found where you're looking, not at one end).
  List<AddressResult> streets(String query, {required LatLng near, int limit = 6}) {
    final words = normalizeWords(query.replaceFirst(RegExp(r'^\s*\d+[a-z]?\s+', caseSensitive: false), ''));
    final hits = <({int name, double meters, LatLng point})>[];
    for (var n = 0; n < graph.names.length; n++) {
      final edges = _edgesByName[n];
      if (edges == null || !wordsMatch(words, _words[n])) continue;
      final (point, meters) = _closestVertex(edges, near);
      hits.add((name: n, meters: meters, point: point));
    }
    // Exact names first, then the nearest.
    hits.sort((a, b) {
      final exact = (_words[b.name].join(' ') == words.join(' ') ? 1 : 0) -
          (_words[a.name].join(' ') == words.join(' ') ? 1 : 0);
      return exact != 0 ? exact : a.meters.compareTo(b.meters);
    });
    final numbered = RegExp(r'^\s*\d').hasMatch(query);
    return [
      for (final h in hits.take(limit))
        AddressResult(
          title: graph.names[h.name],
          subtitle: numbered ? 'Street (house numbers need a connection)' : 'Street on your map',
          point: h.point,
          source: AddressSource.street,
        ),
    ];
  }

  /// Where two streets meet: "Main St & 2nd Ave", "Main and 2nd",
  /// "Main at 2nd". The crossing nearest [near] for each pair of matches.
  List<AddressResult> crossings(String query, {required LatLng near, int limit = 4}) {
    final parts = query.split(RegExp(r'\s*(?:&|\+|/|\band\b|\bat\b)\s*', caseSensitive: false));
    if (parts.length != 2 || parts.any((p) => p.trim().isEmpty)) return const [];
    final a = normalizeWords(parts[0]), b = normalizeWords(parts[1]);
    final namesA = [for (var n = 0; n < graph.names.length; n++) if (wordsMatch(a, _words[n])) n];
    final namesB = [for (var n = 0; n < graph.names.length; n++) if (wordsMatch(b, _words[n])) n];
    final results = <({String title, LatLng point, double meters})>[];
    for (final na in namesA) {
      final vertices = <int>{
        for (final e in _edgesByName[na] ?? const <int>[]) ...[graph.edgeFrom[e], graph.edgeTo[e]],
      };
      for (final nb in namesB) {
        if (nb == na) continue;
        int? best;
        var bestMeters = double.infinity;
        for (final e in _edgesByName[nb] ?? const <int>[]) {
          for (final v in [graph.edgeFrom[e], graph.edgeTo[e]]) {
            if (!vertices.contains(v)) continue;
            final p = graph.vertex(v);
            final m = distanceMeters(near.latitude, near.longitude, p.latitude, p.longitude);
            if (m < bestMeters) {
              best = v;
              bestMeters = m;
            }
          }
        }
        if (best != null) {
          results.add((title: '${graph.names[na]} & ${graph.names[nb]}', point: graph.vertex(best), meters: bestMeters));
        }
      }
    }
    results.sort((x, y) => x.meters.compareTo(y.meters));
    return [
      for (final r in results.take(limit))
        AddressResult(title: r.title, subtitle: 'Crossing on your map', point: r.point, source: AddressSource.crossing),
    ];
  }

  (LatLng, double) _closestVertex(List<int> edges, LatLng near) {
    var best = graph.vertex(graph.edgeFrom[edges.first]);
    var bestMeters = double.infinity;
    for (final e in edges) {
      for (final v in [graph.edgeFrom[e], graph.edgeTo[e]]) {
        final p = graph.vertex(v);
        final m = distanceMeters(near.latitude, near.longitude, p.latitude, p.longitude);
        if (m < bestMeters) {
          best = p;
          bestMeters = m;
        }
      }
    }
    return (best, bestMeters);
  }
}

/// Named places and their addresses from the POI pack.
List<AddressResult> placeResults(Iterable<Poi> pois, String query, {required LatLng near, int limit = 5}) {
  final words = normalizeWords(query);
  if (words.isEmpty) return const [];
  final hits = <({Poi poi, double meters})>[
    for (final poi in pois)
      if (wordsMatch(words, normalizeWords('${poi.title} ${poi.address ?? ''}')))
        (poi: poi, meters: distanceMeters(near.latitude, near.longitude, poi.latitude, poi.longitude)),
  ]..sort((a, b) => a.meters.compareTo(b.meters));
  return [
    for (final h in hits.take(limit))
      AddressResult(
        title: h.poi.title,
        subtitle: h.poi.address ?? h.poi.category.label,
        point: LatLng(h.poi.latitude, h.poi.longitude),
        source: AddressSource.place,
      ),
  ];
}

/// Photon (https://photon.komoot.io), OpenStreetMap's open geocoder: full
/// addresses with house numbers, anywhere. Only reached through the
/// app's network gate, so offline mode sends nothing.
class PhotonClient {
  PhotonClient({required this.client, this.baseUrl = 'https://photon.komoot.io'});

  final http.Client client;
  final String baseUrl;

  /// Up to [limit] results for [query], biased towards [near].
  Future<List<AddressResult>> search(String query, {required LatLng near, int limit = 6}) async {
    final uri = Uri.parse('$baseUrl/api/').replace(queryParameters: {
      'q': query,
      'limit': '$limit',
      'lat': near.latitude.toStringAsFixed(3),
      'lon': near.longitude.toStringAsFixed(3),
    });
    final response = await client
        .get(uri, headers: {'User-Agent': 'holdfast (open-source emergency map)'})
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return const [];
    return parsePhoton(jsonDecode(utf8.decode(response.bodyBytes)));
  }
}

/// Reads Photon's GeoJSON answer. Features it can't read are skipped.
List<AddressResult> parsePhoton(Object? json) {
  final features = json is Map ? json['features'] : null;
  if (features is! List) return const [];
  final results = <AddressResult>[];
  for (final f in features) {
    if (f is! Map) continue;
    final coordinates = (f['geometry'] as Map?)?['coordinates'];
    final p = f['properties'];
    if (coordinates is! List || coordinates.length < 2 || p is! Map) continue;
    final lon = coordinates[0], lat = coordinates[1];
    if (lon is! num || lat is! num) continue;
    String? text(String key) => p[key] is String && (p[key] as String).isNotEmpty ? p[key] as String : null;
    final street = [?text('housenumber'), ?text('street')].join(' ');
    final title = text('name') ?? (street.isNotEmpty ? street : null);
    if (title == null) continue;
    final subtitle = [
      if (text('name') != null && street.isNotEmpty) street,
      ?text('city'),
      ?text('state'),
      ?text('country'),
    ].join(', ');
    results.add(AddressResult(
      title: title,
      subtitle: subtitle,
      point: LatLng(lat.toDouble(), lon.toDouble()),
      source: AddressSource.online,
    ));
  }
  return results;
}
