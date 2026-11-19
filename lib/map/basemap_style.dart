/// Basemap styles that follow the app theme, including a night-vision style
/// generated from the dark one.
library;

import 'package:material_ui/material_ui.dart' show Color;
// The v4 layer lists aren't exported publicly; we need the raw JSON to
// recolour it for night vision, so import them directly.
// ignore: implementation_imports
import 'package:vector_map_tiles_pmtiles/src/themes/v4/_package.dart' as v4;
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../theme/app_theme_mode.dart';

/// Map style for a resolved theme mode. Results are cached because parsing
/// a style is far more expensive than switching between parsed ones.
///
/// Every style gets its own id. The renderer caches tiles by theme id, and
/// styles built from Protomaps layer lists all default to the id "default",
/// so without this a theme switch re-uses tiles drawn in the old colours.
vtr.Theme basemapStyleFor(AppThemeMode resolvedMode) => _cache.putIfAbsent(
      resolvedMode,
      () => switch (resolvedMode) {
        AppThemeMode.light || AppThemeMode.system => ProtomapsThemes.lightV4(),
        AppThemeMode.dark => ProtomapsThemes.darkV4(),
        AppThemeMode.nightVision => const ProtomapsThemes().build(nightVisionLayers()),
      }
          .copyWith(id: 'holdfast-${resolvedMode.name}'),
    );

final _cache = <AppThemeMode, vtr.Theme>{};

/// The Protomaps dark style with every colour mapped onto a single red hue.
List<Map<String, Object>> nightVisionLayers() =>
    [for (final layer in v4.themeDark) _recolour(layer) as Map<String, Object>];

/// Walks a style value (maps, lists, expressions) and converts each colour.
Object _recolour(Object value) {
  if (value is Map) {
    return <String, Object>{
      for (final entry in value.entries) entry.key as String: _recolour(entry.value as Object),
    };
  }
  if (value is List) return [for (final item in value) _recolour(item as Object)];
  if (value is String) return toNightVision(value) ?? value;
  return value;
}

/// Converts a CSS colour string to the night-vision palette, or returns null
/// if [css] isn't a colour (style JSON mixes colours with names and fonts).
///
/// Brightness is preserved as red intensity, so roads still stand out from
/// land and water stays distinct, just without any blue or green light.
String? toNightVision(String css) {
  final color = parseCssColor(css);
  if (color == null) return null;
  final luminance = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
  // Squash into a dim range: dark-adapted eyes need very little light.
  final red = (20 + luminance * 200).round().clamp(0, 255);
  final green = (luminance * 18).round().clamp(0, 255);
  final alpha = color.a;
  return alpha >= 0.999
      ? '#${_hex(red)}${_hex(green)}00'
      : 'rgba($red,$green,0,${alpha.toStringAsFixed(3)})';
}

String _hex(int v) => v.toRadixString(16).padLeft(2, '0');

/// Parses `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(...)` and `rgba(...)`.
Color? parseCssColor(String css) {
  final s = css.trim().toLowerCase();
  if (s.startsWith('#')) {
    var hex = s.substring(1);
    if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
    if (hex.length != 6 && hex.length != 8) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    return hex.length == 6
        ? Color(0xFF000000 | value)
        : Color(((value & 0xFF) << 24) | (value >> 8));
  }
  final match = RegExp(r'^rgba?\(([^)]*)\)$').firstMatch(s);
  if (match == null) return null;
  final parts = match.group(1)!.split(',').map((p) => double.tryParse(p.trim())).toList();
  if (parts.length < 3 || parts.any((p) => p == null)) return null;
  return Color.from(
    alpha: parts.length > 3 ? parts[3]! : 1,
    red: parts[0]! / 255,
    green: parts[1]! / 255,
    blue: parts[2]! / 255,
  );
}
