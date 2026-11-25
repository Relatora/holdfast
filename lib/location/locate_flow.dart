import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../map/location_layer.dart' show formatAccuracy;
import 'locator.dart';

/// "Go to my location", start to finish: GPS first; when that fails, a
/// sheet that says why and offers the way out that fits.
///
/// - Location off: turn it on (GPS works with no signal or data), then try
///   again as soon as the person comes back to the app.
/// - No GPS fix (indoors, under cover): locate by cell towers instead.
/// - Permission refused: ask again, or open the app's settings.
///
/// Returns the fix found, or null when the person gave up.
Future<Fix?> locateMe(BuildContext context, DeviceLocator locator) async {
  var result = await locator.gps();
  while (true) {
    if (!context.mounted) return null;
    switch (result) {
      case Located(:final fix):
        if (fix.approximate) _announceApproximate(context, fix);
        return fix;
      case LocateFailed(:final problem):
        final choice = await _showProblem(context, problem);
        if (!context.mounted) return null;
        switch (choice) {
          case null || _Choice.close:
            return null;
          case _Choice.retry:
            result = await locator.gps();
          case _Choice.approximate:
            result = await locator.approximate();
            if (result case LocateFailed(problem: LocateProblem.noFix)) {
              if (!context.mounted) return null;
              final again = await _showNothingHeard(context);
              if (again != _Choice.retry || !context.mounted) return null;
              result = await locator.approximate();
            }
          case _Choice.openLocationSettings:
            if (!await locator.openLocationSettings()) return null;
            // Pick up where we left off when they come back from Settings.
            await _nextResume();
            result = await locator.gps();
          case _Choice.openAppSettings:
            await locator.openAppSettings();
            await _nextResume();
            result = await locator.gps();
        }
    }
  }
}

enum _Choice { retry, approximate, openLocationSettings, openAppSettings, close }

/// Phones have a cell radio to listen with; desktops ask the system,
/// which locates them by Wi-Fi.
bool get _hasCellRadio => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Windows keeps location for desktop apps behind two switches in
/// Settings, with no prompt the app can show again.
bool get _isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

const _windowsSwitches = 'In Windows Settings, under Privacy & security > Location, turn on '
    '"Location services" and "Let desktop apps access your location".';

String get _approximateLabel => _hasCellRadio ? 'Use cell towers' : 'Use approximate location';

Future<_Choice?> _showProblem(BuildContext context, LocateProblem problem) {
  final (icon, title, body, actions) = switch (problem) {
    LocateProblem.serviceOff => (
        Icons.location_off_rounded,
        'Location is off',
        _hasCellRadio
            ? 'Turn on location to find yourself by GPS. GPS works with no signal and no data. '
                'Holdfast also needs location on to read nearby cell towers.'
            : _isWindows
                ? '$_windowsSwitches Windows finds this PC from nearby Wi-Fi networks.'
                : 'Turn on location in this device\'s settings to find yourself on the map.',
        [
          (_Choice.openLocationSettings, _isWindows ? 'Open location settings' : 'Turn on location'),
          (_Choice.close, 'Not now'),
        ],
      ),
    LocateProblem.noFix => (
        Icons.gps_not_fixed_rounded,
        'Can\'t get a GPS fix',
        _hasCellRadio
            ? 'GPS needs a view of the sky. Indoors or under cover it can take minutes. '
                'Nearby cell towers give a rough position right away, accurate to about a kilometre.'
            : 'No position came in time. An approximate location, from Wi-Fi networks nearby, '
                'may still work.',
        [(_Choice.approximate, _approximateLabel), (_Choice.retry, 'Keep trying')],
      ),
    LocateProblem.denied => (
        Icons.location_disabled_rounded,
        'Holdfast can\'t see your location',
        'Allow location to find yourself on the map. Your position stays on this device.',
        [(_Choice.retry, 'Allow location'), (_Choice.close, 'Not now')],
      ),
    LocateProblem.deniedForever => (
        Icons.location_disabled_rounded,
        'Location is blocked for Holdfast',
        _isWindows
            ? _windowsSwitches
            : 'You chose not to be asked again. To find yourself on the map, allow location in '
                'Holdfast\'s app settings.',
        [
          (_Choice.openAppSettings, _isWindows ? 'Open location settings' : 'Open app settings'),
          (_Choice.close, 'Not now'),
        ],
      ),
    LocateProblem.unsupported => (
        Icons.not_listed_location_rounded,
        'No location on this device',
        'This device has no location service. Move the map by hand, or search for a place.',
        [(_Choice.close, 'OK')],
      ),
  };
  return _sheet(context, icon: icon, title: title, body: body, actions: actions);
}

Future<_Choice?> _showNothingHeard(BuildContext context) => _sheet(
      context,
      icon: Icons.signal_cellular_off_rounded,
      title: 'No position found',
      body: _hasCellRadio
          ? 'No cell tower nearby could be placed on your downloaded maps, and the phone\'s network '
              'location didn\'t answer. Try near a window or outside, or download the map for this area.'
          : 'This device couldn\'t estimate where it is. Move the map by hand, or search for a place.',
      actions: [(_Choice.retry, 'Try again'), (_Choice.close, 'Close')],
    );

Future<_Choice?> _sheet(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String body,
  required List<(_Choice, String)> actions,
}) =>
    showModalBottomSheet<_Choice>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 32, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text(title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(body, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (i, (choice, label)) in actions.reversed.indexed)
                      i == actions.length - 1
                          ? FilledButton(onPressed: () => Navigator.pop(context, choice), child: Text(label))
                          : TextButton(onPressed: () => Navigator.pop(context, choice), child: Text(label)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

/// Says how rough the position is, so nobody takes a circle kilometres
/// wide for a pinpoint.
void _announceApproximate(BuildContext context, Fix fix) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('Approximate location from ${fix.source.label.toLowerCase()}, '
        '${formatAccuracy(fix.accuracyMeters)}'),
  ));
}

/// Completes when the app is next brought back to the front (after the
/// person visits the system settings), or after two minutes.
Future<void> _nextResume() {
  final done = Completer<void>();
  late final AppLifecycleListener listener;
  listener = AppLifecycleListener(onResume: () {
    if (!done.isCompleted) done.complete();
  });
  return done.future
      .timeout(const Duration(minutes: 2), onTimeout: () {})
      .whenComplete(listener.dispose)
      // Android hands the app its drawing surface back a moment after
      // "resumed". Map tiles drawn before that never finish, and a flight
      // started at once left the basemap blank under its pins.
      .then((_) => Future<void>.delayed(const Duration(milliseconds: 800)));
}
