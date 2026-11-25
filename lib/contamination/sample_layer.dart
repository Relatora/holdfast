import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../routing/router.dart' show Avoid;
import 'contaminants.dart';
import 'interpolation.dart';
import 'sample.dart';

/// Colours for the five levels: the same traffic-light scale radiation
/// reports use, darkest for the worst.
extension ContaminationLevelStyle on ContaminationLevel {
  Color get color => switch (this) {
        ContaminationLevel.normal => const Color(0xFF43A047),
        ContaminationLevel.elevated => const Color(0xFFC0CA33),
        ContaminationLevel.high => const Color(0xFFFFA000),
        ContaminationLevel.veryHigh => const Color(0xFFE64A19),
        ContaminationLevel.dangerous => const Color(0xFF8E24AA),
      };
}

extension ContaminantStyle on Contaminant {
  IconData get icon => switch (exposure) {
        Exposure.chronic => Icons.science_rounded,
        Exposure.radiation => Icons.warning_amber_rounded,
      };
}

/// Estimated zones under the dots: translucent cells shaded by level, and
/// one label per zone saying what it is and that it is an estimate.
List<Widget> sampleZoneLayers(List<EstimatedZone> zones, {required void Function(Contaminant) onTapLabel}) {
  if (zones.isEmpty) return const [];
  return [
    PolygonLayer(
      polygons: [
        for (final zone in zones)
          for (final cell in zone.cells)
            Polygon(points: cell.outline, color: zone.levelOf(cell).color.withValues(alpha: 0.26)),
      ],
    ),
    MarkerLayer(
      markers: [
        for (final zone in zones)
          Marker(
            point: _labelPoint(zone),
            width: 230,
            height: 28,
            alignment: Alignment.topCenter,
            child: Center(
              child: GestureDetector(
                onTap: () => onTapLabel(zone.contaminant),
                child: _ZoneLabel(zone: zone),
              ),
            ),
          ),
      ],
    ),
  ];
}

/// Above the zone's northernmost cell, so the label doesn't hide the shading.
LatLng _labelPoint(EstimatedZone zone) {
  final top = zone.cells.reduce((a, b) => a.north > b.north ? a : b);
  return LatLng(top.north, top.center.longitude);
}

class _ZoneLabel extends StatelessWidget {
  const _ZoneLabel({required this.zone});
  final EstimatedZone zone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        '${zone.contaminant.label}: estimated from ${zone.sampleCount} samples',
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}

/// One dot per live sample, coloured by its level. A disputed sample is
/// faded, so a doubtful reading never looks as solid as a backed-up one.
Widget sampleDotLayer(
  List<Sample> samples, {
  required bool Function(Sample) disputed,
  required void Function(Sample) onTap,
}) {
  return MarkerLayer(
    markers: [
      for (final sample in samples)
        Marker(
          key: ValueKey('sample-${sample.id}'),
          point: LatLng(sample.latitude, sample.longitude),
          width: 30,
          height: 30,
          child: GestureDetector(
            onTap: () => onTap(sample),
            child: Semantics(
              button: true,
              label: '${sample.contaminant.label} reading: ${sample.contaminant.format(sample.value)}, '
                  '${sample.level.label.toLowerCase()}',
              child: Opacity(
                opacity: disputed(sample) ? 0.45 : 1,
                child: _SampleDot(level: sample.level, icon: sample.contaminant.icon),
              ),
            ),
          ),
        ),
    ],
  );
}

class _SampleDot extends StatelessWidget {
  const _SampleDot({required this.level, required this.icon});
  final ContaminationLevel level;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    // A rounded square rather than a circle, so readings never read as
    // hazard markers or the location dot.
    return Center(
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: level.color,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(blurRadius: 3, color: Color(0x55000000))],
        ),
        child: Icon(icon, size: 13, color: Colors.white),
      ),
    );
  }
}

/// Ground a route should keep off: around very high and dangerous samples,
/// and across the estimated zone's very high and dangerous cells.
List<Avoid> sampleAvoidAreas(List<Sample> samples, List<EstimatedZone> zones) {
  const distance = Distance();
  return [
    for (final s in samples)
      if (s.level.avoid) Avoid(LatLng(s.latitude, s.longitude), 150),
    for (final zone in zones)
      for (final cell in zone.cells)
        if (zone.levelOf(cell).avoid)
          // A circle through the cell's corners covers the whole cell.
          Avoid(cell.center, distance.as(LengthUnit.Meter, cell.center, LatLng(cell.north, cell.east))),
  ];
}
