import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../settings/app_settings.dart';

/// Decides whether decorative animation should run right now.
///
/// Two things switch it off:
/// * the operating system's "reduce motion" accessibility setting, and
/// * Holdfast's own battery saver.
///
/// Widgets call [Motion.enabled] instead of checking either flag directly, so
/// the policy lives in one place. Functional transitions (a sheet sliding in,
/// a page changing) still run; only the purely decorative extras stop.
abstract final class Motion {
  static bool enabled(BuildContext context) {
    final reducedByOs = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final batterySaver = context.select<AppSettings, bool>((s) => s.batterySaver);
    return !reducedByOs && !batterySaver;
  }

  /// Same as [enabled] but safe to call outside `build` (no subscription).
  static bool enabledNow(BuildContext context) {
    final reducedByOs = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return !reducedByOs && !context.read<AppSettings>().batterySaver;
  }
}
