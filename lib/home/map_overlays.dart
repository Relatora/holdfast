/// The small floating widgets layered over the map.
library;

import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';

import '../hazards/hazard_repository.dart';
import '../pois/poi.dart';
import '../pois/poi_index.dart';
import '../regions/region.dart';

/// Search over the active region's supply locations, fully offline.
class PlaceSearchBar extends StatelessWidget {
  const PlaceSearchBar({
    super.key,
    required this.index,
    required this.onSelected,
    required this.onOpenSettings,
  });

  final PoiIndex index;
  final ValueChanged<Poi> onSelected;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return SearchAnchor(
      builder: (context, controller) => SearchBar(
        controller: controller,
        hintText: index.isEmpty ? 'Download a map to search' : 'Search Walmart, pharmacy, water…',
        leading: const Icon(Icons.search_rounded),
        elevation: const WidgetStatePropertyAll(3),
        onTap: controller.openView,
        onChanged: (_) => controller.openView(),
        trailing: [
          IconButton(tooltip: 'Settings', onPressed: onOpenSettings, icon: const Icon(Icons.tune_rounded)),
        ],
      ),
      suggestionsBuilder: (context, controller) {
        final matches = index.filter(query: controller.text).take(30);
        return [
          for (final poi in matches)
            ListTile(
              leading: Icon(poi.category.icon, color: poi.category.color),
              title: Text(poi.title),
              subtitle: Text([poi.category.label, ?poi.address].join(' · ')),
              onTap: () {
                controller.closeView(poi.title);
                onSelected(poi);
              },
            ),
        ];
      },
    );
  }
}

/// One-tap category filters. With none selected, every place shows once the
/// map is zoomed in far enough.
class CategoryChips extends StatelessWidget {
  const CategoryChips({
    super.key,
    required this.selected,
    required this.onToggle,
    required this.animate,
    this.nightVision = false,
  });

  final Set<PoiCategory> selected;
  final ValueChanged<PoiCategory> onToggle;
  final bool animate;

  /// Category colours include greens and blues; night vision drops them.
  final bool nightVision;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: PoiCategory.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final category = PoiCategory.values[i];
          final chip = FilterChip(
            avatar: Icon(
              category.icon,
              size: 18,
              color: selected.contains(category) || nightVision ? null : category.color,
            ),
            label: Text(category.shortLabel),
            selected: selected.contains(category),
            showCheckmark: false,
            onSelected: (_) => onToggle(category),
          );
          return animate
              ? chip.animate(delay: (40 * i).ms).fadeIn(duration: 300.ms).slideX(begin: 0.4, end: 0, curve: Curves.easeOutCubic)
              : chip;
        },
      ),
    );
  }
}

/// A rounded, translucent capsule used for the status lines.
class _Capsule extends StatelessWidget {
  const _Capsule({super.key, required this.icon, required this.text, this.color, this.onTap});

  final IconData icon;
  final String text;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.9),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color ?? scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({super.key, required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, text, color) = switch (status) {
      SyncStatus.idle => (Icons.cloud_queue_rounded, 'Not synced yet', null),
      SyncStatus.syncing => (Icons.sync_rounded, 'Syncing reports…', scheme.primary),
      SyncStatus.synced => (Icons.cloud_done_rounded, 'Reports synced', scheme.primary),
      SyncStatus.offline => (Icons.cloud_off_rounded, 'Offline: reports will sync later', scheme.error),
    };
    // Cross-fade between states so the line never flickers.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: _Capsule(key: ValueKey(status), icon: icon, text: text, color: color),
    );
  }
}

class RegionStatusChip extends StatelessWidget {
  const RegionStatusChip({super.key, required this.region, required this.offline});

  final Region? region;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final r = region;
    if (r == null) return const _Capsule(icon: Icons.map_outlined, text: 'No map yet');
    return _Capsule(
      icon: offline ? Icons.offline_pin_rounded : Icons.public_rounded,
      text: offline ? 'Offline map: ${r.name}' : 'Streaming: ${r.name}',
    );
  }
}

/// OpenStreetMap's licence requires visible attribution on the map.
class AttributionChip extends StatelessWidget {
  const AttributionChip({super.key});

  @override
  Widget build(BuildContext context) {
    return _Capsule(
      icon: Icons.copyright_rounded,
      text: 'OpenStreetMap · Protomaps',
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Map data'),
          content: const Text(
            'Map data © OpenStreetMap contributors, available under the Open '
            'Database License (ODbL 1.0) at openstreetmap.org/copyright.\n\n'
            'Basemap tiles and styles by Protomaps (protomaps.com), styles CC0.\n\n'
            'Hazard reports come from Holdfast users and may be wrong or out of '
            'date. Always follow instructions from local authorities.',
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      ),
    );
  }
}

/// Shown over the contour background until the first map is downloaded.
class NoMapCard extends StatelessWidget {
  const NoMapCard({super.key, required this.onChoose});

  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_rounded, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('No offline map yet', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                'Download a city, province, country, continent or the whole world. '
                'It keeps working when the network does not.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onChoose,
                icon: const Icon(Icons.download_rounded),
                label: const Text('Choose a map'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
