import 'dart:convert';

import 'package:http/http.dart' as http;

import 'hazard_details.dart';

/// Current wind at a point, from Open-Meteo (https://open-meteo.com): free,
/// no account, CC BY 4.0 data. Only the hazard's coordinates are sent.
///
/// Returns null when offline or on any error: wind is optional, and the
/// reporter can always enter it by hand.
class WindService {
  WindService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const attribution = 'Weather data by Open-Meteo.com (CC BY 4.0)';

  Future<Wind?> current(double latitude, double longitude) async {
    final url = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': latitude.toStringAsFixed(4),
      'longitude': longitude.toStringAsFixed(4),
      'current': 'wind_speed_10m,wind_direction_10m',
      'wind_speed_unit': 'kmh',
    });
    try {
      final response = await _client.get(url).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final current = (jsonDecode(response.body) as Map)['current'];
      if (current is! Map) return null;
      final speed = current['wind_speed_10m'], from = current['wind_direction_10m'];
      if (speed is! num || from is! num) return null;
      return Wind(fromDegrees: from.toDouble(), speedKmh: speed.toDouble(), source: WindSource.forecast);
    } catch (_) {
      return null;
    }
  }
}
