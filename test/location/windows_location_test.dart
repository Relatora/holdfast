import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:holdfast/location/locator.dart';
import 'package:holdfast/location/windows_location.dart';

/// Stands in for windows/runner/location_channel.cpp.
class _FakeWindows {
  _FakeWindows(this.channel) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, _handle);
  }

  final MethodChannel channel;
  String access = 'allowed';
  String status = 'ready';
  String source = 'wifi';
  bool noFix = false;
  final calls = <MethodCall>[];

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'status':
        return {'access': access, 'status': status};
      case 'position':
        if (noFix) throw PlatformException(code: 'noFix', message: 'timed out');
        return {
          'latitude': 42.97,
          'longitude': -82.40,
          'accuracy': 60.0,
          'timestampMs': DateTime.utc(2026, 11, 25, 18).millisecondsSinceEpoch,
          'source': source,
        };
    }
    return null;
  }

  void dispose() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('holdfast/location-test');
  late _FakeWindows windows;
  late List<Uri> opened;
  late DeviceLocator locator;

  setUp(() {
    windows = _FakeWindows(channel);
    opened = [];
    final platform = WindowsLocationPlatform(
      channel: channel,
      openUri: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    locator = DeviceLocator(platform: platform);
  });
  tearDown(() => windows.dispose());

  test('a Wi-Fi position is approximate, never a GPS dot', () async {
    final result = await locator.gps();
    final fix = (result as Located).fix;
    expect(fix.source, FixSource.network);
    expect(fix.approximate, isTrue);
    expect(fix.accuracyMeters, 60);
    expect(windows.calls.last.arguments, {'precise': true, 'timeoutMs': 10000});
  });

  test('a PC with a GPS receiver gets a real GPS fix', () async {
    windows.source = 'satellite';
    final fix = ((await locator.gps()) as Located).fix;
    expect(fix.source, FixSource.gps);
  });

  test('location switched off in Windows Settings reads as "off", and opens those settings', () async {
    windows
      ..status = 'disabled'
      ..access = 'denied';
    expect(await locator.gps(), isA<LocateFailed>().having((f) => f.problem, 'problem', LocateProblem.serviceOff));
    await locator.openLocationSettings();
    expect(opened.single.toString(), 'ms-settings:privacy-location');
  });

  test('desktop apps blocked: only Settings can change it', () async {
    windows.access = 'denied';
    expect(await locator.gps(), isA<LocateFailed>().having((f) => f.problem, 'problem', LocateProblem.deniedForever));
    await locator.openAppSettings();
    expect(opened.single.scheme, 'ms-settings');
  });

  test('no location service at all is "unsupported"', () async {
    windows.status = 'notAvailable';
    expect(await locator.gps(), isA<LocateFailed>().having((f) => f.problem, 'problem', LocateProblem.unsupported));
  });

  test('a timeout is "no fix", so the sheet can offer the approximate way', () async {
    windows.noFix = true;
    expect(await locator.gps(), isA<LocateFailed>().having((f) => f.problem, 'problem', LocateProblem.noFix));
  });

  test('positions keep their time in UTC', () async {
    final p = await WindowsLocationPlatform(channel: channel).position(precise: false, timeLimit: const Duration(seconds: 15));
    expect(p, isA<WindowsPosition>());
    expect(p.timestamp, DateTime.utc(2026, 11, 25, 18));
    expect(p.timestamp.isUtc, isTrue);
    expect(WindowsLocationPlatform(channel: channel).sourceOf(p, precise: true), FixSource.network);
    expect(const GeolocatorPlatformAdapter().sourceOf(p, precise: true), FixSource.gps,
        reason: 'on a phone, a precise request is answered by GPS');
    expect(LocationPermission.values, contains(LocationPermission.deniedForever));
  });
}
