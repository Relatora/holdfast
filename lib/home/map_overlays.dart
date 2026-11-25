/// The small floating widgets layered over the map.
library;

import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../favorites/favorites_store.dart';
import '../favorites/star_button.dart';
import '../hazards/hazard_repository.dart';
import '../pois/poi.dart';
import '../pois/poi_index.dart';
import '../regions/region.dart';

/// Search over the active region's supply locations, fully offline.
///
/// With nothing typed, the search view shows the person's favourites:
/// saved searches as chips (tap to rerun) and starred places (tap to fly
/// there). While typing, the first row saves the query and every result
/// carries a star.
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
        void select(Poi poi) {
          controller.closeView(poi.title);
          // Closing the search view leaves the bar focused, and the keyboard
          // would cover the place sheet and the directions panel.
          FocusManager.instance.primaryFocus?.unfocus();
          onSelected(poi);
        }

        final query = controller.text.trim();
        if (query.isEmpty) {
          return [_FavoritesView(index: index, controller: controller, onSelected: select)];
        }
        final matches = index.filter(query: query).take(30);
        return [
          _SaveSearchTile(query: query),
          for (final poi in matches)
            ListTile(
              leading: Icon(poi.category.icon, color: poi.category.color),
              title: Text(poi.title),
              subtitle: Text([poi.category.label, ?poi.address].join(' · ')),
              trailing: StarButton(poi: poi),
              onTap: () => select(poi),
            ),
          if (matches.isEmpty)
            const ListTile(
              leading: Icon(Icons.search_off_rounded),
              title: Text('No places match in this map'),
            ),
        ];
      },
    );
  }
}

/// "Save this search" / "Search saved": the first row while typing.
class _SaveSearchTile extends StatelessWidget {
  const _SaveSearchTile({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final store = context.read<FavoritesStore>();
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final saved = store.isSaved(query);
        return ListTile(
          leading: Icon(
            saved ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
            color: saved ? scheme.primary : null,
          ),
          title: Text(saved ? 'Search saved' : 'Save this search'),
          subtitle: Text('“$query”'),
          trailing: saved ? const Text('Tap to remove') : null,
          onTap: () => saved ? store.removeSearch(query) : store.saveSearch(query),
        );
      },
    );
  }
}

/// The empty-query view: saved searches, then starred places.
///
/// One widget listening to the store, rather than a list of suggestions,
/// because the search view does not rebuild suggestions when favourites
/// change, only when the text does.
class _FavoritesView extends StatelessWidget {
  const _FavoritesView({required this.index, required this.controller, required this.onSelected});

  final PoiIndex index;
  final SearchController controller;
  final ValueChanged<Poi> onSelected;

  void _rerun(String query) {
    // Setting the value (not just the text) puts the cursor at the end, so
    // the person can keep typing to narrow the search.
    controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<FavoritesStore>();
    final theme = Theme.of(context);
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        );

    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final searches = store.searches;
        final places = store.places;
        if (searches.isEmpty && places.isEmpty) {
          return const ListTile(
            leading: Icon(Icons.star_outline_rounded),
            title: Text('No favourites yet'),
            subtitle: Text('Star a place or save a search, and it will be waiting here, offline.'),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (searches.isNotEmpty) ...[
              header('Saved searches'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final query in searches)
                      InputChip(
                        avatar: const Icon(Icons.bookmark_rounded, size: 18),
                        label: Text(query),
                        onPressed: () => _rerun(query),
                        onDeleted: () => store.removeSearch(query),
                        deleteButtonTooltipMessage: 'Remove saved search',
                      ),
                  ],
                ),
              ),
            ],
            if (places.isNotEmpty) ...[
              header('Starred places'),
              for (final saved in places)
                // Prefer the live copy so a refreshed pack's data wins; fall
                // back to the snapshot when this map doesn't have the place.
                _StarredPlaceTile(saved: saved, live: index.byId(saved.id), onSelected: onSelected),
            ],
          ],
        );
      },
    );
  }
}

class _StarredPlaceTile extends StatelessWidget {
  const _StarredPlaceTile({required this.saved, required this.live, required this.onSelected});

