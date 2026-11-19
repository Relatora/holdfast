import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/map/basemap_style.dart';
import 'package:holdfast/theme/app_theme_mode.dart';

void main() {
  group('parseCssColor', () {
    test('reads the formats used in Protomaps styles', () {
      expect(parseCssColor('#fff')!.toARGB32(), 0xFFFFFFFF);
      expect(parseCssColor('#34373d')!.toARGB32(), 0xFF34373D);
      expect(parseCssColor('rgba(0, 0, 0, 0.5)')!.a, closeTo(0.5, 0.01));
      expect(parseCssColor('rgb(255,0,0)')!.r, 1);
    });

    test('ignores strings that are not colours', () {
      expect(parseCssColor('Noto Sans Regular'), isNull);
      expect(parseCssColor('#zzzzzz'), isNull);
    });
  });

  group('toNightVision', () {
    test('produces red-only colours', () {
      final converted = parseCssColor(toNightVision('#4aa3df')!)!;
      expect(converted.b, 0);
      expect(converted.r, greaterThan(converted.g * 5));
    });

    test('keeps brighter inputs brighter, so roads stay visible on land', () {
      final dark = parseCssColor(toNightVision('#222222')!)!;
      final light = parseCssColor(toNightVision('#dddddd')!)!;
      expect(light.r, greaterThan(dark.r));
    });

    test('preserves transparency', () {
      expect(toNightVision('rgba(255,255,255,0.25)'), startsWith('rgba('));
    });
  });

  test('every layer of the night-vision style is free of blue light', () {
    final colours = <String>[];
    void collect(Object? value) {
      if (value is Map) value.values.forEach(collect);
      if (value is List) value.forEach(collect);
      if (value is String && parseCssColor(value) != null) colours.add(value);
    }

    nightVisionLayers().forEach(collect);
    expect(colours, isNotEmpty);
    expect(colours.every((c) => parseCssColor(c)!.b == 0), isTrue);
  });

  test('each map style has its own cache id', () {
    // Regression: the renderer caches tiles per theme id, and shared ids
    // left grey tiles on screen after switching to night vision.
    final ids = {
      for (final mode in [AppThemeMode.light, AppThemeMode.dark, AppThemeMode.nightVision])
        basemapStyleFor(mode).id,
    };
    expect(ids, hasLength(3));
  });
}
