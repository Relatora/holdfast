import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../regions/region.dart';

/// Outlines of the downloaded regions, each labelled in its north-west
/// corner, for when the map also streams. A label shows only while its
/// region spans a good part of the screen at [zoom]; further out it would
/// be wider than the outline it names.
///
/// Online, a streamed street looks exactly like a saved one. These lines
/// show where the map stops working with no network: inside an outline,
/// everything comes from the device.
List<Widget> savedAreaLayers(List<Region> saved, ColorScheme scheme, {required double zoom}) {
  if (saved.isEmpty) return const [];
  return [
    PolygonLayer(
      polygons: [
        for (final r in saved)
          Polygon(
            points: [
              LatLng(r.north, r.west),
              LatLng(r.north, r.east),
              LatLng(r.south, r.east),
              LatLng(r.south, r.west),
            ],
            color: scheme.primary.withValues(alpha: 0.04),
            borderColor: scheme.primary,
            borderStrokeWidth: 2.5,
          ),
      ],
    ),
    MarkerLayer(
      markers: [
        for (final r in saved)
          // fitZoom frames the region; a step and a half out, it's about a
          // third of the screen across, still wider than the label.
          if (zoom >= r.fitZoom - 1.5)
            Marker(
              point: LatLng(r.north, r.west),
              width: 220,
              height: 30,
              // Below and to the right of the corner: inside the outline.
              alignment: Alignment.bottomRight,
              child: Align(
                alignment: Alignment.topLeft,
                child: _SavedLabel(region: r, scheme: scheme),
              ),
            ),
      ],
    ),
  ];
}

class _SavedLabel extends StatelessWidget {
  const _SavedLabel({required this.region, required this.scheme});

  final Region region;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.offline_pin_rounded, size: 14, color: scheme.onPrimary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '${region.name} saved offline',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
