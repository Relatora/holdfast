import 'package:flutter_map/flutter_map.dart';
import 'package:material_ui/material_ui.dart';

import '../location/locator.dart';

/// The device's position on the map: a dot for a GPS fix, inside a circle
/// as wide as its likely error.
///
/// A rough fix (cell towers, network) gets a hollow, dashed-looking ring
/// and no solid dot, so a position that may be kilometres off never reads
/// as "you are exactly here".
List<Widget> locationLayers(Fix? fix, ColorScheme scheme) {
  if (fix == null) return const [];
  final color = fix.approximate ? scheme.tertiary : scheme.primary;
  return [
    CircleLayer(
      circles: [
        CircleMarker(
          point: fix.at,
          radius: fix.accuracyMeters,
          useRadiusInMeter: true,
          color: color.withValues(alpha: fix.approximate ? 0.10 : 0.15),
          borderColor: color.withValues(alpha: 0.7),
          borderStrokeWidth: fix.approximate ? 2 : 1,
        ),
      ],
    ),
    MarkerLayer(
      markers: [
        Marker(
          point: fix.at,
          width: 26,
          height: 26,
          child: Semantics(
            label: fix.approximate
                ? 'Your approximate location, from ${fix.source.label.toLowerCase()}, '
                    'within ${formatAccuracy(fix.accuracyMeters)}'
                : 'Your location, within ${formatAccuracy(fix.accuracyMeters)}',
            child: _Dot(color: color, hollow: fix.approximate),
          ),
        ),
      ],
    ),
  ];
}

/// "±40 m" or "±1.8 km".
String formatAccuracy(double meters) =>
    meters < 1000 ? '±${meters.round()} m' : '±${(meters / 1000).toStringAsFixed(1)} km';

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.hollow});

  final Color color;
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? Colors.white.withValues(alpha: 0.85) : color,
        border: Border.all(color: hollow ? color : Colors.white, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Color(0x55000000))],
      ),
    );
  }
}
