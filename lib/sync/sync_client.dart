import 'dart:convert';

import 'package:http/http.dart' as http;

import '../hazards/hazard_events.dart';

/// Talks to the Holdfast server's event API.
///
/// The server is intentionally dumb: it stores events and hands them back.
/// It never decides whether a hazard is verified; clients do that with the
/// shared rules in `hazard_engine.dart`, so the answer is identical whether
/// events arrived via the server, a satellite link or a mesh neighbour.
class SyncClient {
  SyncClient(this.baseUrl, {http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  static const _timeout = Duration(seconds: 8);

  /// Uploads events. The server ignores ids it already has, so retrying a
  /// batch after a dropped connection is always safe.
  Future<void> push(List<HazardEvent> events) async {
    if (events.isEmpty) return;
    final response = await _client
        .post(
          Uri.parse('$baseUrl/v1/events'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'events': [for (final e in events) e.toJson()]}),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException('push failed: HTTP ${response.statusCode}');
    }
  }

  /// Downloads events after [cursor] (exclusive). Returns the events and the
  /// cursor to pass next time.
  Future<({List<HazardEvent> events, int cursor})> pull(int cursor) async {
    final response = await _client
        .get(Uri.parse('$baseUrl/v1/events?since=$cursor'))
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException('pull failed: HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, Object?>;
    return (
      events: [
        for (final e in body['events']! as List<Object?>)
          HazardEvent.fromJson((e! as Map).cast<String, Object?>()),
      ],
      cursor: (body['cursor']! as num).toInt(),
    );
  }
}
