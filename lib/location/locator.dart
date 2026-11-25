import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Where a position came from. It decides how the map draws it: a GPS fix
/// is a dot, anything rougher is a wide circle that never passes for one.
enum FixSource {
  gps('GPS'),
  network('Network location'),
  towers('Cell towers');

  const FixSource(this.label);
  final String label;
}

/// A position and how far off it may be.
class Fix {
  const Fix({required this.at, required this.accuracyMeters, required this.source, required this.time});

  final LatLng at;

  /// Radius within which the true position probably lies.
  final double accuracyMeters;
  final FixSource source;
  final DateTime time;

  /// Anything other than GPS is an estimate the user should be told about.
  bool get approximate => source != FixSource.gps;
}

/// Why no position could be found. Each one has its own way out, which the
/// location sheet offers.
enum LocateProblem {
  /// Location is switched off for the whole device: offer to turn it on.
  serviceOff,

  /// The user said no this time: asking again is allowed.
  denied,

  /// The user said "don't ask again": only the app's settings can undo it.
  deniedForever,

  /// Location is on and allowed, but no fix came in time: usually indoors
  /// or under heavy cover, away from the sky. Offer a rougher method.
  noFix,

  /// This device has no location service at all (some desktops).
  unsupported,
}

/// The outcome of one attempt: a [Fix] or the [LocateProblem] that stopped it.
sealed class LocateResult {
  const LocateResult();
}

class Located extends LocateResult {
  const Located(this.fix);
  final Fix fix;
}

class LocateFailed extends LocateResult {
  const LocateFailed(this.problem);
  final LocateProblem problem;
}

/// The few calls the [DeviceLocator] makes, so tests can stand in for the
/// device. [GeolocatorPlatformAdapter] is the real one.
abstract interface class LocationPlatform {
  Future<bool> serviceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();

  /// A single position. [precise] asks for GPS; otherwise the cheaper
  /// network provider (cell towers and Wi-Fi, resolved by the system).
  /// Throws on timeout or failure.
  Future<Position> position({required bool precise, required Duration timeLimit});

  Future<bool> openLocationSettings();
  Future<bool> openAppSettings();
}

/// [LocationPlatform] over the geolocator plugin.
class GeolocatorPlatformAdapter implements LocationPlatform {
  const GeolocatorPlatformAdapter();

  @override
  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() => Geolocator.requestPermission();

  @override
  Future<Position> position({required bool precise, required Duration timeLimit}) {
    final settings = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: precise ? LocationAccuracy.high : LocationAccuracy.low,
            timeLimit: timeLimit,
            // The plain LocationManager, not Google's fused provider: it
            // works on phones without Google services, and at low accuracy
            // it asks the network provider (towers and Wi-Fi) directly.
            forceLocationManager: !precise,
          )
        : LocationSettings(accuracy: precise ? LocationAccuracy.high : LocationAccuracy.low, timeLimit: timeLimit);
    return Geolocator.getCurrentPosition(locationSettings: settings);
  }

  @override
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  @override
  Future<bool> openAppSettings() => Geolocator.openAppSettings();
}

/// Finds the device on the map, by GPS first and more roughly when that
/// fails, and remembers the last position for the location dot and for
/// directions.
///
/// It never decides on its own to fall back: a rough position presented as
/// a precise one is worse than none in an emergency. The caller shows the
/// [LocateProblem] and lets the person choose [approximate].
class DeviceLocator extends ChangeNotifier {
  DeviceLocator({
    LocationPlatform platform = const GeolocatorPlatformAdapter(),
    this.gpsTimeLimit = const Duration(seconds: 10),
    DateTime Function()? clock,
  })  : _platform = platform, // ignore: prefer_initializing_formals (private field, public name)
        _clock = clock ?? DateTime.now;

  final LocationPlatform _platform;
  final Duration gpsTimeLimit;
  final DateTime Function() _clock;

