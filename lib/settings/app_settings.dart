import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../hazards/hazard.dart';
import '../theme/app_theme_mode.dart';

/// User preferences that survive restarts, exposed as a [ChangeNotifier] so
/// widgets rebuild when a setting changes.
///
/// Everything is stored in [SharedPreferences]: these are a handful of small
/// values, and keeping them out of the hazard/region stores means a corrupt
/// map download can never reset someone's theme or onboarding choice.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs, {required this.isFirstLaunch});

  /// Loads settings and records that the app has now been opened once.
  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final firstLaunch = !(prefs.getBool(_kLaunchedBefore) ?? false);
    await prefs.setBool(_kLaunchedBefore, true);
    if (prefs.getString(_kDeviceId) == null) {
      await prefs.setString(_kDeviceId, const Uuid().v4());
    }
    return AppSettings._(prefs, isFirstLaunch: firstLaunch);
  }

  static const _kLaunchedBefore = 'launchedBefore';
  static const _kThemeMode = 'themeMode';
  static const _kBatterySaver = 'batterySaver';
  static const _kOnboardingDismissed = 'onboardingDismissed';
  static const _kShowUnverified = 'showUnverifiedHazards';
  static const _kHazardCategories = 'hazardCategories';
  static const _kNuclearView = 'nuclearView';
  static const _kFetchWind = 'fetchWind';
  static const _kDeviceId = 'deviceId';

  final SharedPreferences _prefs;

  /// True only during the very first session after install.
  final bool isFirstLaunch;

  /// Random, stable identifier for this install. Hazard votes are counted
  /// once per device, so this is what stops one phone from verifying its own
  /// report. (Signed device keys replace it in a later milestone.)
  String get deviceId => _prefs.getString(_kDeviceId)!;

  AppThemeMode get themeMode => AppThemeMode.parse(_prefs.getString(_kThemeMode));
  set themeMode(AppThemeMode value) {
    _prefs.setString(_kThemeMode, value.name);
    notifyListeners();
  }

  /// Battery saver turns off decorative animation and pulsing markers. It is
  /// the "emergency mode" switch: looking good must never cost battery when
  /// it matters.
  bool get batterySaver => _prefs.getBool(_kBatterySaver) ?? false;
  set batterySaver(bool value) {
    _prefs.setBool(_kBatterySaver, value);
    notifyListeners();
  }

  /// Set by the "Don't show me this again" box on the welcome cards.
  bool get onboardingDismissed => _prefs.getBool(_kOnboardingDismissed) ?? false;
  set onboardingDismissed(bool value) {
    _prefs.setBool(_kOnboardingDismissed, value);
    notifyListeners();
  }

  /// Unverified reports are hidden by default to limit panic and abuse;
  /// people who want the raw feed can opt in.
  bool get showUnverifiedHazards => _prefs.getBool(_kShowUnverified) ?? false;
  set showUnverifiedHazards(bool value) {
    _prefs.setBool(_kShowUnverified, value);
    notifyListeners();
  }

  /// Hazard categories shown on the map; empty means every category. A
  /// shortlist, so someone tracking floods isn't wading through every
  /// police report. Directions still avoid hazards that are filtered out.
  Set<HazardCategory> get hazardCategories => {
        for (final name in _prefs.getStringList(_kHazardCategories) ?? const <String>[])
          ?HazardCategory.values.asNameMap()[name],
      };
  set hazardCategories(Set<HazardCategory> value) {
    _prefs.setStringList(_kHazardCategories, [for (final c in value) c.name]);
    notifyListeners();
  }

  /// Whether "Use current wind" may ask Open-Meteo for the wind at a
  /// hazard. Only the hazard's coordinates are sent.
  bool get fetchWind => _prefs.getBool(_kFetchWind) ?? true;
  set fetchWind(bool value) {
    _prefs.setBool(_kFetchWind, value);
    notifyListeners();
  }

  /// Which effect rings nuclear detonation reports draw on the map.
  NuclearView get nuclearView => NuclearView.values.asNameMap()[_prefs.getString(_kNuclearView)] ?? NuclearView.human;
  set nuclearView(NuclearView value) {
    _prefs.setString(_kNuclearView, value.name);
    notifyListeners();
  }
}

/// The two ways to read a nuclear detonation's rings, or none.
enum NuclearView {
  human('Human impact'),
  buildings('Building damage'),
  hidden('Hide rings');

  const NuclearView(this.label);
  final String label;
}
