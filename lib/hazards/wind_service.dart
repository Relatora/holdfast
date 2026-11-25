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

  /// The forecast wind at [time], for a planned release: the plume should
  /// follow the wind *then*, not now. Open-Meteo forecasts 16 days ahead
  /// by the hour (UTC here); the hour nearest [time] is used. Null when the
  /// time is outside the forecast, offline, or on any error.
  Future<Wind?> forecastAt(double latitude, double longitude, DateTime time) async {
    final url = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': latitude.toStringAsFixed(4),
      'longitude': longitude.toStringAsFixed(4),
      'hourly': 'wind_speed_10m,wind_direction_10m',
      'wind_speed_unit': 'kmh',
      'timezone': 'GMT',
      'forecast_days': '16',
    });
    try {
      final response = await _client.get(url).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final hourly = (jsonDecode(response.body) as Map)['hourly'];
      if (hourly is! Map) return null;
      final times = hourly['time'], speeds = hourly['wind_speed_10m'], froms = hourly['wind_direction_10m'];
      if (times is! List || speeds is! List || froms is! List) return null;
      final target = time.toUtc();
      int? best;
      Duration? bestGap;
      for (var i = 0; i < times.length && i < speeds.length && i < froms.length; i++) {
        // Open-Meteo writes "2026-11-25T15:00" with no zone; it is GMT here.
        final at = DateTime.tryParse('${times[i]}Z');
        if (at == null || speeds[i] is! num || froms[i] is! num) continue;
        final gap = at.difference(target).abs();
        if (bestGap == null || gap < bestGap) {
          best = i;
          bestGap = gap;
        }
      }
      // Beyond the forecast's end (or before its start) it's a guess.
      if (best == null || bestGap! > const Duration(minutes: 90)) return null;
      return Wind(
        fromDegrees: (froms[best] as num).toDouble(),
        speedKmh: (speeds[best] as num).toDouble(),
        source: WindSource.forecast,
      );
    } catch (_) {
      return null;
    }
  }

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