  final Poi saved;
  final Poi? live;
  final ValueChanged<Poi> onSelected;

  @override
  Widget build(BuildContext context) {
    final poi = live ?? saved;
    return ListTile(
      leading: Icon(poi.category.icon, color: poi.category.color),
      title: Text(poi.title),
      subtitle: Text([
        poi.category.label,
        if (live == null) 'not in this map' else ?poi.address,
      ].join(' · ')),
      trailing: StarButton(poi: poi),
      onTap: () => onSelected(poi),
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

/// Zoom in and out, stacked in one pill so they read as a pair.
class ZoomButtons extends StatelessWidget {
  const ZoomButtons({super.key, required this.onZoomIn, required this.onZoomOut});

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 3,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(tooltip: 'Zoom in', onPressed: onZoomIn, icon: const Icon(Icons.add_rounded)),
          SizedBox(width: 24, child: Divider(height: 1, color: scheme.outlineVariant)),
          IconButton(tooltip: 'Zoom out', onPressed: onZoomOut, icon: const Icon(Icons.remove_rounded)),
        ],
      ),
    );
  }
}

/// "Go to my location". Shows a spinner while looking, and a filled icon
/// once the device has been found.
class MyLocationButton extends StatelessWidget {
  const MyLocationButton({super.key, required this.busy, required this.located, required this.onPressed});

  final bool busy;
  final bool located;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      heroTag: 'myLocation',
      tooltip: busy ? 'Finding your location' : 'Go to my location',
      onPressed: busy ? null : onPressed,
      child: busy
          // In the button's own foreground colour (the icon theme the FAB
          // sets): the default, primary, vanishes on a primary button.
          ? Builder(
              builder: (context) => SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: IconTheme.of(context).color),
              ),
            )
          : Icon(located ? Icons.my_location_rounded : Icons.location_searching_rounded),
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
      // Chosen, not a fault: no alarming colour.
      SyncStatus.paused => (Icons.airplanemode_active_rounded, 'Offline mode: reports wait on this device', null),
    };
    // Cross-fade between states so the line never flickers.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: _Capsule(key: ValueKey(status), icon: icon, text: text, color: color),
    );
  }
}

class RegionStatusChip extends StatelessWidget {
  const RegionStatusChip({
    super.key,
    required this.region,
    required this.offline,
    this.updates = const [],
    this.streaming = false,
    this.centerRegion,
    this.onTap,
  });

  final Region? region;
  final bool offline;

  /// The world map is streaming beyond the downloaded maps. The chip then
  /// follows the centre of the map: [centerRegion] is the downloaded region
  /// there, or null when the centre is only streamed.
  final bool streaming;
  final Region? centerRegion;

  /// Maps on this device with a newer build waiting (not necessarily the
  /// one on screen). Said on the chip, which opens My maps, where the
  /// Update button is.
  final List<Region> updates;

  /// Opens the "My maps" switcher.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = region;
    if (r == null && streaming && updates.isEmpty) {
      return _Capsule(icon: Icons.cloud_outlined, text: 'Streaming: no map saved offline yet', onTap: onTap);
    }
    if (r == null) return _Capsule(icon: Icons.map_outlined, text: 'No map yet', onTap: onTap);
    // The update leads: long names are cut off at the end. It names the map
    // that has the update, which may not be the one on screen.
    final (icon, text) = switch (updates) {
      [final only] => (Icons.update_rounded, 'Map update ready: ${only.name}'),
      [_, _, ...] => (Icons.update_rounded, '${updates.length} map updates ready'),
      _ when streaming => switch (centerRegion) {
          final here? => (Icons.offline_pin_rounded, 'Offline map: ${here.name}'),
          null => (Icons.cloud_outlined, 'Streaming: not saved offline'),
        },
      _ when offline => (Icons.offline_pin_rounded, 'Offline map: ${r.name}'),
      _ => (Icons.public_rounded, 'Streaming: ${r.name}'),
    };
    return _Capsule(icon: icon, text: text, onTap: onTap);
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
