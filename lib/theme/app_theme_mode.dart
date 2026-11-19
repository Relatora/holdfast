/// The four looks Holdfast can take.
///
/// [nightVision] is a deliberate addition to the usual light/dark pair: an
/// all-red, low-brightness palette. Red light barely affects the eye's dark
/// adaptation, so someone checking the map at night can look away and still
/// see in the dark. On OLED phones the mostly-black pixels also save battery.
enum AppThemeMode {
  /// Follow the operating system's light/dark setting.
  system('System', 'Match your device'),

  /// Warm sand and forest green; readable in direct sunlight.
  light('Light', 'Best outdoors in daylight'),

  /// Deep slate with an amber accent.
  dark('Dark', 'Easy on the eyes at dusk'),

  /// Red on black; preserves night vision.
  nightVision('Night vision', 'Red light keeps your eyes dark-adapted');

  const AppThemeMode(this.label, this.description);

  /// Short name shown in pickers.
  final String label;

  /// One-line explanation shown under [label].
  final String description;

  /// Parses a stored value, falling back to [system] for unknown or missing
  /// values so an old or corrupted preference never crashes start-up.
  static AppThemeMode parse(String? name) => AppThemeMode.values.firstWhere(
        (mode) => mode.name == name,
        orElse: () => AppThemeMode.system,
      );
}