  /// Rough positions to try, in order, before the system's network
  /// location. Offline cell-tower positioning plugs in here.
  final List<Future<Fix?> Function()> _roughSources = [];

  Fix? _last;
  bool _busy = false;

  /// The most recent position found, if any.
  Fix? get last => _last;

  /// Whether an attempt is running (the button shows progress).
  bool get busy => _busy;

  /// A fix from the last [maxAge], or null. Directions start from it so the
  /// route begins where the dot is, without waiting for another fix.
  Fix? recent({Duration maxAge = const Duration(minutes: 2)}) {
    final fix = _last;
    if (fix == null || _clock().difference(fix.time) > maxAge) return null;
    return fix;
  }

  /// Adds a rough source tried by [approximate] before the system's own.
  void addRoughSource(Future<Fix?> Function() source) => _roughSources.add(source);

  /// A GPS fix, or why there isn't one.
  Future<LocateResult> gps() => _attempt(() async {
        if (await _permissionProblem() case final problem?) return LocateFailed(problem);
        try {
          final p = await _platform.position(precise: true, timeLimit: gpsTimeLimit);
          return Located(_fixFrom(p, FixSource.gps));
        } catch (_) {
          // Location may have been switched off while waiting for a fix:
          // then the way out is to turn it back on, not a rougher method.
          if (await _serviceOff()) return const LocateFailed(LocateProblem.serviceOff);
          return const LocateFailed(LocateProblem.noFix);
        }
      });

  /// A rougher position: the [addRoughSource] sources first (offline), then
  /// the system's network location (towers and Wi-Fi, usually needs data).
  Future<LocateResult> approximate() => _attempt(() async {
        if (await _permissionProblem() case final problem?) return LocateFailed(problem);
        for (final source in _roughSources) {
          try {
            if (await source() case final fix?) return Located(fix);
          } catch (_) {
            // That source failed; the next one may not.
          }
        }
        try {
          final p = await _platform.position(precise: false, timeLimit: const Duration(seconds: 15));
          return Located(_fixFrom(p, FixSource.network));
        } catch (_) {
          return const LocateFailed(LocateProblem.noFix);
        }
      });

  /// Opens the device's location switch; true when the screen opened.
  Future<bool> openLocationSettings() async {
    try {
      return await _platform.openLocationSettings();
    } catch (_) {
      return false;
    }
  }

  /// Opens this app's permission settings; true when the screen opened.
  Future<bool> openAppSettings() async {
    try {
      return await _platform.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  /// Forgets the last position (the dot goes away).
  void clear() {
    if (_last == null) return;
    _last = null;
    notifyListeners();
  }

  /// Checks the service and the permission, asking for it when allowed.
  /// Null means go ahead.
  Future<LocateProblem?> _permissionProblem() async {
    try {
      if (!await _platform.serviceEnabled()) return LocateProblem.serviceOff;
      var permission = await _platform.checkPermission();
      if (permission == LocationPermission.denied) permission = await _platform.requestPermission();
      return switch (permission) {
        LocationPermission.denied => LocateProblem.denied,
        LocationPermission.deniedForever => LocateProblem.deniedForever,
        LocationPermission.unableToDetermine => LocateProblem.unsupported,
        LocationPermission.whileInUse || LocationPermission.always => null,
      };
    } catch (_) {
      // No plugin on this platform, or no location API at all.
      return LocateProblem.unsupported;
    }
  }

  Future<bool> _serviceOff() async {
    try {
      return !await _platform.serviceEnabled();
    } catch (_) {
      return false;
    }
  }

  Future<LocateResult> _attempt(Future<LocateResult> Function() run) async {
    _busy = true;
    notifyListeners();
    try {
      final result = await run();
      if (result is Located) _last = result.fix;
      return result;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Fix _fixFrom(Position p, FixSource source) => Fix(
        at: LatLng(p.latitude, p.longitude),
        accuracyMeters: p.accuracy,
        source: source,
        time: _clock(),
      );
}
