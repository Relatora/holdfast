/// Drawing and explaining a nuclear detonation's effect rings: the map
/// layer, the colours, and the legend in the hazard details sheet.
library;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../regions/region_files.dart' show SidePack;
import '../../regions/region_store.dart';
import '../../settings/app_settings.dart';
import '../../training/training_hooks.dart';
import '../hazard.dart';
import '../hazard_details.dart';
import 'nuclear_effects.dart';
import 'population_grid.dart';

extension RingStyle on RingKind {
  /// Hot colours for the blast, a sickly green for radiation, so the two
  /// views read differently at a glance.
  Color get color => switch (this) {
        RingKind.fireball => const Color(0xFFFFEB3B),
        RingKind.heavyBlast => const Color(0xFFB71C1C),
        RingKind.radiation => const Color(0xFF7CB342),
        RingKind.moderateBlast => const Color(0xFFF4511E),
        RingKind.thermal => const Color(0xFFFFA000),
        RingKind.lightBlast => const Color(0xFF90A4AE),
      };
}

/// The rings [view] shows for [details], largest first (for drawing).
List<EffectRing> ringsFor(NuclearDetails details, NuclearView view) {
  final rings = nuclearEffects(details);
  return switch (view) {
    NuclearView.human => rings,
    NuclearView.buildings => [for (final r in rings) if (r.kind.damagesBuildings) r],
    NuclearView.hidden => const [],
  };
}

/// Map layer with the rings of every nuclear detonation in [hazards].
Widget nuclearRingsLayer(Iterable<Hazard> hazards, NuclearView view) {
  final circles = <CircleMarker>[];
  for (final hazard in hazards) {
    final details = hazard.nuclear;
    if (details == null) continue;
    final rings = ringsFor(details, view).reversed; // big first, small on top
    for (final ring in rings) {
      circles.add(CircleMarker(
        point: LatLng(hazard.latitude, hazard.longitude),
        radius: ring.radiusMeters,
        useRadiusInMeter: true,
        color: ring.kind.color.withValues(alpha: 0.14),
        borderColor: ring.kind.color,
        borderStrokeWidth: 2,
      ));
    }
  }
  return CircleLayer(circles: circles);
}

String _km(double meters) => meters < 1000 ? '${(meters / 10).round() * 10} m' : '${(meters / 1000).toStringAsFixed(1)} km';

String _people(double n) {
  if (n < 1000) return '${(n / 10).round() * 10}';
  if (n < 1e6) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)} thousand';
  return '${(n / 1e6).toStringAsFixed(1)} million';
}

/// The legend and estimate in the details sheet of a nuclear detonation.
class NuclearEffectsPanel extends StatelessWidget {
  const NuclearEffectsPanel({super.key, required this.hazard, required this.details});

  final Hazard hazard;
  final NuclearDetails details;

  /// Decoded packs, per region: decoding is quick but not free, and the
  /// sheet rebuilds often.
  static final _grids = <String, Future<PopulationGrid?>>{};

  Future<PopulationGrid?> _grid(RegionStore store) {
    final region = store.activeRegion;
    if (region == null) return Future.value(null);
    // Keyed by data key, so an updated map's population grid is read anew.
    return _grids.putIfAbsent(store.dataKey(region), () async {
      final bytes = await store.sidePack(region, SidePack.population);
      if (bytes == null) return null;
      try {
        return PopulationGrid.decode(bytes);
      } on PopulationFormatException {
        return null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    TrainingHooks.report(const ViewedNuclearRings());
    final settings = context.watch<AppSettings>();
    final store = context.read<RegionStore>();
    final theme = Theme.of(context);
    final view = settings.nuclearView;
    final rings = ringsFor(details, view == NuclearView.hidden ? NuclearView.human : view);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        SegmentedButton<NuclearView>(
          segments: [for (final v in NuclearView.values) ButtonSegment(value: v, label: Text(v.label))],
          selected: {view},
          onSelectionChanged: (s) => settings.nuclearView = s.first,
        ),
        FutureBuilder<PopulationGrid?>(
          future: _grid(store),
          builder: (context, snapshot) {
            final grid = snapshot.data;
            if (grid == null) {
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  snapshot.connectionState == ConnectionState.done
                      ? 'No population data for this map, so only the rates are shown.'
                      : 'Estimating casualties…',
                  style: theme.textTheme.bodySmall,
                ),
              );
            }
            final all = nuclearEffects(details);
            final estimate = estimateCasualties(all, (r) => grid.within(hazard.latitude, hazard.longitude, r));
            return Card(
              margin: const EdgeInsets.only(top: 10),
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '≈ ${_people(estimate.deaths)} deaths, ${_people(estimate.injured)} injured',
                      style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onErrorContainer),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'A rough estimate from where people live, ignoring shelter, warning time and fallout. '
                      '${PopulationGrid.attribution}.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        for (final ring in rings)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(radius: 10, backgroundColor: ring.kind.color),
            title: Text('${ring.title} · ${_km(ring.radiusMeters)}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(view == NuclearView.buildings
                    ? ring.buildingEffect
                    : '~${(ring.fatalShare * 100).round()}% killed, ~${(ring.injuredShare * 100).round()}% injured. '
                        '${ring.humanEffect}'),
                Text(ring.functionalStatus, style: const TextStyle(fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        Text(
          'Distances from Glasstone & Dolan, The Effects of Nuclear Weapons (1977); '
          'casualty rates from the US OTA, The Effects of Nuclear War (1979).',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
