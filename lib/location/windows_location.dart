import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import 'locator.dart';

/// A position from the Windows location service, which also says how it
/// was found. Only a satellite fix is GPS-grade; Wi-Fi and IP positions are
/// drawn as the approximate estimates they are.
class WindowsPosition extends Position {
  const WindowsPosition({
    required super.latitude,
    required super.longitude,
    required super.accuracy,
    required super.timestamp,
    required this.source,
  }) : super(
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        );

  /// "satellite", "wifi", "cellular", "ipAddress" or "unknown".
  final String source;

  bool get satellite => source == 'satellite';
}

/// [LocationPlatform] over the Windows location service, reached through
/// the `holdfast/location` channel in `windows/runner/location_channel.cpp`
/// (the geolocator plugin has no Windows implementation).
///
/// Windows differs from a phone in two ways the app has to respect:
/// * Desktop apps never get a permission prompt they can repeat. Location
///   is allowed or blocked in Settings > Privacy & security > Location,
///   where both "Location services" and "Let desktop apps access your
///   location" live, so "off" and "blocked" both lead there.
/// * Most PCs have no GPS: Windows locates them by Wi-Fi. Such a position
///   is reported as approximate, never as a GPS dot.
class WindowsLocationPlatform implements LocationPlatform {
  WindowsLocationPlatform({MethodChannel? channel, Future<bool> Function(Uri)? openUri})
      : _channel = channel ?? const MethodChannel('holdfast/location'),
        _openUri = openUri ?? ((uri) => launchUrl(uri));

  final MethodChannel _channel;
  final Future<bool> Function(Uri) _openUri;

  static final _privacySettings = Uri.parse('ms-settings:privacy-location');

  Future<({String access, String status})> _status() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('status') ?? const {};
    return (access: raw['access'] as String? ?? 'unspecified', status: raw['status'] as String? ?? 'notAvailable');
  }

  /// Off when Windows says location is disabled, for the whole device or
  /// for desktop apps (both switches are on the same Settings page). A PC
  /// with no location service at all is not "off": the permission check
  /// reports it as unsupported instead.
  @override
  Future<bool> serviceEnabled() async => (await _status()).status != 'disabled';

  @override
  Future<LocationPermission> checkPermission() async => _permission(await _status());

  /// Windows has no prompt to show again: the answer is whatever Settings
  /// says now.
  @override
  Future<LocationPermission> requestPermission() => checkPermission();

  static LocationPermission _permission(({String access, String status}) s) {
    if (s.status == 'notAvailable') return LocationPermission.unableToDetermine;
    return switch (s.access) {
      'allowed' => LocationPermission.whileInUse,
      // Only Settings can change it: the app says so and opens them.
      'denied' => LocationPermission.deniedForever,
      _ => LocationPermission.unableToDetermine,
    };
  }

  @override
  Future<Position> position({required bool precise, required Duration timeLimit}) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('position', {
      'precise': precise,
      'timeoutMs': timeLimit.inMilliseconds,
    });
    if (raw == null) throw PlatformException(code: 'noFix');
    return WindowsPosition(
      latitude: (raw['latitude']! as num).toDouble(),
      longitude: (raw['longitude']! as num).toDouble(),
      accuracy: (raw['accuracy']! as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch((raw['timestampMs']! as num).toInt(), isUtc: true),
      source: raw['source'] as String? ?? 'unknown',
    );
  }

  @override
  Future<bool> openLocationSettings() => _openUri(_privacySettings);

  @override
  Future<bool> openAppSettings() => _openUri(_privacySettings);

  @override
  FixSource sourceOf(Position position, {required bool precise}) =>
      position is WindowsPosition && !position.satellite ? FixSource.network : FixSource.gps;
}
