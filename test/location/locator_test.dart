import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:holdfast/location/locator.dart';
import 'package:latlong2/latlong.dart';

/// A device whose location switch, permission answers and GPS behaviour
/// each test sets.
class _FakeDevice implements LocationPlatform {
  bool service = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission answer = LocationPermission.whileInUse;
  bool gpsWorks = true;
  bool networkWorks = true;
  bool throwsOnService = false;
  int requests = 0;
  final positions = <bool>[]; // the `precise` flag of each position request

  @override
  Future<bool> serviceEnabled() async {
    if (throwsOnService) throw UnsupportedError('no location API');
    return service;
  }

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return permission = answer;
  }

  @override
  Future<Position> position({required bool precise, required Duration timeLimit}) async {
    positions.add(precise);
    if (precise ? !gpsWorks : !networkWorks) throw Exception('timed out');
    return Position(
      latitude: 45.42,
      longitude: -75.69,
      timestamp: DateTime.utc(2026, 11, 25),
      accuracy: precise ? 8 : 1500,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  FixSource sourceOf(Position position, {required bool precise}) => precise ? FixSource.gps : FixSource.network;
}

/// Location is on when the attempt starts, and off by the time GPS gives up.
class _SwitchOffDuringFix extends _FakeDevice {
  @override
  Future<Position> position({required bool precise, required Duration timeLimit}) async {
    service = false;
    throw Exception('timed out');
  }
}

LocateProblem? problemOf(LocateResult r) => r is LocateFailed ? r.problem : null;
Fix? fixOf(LocateResult r) => r is Located ? r.fix : null;

void main() {
  late _FakeDevice device;
  late DateTime now;
  late DeviceLocator locator;

  setUp(() {
    device = _FakeDevice();
    now = DateTime.utc(2026, 11, 25, 9);
    locator = DeviceLocator(platform: device, clock: () => now);
  });

  test('a GPS fix is precise and remembered', () async {
    final fix = fixOf(await locator.gps())!;
    expect(fix.source, FixSource.gps);
    expect(fix.approximate, isFalse);
    expect(fix.at, const LatLng(45.42, -75.69));
    expect(fix.accuracyMeters, 8);
    expect(locator.last, same(fix));
    expect(device.positions, [true]);
  });

  test('location switched off is reported, not worked around', () async {
    device.service = false;
    expect(problemOf(await locator.gps()), LocateProblem.serviceOff);
    expect(device.positions, isEmpty, reason: 'no position is asked for with location off');
    expect(locator.last, isNull);
  });

  test('permission is asked once, and each refusal has its own problem', () async {
    device
      ..permission = LocationPermission.denied
      ..answer = LocationPermission.denied;
    expect(problemOf(await locator.gps()), LocateProblem.denied);
    expect(device.requests, 1);

    device
      ..permission = LocationPermission.denied
      ..answer = LocationPermission.deniedForever;
    expect(problemOf(await locator.gps()), LocateProblem.deniedForever);

    device
      ..permission = LocationPermission.denied
      ..answer = LocationPermission.whileInUse;
    expect(fixOf(await locator.gps()), isNotNull, reason: 'allowed on asking');
  });

  test('no GPS fix in time is noFix; the rough fallback is never automatic', () async {
    device.gpsWorks = false;
    expect(problemOf(await locator.gps()), LocateProblem.noFix);
    expect(device.positions, [true], reason: 'gps() must not quietly fall back to the network');
  });

  test('approximate tries rough sources (towers) before the system network location', () async {
    final towerFix = Fix(
      at: const LatLng(45.40, -75.70),
      accuracyMeters: 1800,
      source: FixSource.towers,
      time: now,
    );
    locator
      ..addRoughSource(() async => throw Exception('no cell info'))
      ..addRoughSource(() async => null)
      ..addRoughSource(() async => towerFix);
    expect(fixOf(await locator.approximate()), same(towerFix));
    expect(device.positions, isEmpty, reason: 'the towers answered first');
  });

  test('approximate falls back to the network provider, marked as approximate', () async {
    final fix = fixOf(await locator.approximate())!;
    expect(fix.source, FixSource.network);
    expect(fix.approximate, isTrue);
    expect(device.positions, [false]);

    device.networkWorks = false;
    expect(problemOf(await locator.approximate()), LocateProblem.noFix);
  });

  test('location switched off while waiting for GPS is serviceOff, not noFix', () async {
    final switchingOff = _SwitchOffDuringFix();
    locator = DeviceLocator(platform: switchingOff, clock: () => now);
    expect(problemOf(await locator.gps()), LocateProblem.serviceOff);
  });

  test('a device without a location API is unsupported, not a crash', () async {
    device.throwsOnService = true;
    expect(problemOf(await locator.gps()), LocateProblem.unsupported);
  });

  test('recent() only offers a fix from the last two minutes', () async {
    await locator.gps();
    expect(locator.recent(), isNotNull);
    now = now.add(const Duration(minutes: 3));
    expect(locator.recent(), isNull);
    expect(locator.last, isNotNull, reason: 'the dot stays; only directions want it fresh');
  });

  test('busy is true only while looking', () async {
    final seen = <bool>[];
    locator.addListener(() => seen.add(locator.busy));
    await locator.gps();
    expect(seen, [true, false]);
    expect(locator.busy, isFalse);
  });
}
