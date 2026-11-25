import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'brand/intro_overlay.dart';
import 'home/home_screen.dart';
import 'settings/app_settings.dart';
import 'theme/app_theme.dart';
import 'theme/app_theme_mode.dart';
import 'theme/motion.dart';
import 'theme/theme_reveal.dart';

/// Root widget: wires the theme preference into [MaterialApp].
class HoldfastApp extends StatelessWidget {
  const HoldfastApp({super.key, this.navigatorKey, this.showIntro = false});

  /// Lets a tapped notification open a screen from outside the tree.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Play the animated intro over the first screen. Read once at start, so
  /// switching it off in Settings takes effect from the next launch.
  final bool showIntro;

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppSettings, AppThemeMode>((s) => s.themeMode);

    // Night vision is a dark theme that ignores the OS setting entirely.
    final (light, dark, materialMode) = switch (mode) {
      AppThemeMode.system => (AppTheme.light(), AppTheme.dark(), ThemeMode.system),
      AppThemeMode.light => (AppTheme.light(), AppTheme.dark(), ThemeMode.light),
      AppThemeMode.dark => (AppTheme.light(), AppTheme.dark(), ThemeMode.dark),
      AppThemeMode.nightVision => (AppTheme.nightVision(), AppTheme.nightVision(), ThemeMode.dark),
    };

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Holdfast',
      debugShowCheckedModeBanner: false,
      theme: light,
      darkTheme: dark,
      themeMode: materialMode,
      // ThemeReveal does the transition, so MaterialApp shouldn't lerp too.
      themeAnimationDuration: Duration.zero,
      // The intro plays over the app while the map loads underneath.
      builder: (context, child) => ThemeReveal(
        child: IntroOverlay(
          enabled: showIntro,
          animate: Motion.enabled(context),
          nightVision: mode == AppThemeMode.nightVision,
          child: child!,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
