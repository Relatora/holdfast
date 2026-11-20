import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/theme/app_theme.dart';
import 'package:holdfast/theme/app_theme_mode.dart';
import 'package:holdfast/theme/theme_toggle_button.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('system resolves to the OS brightness', () {
    expect(resolveThemeMode(AppThemeMode.system, Brightness.dark), AppThemeMode.dark);
    expect(resolveThemeMode(AppThemeMode.system, Brightness.light), AppThemeMode.light);
    expect(resolveThemeMode(AppThemeMode.nightVision, Brightness.light), AppThemeMode.nightVision);
  });

  test('the toggle cycles light → dark → night vision → light', () {
    var mode = AppThemeMode.light;
    final seen = <AppThemeMode>[];
    for (var i = 0; i < 3; i++) {
      mode = nextThemeMode(mode, Brightness.light);
      seen.add(mode);
    }
    expect(seen, [AppThemeMode.dark, AppThemeMode.nightVision, AppThemeMode.light]);
  });

  test('the first tap from "system" always changes what is on screen', () {
    expect(nextThemeMode(AppThemeMode.system, Brightness.dark), AppThemeMode.nightVision);
    expect(nextThemeMode(AppThemeMode.system, Brightness.light), AppThemeMode.dark);
  });

  test('unknown stored values fall back to system', () {
    expect(AppThemeMode.parse('sepia'), AppThemeMode.system);
    expect(AppThemeMode.parse(null), AppThemeMode.system);
  });

  test('night vision emits no blue or green light in its main colours', () {
    final scheme = AppTheme.nightVision().colorScheme;
    for (final color in [scheme.primary, scheme.onSurface, scheme.secondary, scheme.surface]) {
      expect(color.b, 0, reason: '$color has blue');
      expect(color.g, lessThan(0.2), reason: '$color has green');
    }
  });

  test('night vision text carries no blue light, in every text style', () {
    final text = AppTheme.nightVision().textTheme;
    final styles = {
      'displayLarge': text.displayLarge,
      'headlineSmall': text.headlineSmall,
      'titleLarge': text.titleLarge,
      'titleMedium': text.titleMedium,
      'bodyLarge': text.bodyLarge,
      'bodyMedium': text.bodyMedium,
      'bodySmall': text.bodySmall,
      'labelLarge': text.labelLarge,
    };
    for (final MapEntry(key: name, value: style) in styles.entries) {
      final color = style?.color;
      expect(color, isNotNull, reason: name);
      expect((color!.b * 255).round(), 0, reason: '$name must have no blue');
    }
  });

  test('headings and figures use the condensed face, body text the regular one', () {
    final text = AppTheme.dark().textTheme;
    expect(text.headlineSmall?.fontFamily, AppTheme.displayFamily);
    expect(text.titleLarge?.fontFamily, AppTheme.displayFamily);
    expect(text.bodyMedium?.fontFamily, AppTheme.bodyFamily);
  });
}
