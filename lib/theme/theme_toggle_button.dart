import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../settings/app_settings.dart';
import 'app_theme_mode.dart';
import 'motion.dart';
import 'theme_reveal.dart';

/// The concrete palette a mode resolves to on this device right now.
/// [AppThemeMode.system] becomes light or dark depending on the OS.
AppThemeMode resolveThemeMode(AppThemeMode mode, Brightness platformBrightness) {
  if (mode != AppThemeMode.system) return mode;
  return platformBrightness == Brightness.dark ? AppThemeMode.dark : AppThemeMode.light;
}

/// Light → dark → night vision → light. Starting from "system" moves on from
/// whatever system currently looks like, so the first tap always changes
/// something visible.
AppThemeMode nextThemeMode(AppThemeMode current, Brightness platformBrightness) {
  return switch (resolveThemeMode(current, platformBrightness)) {
    AppThemeMode.light => AppThemeMode.dark,
    AppThemeMode.dark => AppThemeMode.nightVision,
    _ => AppThemeMode.light,
  };
}

/// Changes the theme with the circular reveal, starting at [origin].
Future<void> switchTheme(BuildContext context, AppThemeMode mode, Offset origin) {
  final settings = context.read<AppSettings>();
  return ThemeReveal.of(context).reveal(
    origin: origin,
    animate: Motion.enabledNow(context),
    applyChange: () => settings.themeMode = mode,
  );
}

/// Map-screen button: tap to cycle palettes, long-press to pick one.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  static IconData iconFor(AppThemeMode mode) => switch (mode) {
        AppThemeMode.light => Icons.light_mode_rounded,
        AppThemeMode.dark => Icons.dark_mode_rounded,
        AppThemeMode.nightVision => Icons.visibility_rounded,
        AppThemeMode.system => Icons.brightness_auto_rounded,
      };

  Offset _centreOf(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppSettings, AppThemeMode>((s) => s.themeMode);
    final brightness = MediaQuery.platformBrightnessOf(context);
    final resolved = resolveThemeMode(mode, brightness);
    return Tooltip(
      message: 'Theme: ${resolved.label} (long-press for all)',
      child: GestureDetector(
        onLongPress: () => showThemePicker(context),
        child: FloatingActionButton.small(
          heroTag: 'theme',
          onPressed: () => switchTheme(
            context,
            nextThemeMode(mode, brightness),
            _centreOf(context),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) => RotationTransition(
              turns: Tween(begin: -0.25, end: 0.0).animate(animation),
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: Icon(iconFor(resolved), key: ValueKey(resolved)),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet listing all four modes with a live colour swatch each.
Future<void> showThemePicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      final current = sheetContext.watch<AppSettings>().themeMode;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in AppThemeMode.values)
              Builder(
                builder: (tileContext) => ListTile(
                  leading: Icon(ThemeToggleButton.iconFor(mode)),
                  title: Text(mode.label),
                  subtitle: Text(mode.description),
                  trailing: current == mode ? const Icon(Icons.check_rounded) : null,
                  onTap: () {
                    final box = tileContext.findRenderObject()! as RenderBox;
                    final origin = box.localToGlobal(box.size.centerLeft(const Offset(40, 0)));
                    Navigator.pop(sheetContext);
                    switchTheme(context, mode, origin);
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
