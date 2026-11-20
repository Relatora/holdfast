import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../map/hazard_marker.dart';
import '../pois/poi.dart' show distanceMeters, formatDistance;
import '../settings/app_settings.dart';
import '../training/training_hooks.dart';
import 'hazard.dart';
import 'hazard_engine.dart';
import 'hazard_filter.dart';
import 'hazard_repository.dart';

/// The Hazards list: every active report around [from], with category
/// chips that shortlist what the map shows (remembered between sessions)
/// and a choice of order. Returns the hazard tapped, if any, once the
/// sheet has closed, so the caller can open its details without two
/// sheets fighting over the same moment.
Future<Hazard?> showHazardsSheet(BuildContext context, {required LatLng from}) {
  return showModalBottomSheet<Hazard>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _HazardsSheet(from: from),
  );
}

class _HazardsSheet extends StatefulWidget {
  const _HazardsSheet({required this.from});

  final LatLng from;

  @override
  State<_HazardsSheet> createState() => _HazardsSheetState();
}

class _HazardsSheetState extends State<_HazardsSheet> {
  HazardSort _sort = HazardSort.nearest;

  /// Tapping a category while everything is shown starts a shortlist of
  /// just that one; after that, taps add and remove. Emptying the
  /// shortlist means "show all" again.
  void _toggle(AppSettings settings, HazardCategory category) {
    final shown = settings.hazardCategories;
    if (shown.isEmpty) {
      settings.hazardCategories = {category};
    } else if (shown.contains(category)) {
      settings.hazardCategories = shown..remove(category);
    } else {
      settings.hazardCategories = shown..add(category);
    }
    TrainingHooks.report(FilteredHazards(settings.hazardCategories));
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final repo = context.watch<HazardRepository>();
    final theme = Theme.of(context);
    final shown = settings.hazardCategories;

    final active = [
      for (final h in repo.hazards)
        if (isVisible(repo.assess(h), showUnverified: settings.showUnverifiedHazards || repo.isSandbox)) h,
    ];
    final counts = countByCategory(active);
    final listed = sortHazards(
      active.where((h) => passesFilter(h, shown)),
      _sort,
      latitude: widget.from.latitude,
      longitude: widget.from.longitude,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: Row(
              children: [
                Expanded(child: Text('Hazards (${listed.length})', style: theme.textTheme.titleLarge)),
                if (shown.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => settings.hazardCategories = {},
                    icon: const Icon(Icons.select_all_rounded),
                    label: const Text('Show all'),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                FilterChip(
                  label: const Text('All'),
                  selected: shown.isEmpty,
                  onSelected: (_) => settings.hazardCategories = {},
                ),
                for (final category in HazardCategory.values)
                  if (category != HazardCategory.other || counts.containsKey(category))
                    FilterChip(
                      avatar: Icon(category.icon, size: 18),
                      label: Text('${category.label}${counts[category] != null ? ' · ${counts[category]}' : ''}'),
                      selected: shown.contains(category),
                      onSelected: (_) => _toggle(settings, category),
                    ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              shown.isEmpty
                  ? 'Showing every category.'
                  : 'The map shows only these categories. Directions still avoid every hazard.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: SegmentedButton<HazardSort>(
              segments: [for (final s in HazardSort.values) ButtonSegment(value: s, label: Text(s.label))],
              selected: {_sort},
              onSelectionChanged: (s) => setState(() => _sort = s.first),
            ),
          ),
          Flexible(
            child: listed.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      active.isEmpty ? 'No active hazards reported.' : 'No hazards in the chosen categories.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      for (final hazard in listed)
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: hazard.type.color,
                            child: Icon(hazard.type.icon, color: Colors.white, size: 20),
                          ),
                          title: Text(hazard.type.label),
                          subtitle: Text([
                            '${hazard.severity.label} severity',
                            switch (repo.assess(hazard).status) {
                              HazardStatus.verified => hazard.official ? 'official' : 'verified',
                              HazardStatus.disputed => 'disputed',
                              _ => 'unverified',
                            },
                          ].join(' · ')),
                          trailing: Text(formatDistance(distanceMeters(
                            widget.from.latitude,
                            widget.from.longitude,
                            hazard.latitude,
                            hazard.longitude,
                          ))),
                          onTap: () => Navigator.pop(context, hazard),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
