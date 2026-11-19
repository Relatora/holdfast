import 'package:material_ui/material_ui.dart';

/// Builds Holdfast's [ThemeData] for each palette.
///
/// The palettes are hand-picked rather than generated from a single seed:
/// a survival tool should feel calm and utilitarian, and each palette has a
/// job (sunlight legibility, dusk comfort, night-vision safety) that a seed
/// algorithm doesn't know about. [ColorScheme.fromSeed] still fills in the
/// dozens of secondary roles so every Material component looks consistent.
abstract final class AppTheme {
  // Light: warm sand background, forest-green actions, rust highlights.
  static const _sand = Color(0xFFF4EFE6);
  static const _forest = Color(0xFF2F6B3A);
  static const _rust = Color(0xFFB5651D);

  // Dark: deep slate with an amber accent that stays visible at low brightness.
  static const _slate = Color(0xFF0F1417);
  static const _slateSurface = Color(0xFF161D22);
  static const _amber = Color(0xFFFFB020);
  static const _teal = Color(0xFF3FC1A8);

  // Night vision: pure black and a single red hue at different intensities.
  // Blue is exactly zero and green stays tiny: those are the wavelengths
  // that undo the eye's dark adaptation.
  static const _nvRed = Color(0xFFFF2200);
  static const _nvDim = Color(0xFFB31A00);
  static const _nvFaint = Color(0xFF3A0800);

  /// Shared hazard red; overridden in night vision where everything is red.
  static const danger = Color(0xFFFF5A4E);

  static ThemeData light() => _build(
        ColorScheme.fromSeed(
          seedColor: _forest,
          brightness: Brightness.light,
          primary: _forest,
          secondary: _rust,
          surface: _sand,
        ),
      );

  static ThemeData dark() => _build(
        ColorScheme.fromSeed(
          seedColor: _amber,
          brightness: Brightness.dark,
          primary: _amber,
          onPrimary: _slate,
          secondary: _teal,
          surface: _slate,
          surfaceContainer: _slateSurface,
          error: danger,
        ),
      );

  /// Every role maps to one of three reds so no blue or green light leaks out.
  static ThemeData nightVision() => _build(
        const ColorScheme(
          brightness: Brightness.dark,
          primary: _nvRed,
          onPrimary: Colors.black,
          primaryContainer: _nvFaint,
          onPrimaryContainer: _nvRed,
          secondary: _nvDim,
          onSecondary: Colors.black,
          secondaryContainer: _nvFaint,
          onSecondaryContainer: _nvRed,
          tertiary: _nvDim,
          onTertiary: Colors.black,
          error: _nvRed,
          onError: Colors.black,
          surface: Colors.black,
          onSurface: _nvRed,
          onSurfaceVariant: _nvDim,
          surfaceContainerLowest: Colors.black,
          surfaceContainerLow: Color(0xFF0A0000),
          surfaceContainer: Color(0xFF120200),
          surfaceContainerHigh: Color(0xFF1A0300),
          surfaceContainerHighest: Color(0xFF220400),
          outline: _nvDim,
          outlineVariant: _nvFaint,
          inverseSurface: _nvRed,
          onInverseSurface: Colors.black,
          inversePrimary: _nvFaint,
          shadow: Colors.black,
          scrim: Colors.black,
          surfaceTint: Colors.transparent,
        ),
      );

  static ThemeData _build(ColorScheme scheme) {
    final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      // Bottom sheets and cards share one soft, rounded shape language.
      cardTheme: CardThemeData(
        shape: rounded,
        elevation: 0,
        color: scheme.surfaceContainer,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainer,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
        selectedColor: scheme.primaryContainer,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: rounded,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: rounded,
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          // A consistent zoom transition everywhere, including desktop and web.
          for (final platform in TargetPlatform.values)
            platform: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
