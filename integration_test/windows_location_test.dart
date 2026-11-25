/// Checks the Windows location channel inside the real app binary, against
/// the real Windows location service. Run on a Windows PC:
///
///     flutter test integration_test/windows_location_test.dart -d windows
///
/// The answer depends on the PC's settings, so the test accepts any of the
/// outcomes the app handles, and prints which one it got.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/location/locator.dart';
import 'package:holdfast/location/windows_location.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Windows location service answers through the channel', (tester) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    final status = await const MethodChannel('holdfast/location').invokeMapMethod<String, Object?>('status');
    debugPrint('Windows location status: $status');
    expect(status!['access'], isIn(['allowed', 'denied', 'unspecified']));
    expect(status['status'], isIn(['ready', 'initializing', 'noData', 'disabled', 'notInitialized', 'notAvailable']));

    final result = await tester.runAsync(() => DeviceLocator(platform: WindowsLocationPlatform()).gps());
    switch (result!) {
      case Located(:final fix):
        debugPrint('Fix: ${fix.at} ±${fix.accuracyMeters.round()} m from ${fix.source.label}');
        expect(fix.accuracyMeters, greaterThan(0));
      case LocateFailed(:final problem):
        debugPrint('No fix: $problem');
        expect(problem, isNot(LocateProblem.unsupported), reason: 'the channel itself must answer');
    }
  });
}
