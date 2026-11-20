import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'region.dart';
import 'region_store.dart';

/// What the user picked in [showMyMaps].
sealed class MyMapsChoice {
  const MyMapsChoice();
}

/// Go to this downloaded map (switching to it first if needed).
class GoToMap extends MyMapsChoice {
  const GoToMap(this.region);
  final Region region;
}

/// Open the full Maps screen to download or delete maps.
class ManageMaps extends MyMapsChoice {
  const ManageMaps();
}

/// The quick switcher behind the map's status chip: every downloaded map,
/// the one on screen first, one tap to go there.
Future<MyMapsChoice?> showMyMaps(BuildContext context) => showModalBottomSheet<MyMapsChoice>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _MyMapsSheet(),
    );

class _MyMapsSheet extends StatelessWidget {
  const _MyMapsSheet();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RegionStore>();
    final theme = Theme.of(context);
    final maps = [for (final r in store.deviceRegions) if (store.stateOf(r).phase == RegionPhase.ready) r];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('My maps', style: theme.textTheme.titleLarge),
            ),
            if (maps.isEmpty)
              const ListTile(
                leading: Icon(Icons.download_for_offline_outlined),
                title: Text('No maps on this device yet'),
                subtitle: Text('Download one to use it offline.'),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final region in maps)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.15),
                        foregroundColor: theme.colorScheme.primary,
                        child: Icon(regionLevelIcon(region.level)),
                      ),
                      title: Text(region.name),
                      subtitle: Text([
                        if (store.activeRegion?.id == region.id) 'On the map now',
                        formatBytes(store.sizeOf(region)),
                      ].join(' · ')),
                      trailing: const Icon(Icons.near_me_rounded),
                      onTap: () => Navigator.pop(context, GoToMap(region)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: TextButton.icon(
                onPressed: () => Navigator.pop(context, const ManageMaps()),
                icon: const Icon(Icons.layers_rounded),
                label: const Text('Download or manage maps'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One icon per region size, shared by every list of regions.
IconData regionLevelIcon(RegionLevel level) => switch (level) {
      RegionLevel.city => Icons.location_city_rounded,
      RegionLevel.province => Icons.terrain_rounded,
      RegionLevel.country => Icons.flag_rounded,
      RegionLevel.continent => Icons.public_rounded,
      RegionLevel.world => Icons.language_rounded,
    };
