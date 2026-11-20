import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../pois/poi.dart' show formatDistance;
import 'directions.dart';
import 'router.dart';

/// The bottom panel while directions are open: mode, summary, start point
/// and the step-by-step list.
class DirectionsPanel extends StatelessWidget {
  const DirectionsPanel({super.key, required this.directions, required this.onStepTap});

  final Directions directions;

  /// Moves the map to a step.
  final ValueChanged<RouteStep> onStepTap;

  static IconData iconFor(TravelMode mode) => switch (mode) {
        TravelMode.walk => Icons.directions_walk_rounded,
        TravelMode.bike => Icons.directions_bike_rounded,
        TravelMode.car => Icons.directions_car_rounded,
        TravelMode.train => Icons.train_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = directions;
    final plan = d.plan;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        // Never cover more than half the map: the route is the point.
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5, maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  Icon(Icons.flag_rounded, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'To ${d.destinationLabel}',
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(tooltip: 'Close directions', onPressed: d.close, icon: const Icon(Icons.close_rounded)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SegmentedButton<TravelMode>(
                segments: [
                  for (final mode in TravelMode.values)
                    ButtonSegment(value: mode, icon: Icon(iconFor(mode)), label: Text(mode.label)),
                ],
                selected: {d.mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => d.setMode(s.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('From', style: theme.textTheme.labelLarge),
                  ChoiceChip(
                    avatar: const Icon(Icons.my_location_rounded, size: 18),
                    label: const Text('My location'),
                    selected: d.fromMyLocation,
                    onSelected: (_) => d.useMyLocation(true),
                  ),
                  ChoiceChip(
                    avatar: const Icon(Icons.center_focus_strong_rounded, size: 18),
                    label: const Text('Map centre'),
                    selected: !d.fromMyLocation,
                    onSelected: (_) => d.useMyLocation(false),
                  ),
                ],
              ),
            ),
            if (d.busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
            if (d.notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.location_off_outlined, color: scheme.onSurfaceVariant, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(d.notice!, style: theme.textTheme.bodySmall)),
                  ],
                ),
              ),
            if (d.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, color: scheme.error, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(d.error!)),
                  ],
                ),
              ),
            if (plan != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  children: [
                    Text(_duration(plan.duration),
                        style: theme.textTheme.headlineSmall?.copyWith(color: scheme.primary)),
                    const SizedBox(width: 10),
                    Text(formatDistance(plan.meters), style: theme.textTheme.titleMedium),
                    const Spacer(),
                    if (plan.throughHazard)
                      _Badge(icon: Icons.warning_amber_rounded, text: 'Passes a hazard', color: scheme.error)
                    else if (plan.avoided > 0)
                      _Badge(
                        icon: Icons.shield_outlined,
                        text: 'Avoiding ${plan.avoided} hazard${plan.avoided == 1 ? '' : 's'}',
                        color: scheme.primary,
                      ),
                  ],
                ),
              ),
              if (plan.throughHazard)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'No route avoids every reported hazard. Take care, and check the hazard markers on the way.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
                ),
              const Divider(height: 16),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final leg in plan.legs)
                      for (final step in leg.steps)
                        ListTile(
                          dense: true,
                          leading: Icon(_turnIcon(step.turn, leg.kind), color: scheme.onSurfaceVariant),
                          title: Text(step.instruction),
                          trailing: step.meters > 0 ? Text(formatDistance(step.meters)) : null,
                          onTap: () => onStepTap(step),
                        ),
                  ],
                ),
              ),
            ] else
              const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  static String _duration(Duration d) {
    if (d.inMinutes < 1) return '< 1 min';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    return '${d.inHours} h ${d.inMinutes % 60} min';
  }

  static IconData _turnIcon(Turn turn, LegKind kind) {
    if (kind == LegKind.rail) return Icons.train_rounded;
    return switch (turn) {
      Turn.start => Icons.trip_origin_rounded,
      Turn.straight => Icons.straight_rounded,
      Turn.slightLeft => Icons.turn_slight_left_rounded,
      Turn.left => Icons.turn_left_rounded,
      Turn.sharpLeft => Icons.turn_sharp_left_rounded,
      Turn.slightRight => Icons.turn_slight_right_rounded,
      Turn.right => Icons.turn_right_rounded,
      Turn.sharpRight => Icons.turn_sharp_right_rounded,
      Turn.uTurn => Icons.u_turn_left_rounded,
      Turn.arrive => Icons.flag_rounded,
    };
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      );
}

/// The route on the map: one line per leg (walking legs dotted, the train
/// leg thicker), plus start and destination markers.
List<Widget> routeLayers(RoutePlan plan, ColorScheme scheme) {
  final walkColor = scheme.primary, rideColor = scheme.tertiary;
  return [
    PolylineLayer(
      polylines: [
        for (final leg in plan.legs)
          Polyline(
            points: leg.points,
            strokeWidth: leg.kind == LegKind.rail ? 7 : 5,
            color: leg.kind == LegKind.rail ? rideColor : walkColor,
            borderStrokeWidth: 2,
            borderColor: scheme.surface,
            pattern: leg.kind == LegKind.walk && plan.mode == TravelMode.train
                ? StrokePattern.dotted(spacingFactor: 1.6)
                : const StrokePattern.solid(),
          ),
      ],
    ),
    MarkerLayer(
      markers: [
        _endpoint(plan.legs.first.points.first, Icons.trip_origin_rounded, scheme.primary, scheme.surface),
        _endpoint(plan.legs.last.points.last, Icons.flag_rounded, scheme.error, scheme.surface),
      ],
    ),
  ];
}

Marker _endpoint(LatLng at, IconData icon, Color color, Color background) => Marker(
      point: at,
      width: 32,
      height: 32,
      child: DecoratedBox(
        decoration: BoxDecoration(color: background, shape: BoxShape.circle),
        child: Icon(icon, color: color, size: 24),
      ),
    );
