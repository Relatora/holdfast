import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../map/basemap_layer.dart';
import '../map/topo_background.dart';
import '../onboarding/onboarding_carousel.dart';
import '../onboarding/onboarding_gate.dart';
import '../regions/region_store.dart';
import '../regions/regions_screen.dart';
import '../settings/app_settings.dart';
import '../theme/motion.dart';
import '../theme/theme_toggle_button.dart';

/// The map screen: the active region's offline basemap, styled to match the
/// theme, with the welcome cards on first launch.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _map = MapController();
  late final RegionStore _regions = context.read<RegionStore>();
  String? _regionId;
  String? _basemapSource;

  @override
  void initState() {
    super.initState();
    _regions.addListener(_onRegionsChanged);
    // The store may have finished loading before this screen subscribed, in
    // which case no notification is coming; check its current state once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onRegionsChanged();
      _maybeShowOnboarding();
    });
  }

  @override
  void dispose() {
    _regions.removeListener(_onRegionsChanged);
    super.dispose();
  }

  Future<void> _onRegionsChanged() async {
    final active = _regions.activeRegion;
    if (active?.id == _regionId) return;
    _regionId = active?.id;
    if (active == null) {
      setState(() => _basemapSource = null);
      return;
    }
    final source = await _regions.basemapSource(active);
    if (!mounted || _regionId != active.id) return;
    setState(() => _basemapSource = source);
    _map.move(active.center, active.fitZoom + 1.5);
  }

  Future<void> _maybeShowOnboarding() async {
    final settings = context.read<AppSettings>();
    while (!_regions.loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted) return;
    final show = shouldShowOnboarding(
      dismissedForever: settings.onboardingDismissed,
      isFirstLaunch: settings.isFirstLaunch,
      downloadedRegions: _regions.readyRegions.length,
    );
    if (!show) return;
    final result = await showOnboarding(context);
    if (result == OnboardingResult.chooseMaps && mounted) _openRegions();
  }

  void _openRegions() =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegionsScreen()));

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final regions = context.watch<RegionStore>();
    final mode = resolveThemeMode(settings.themeMode, MediaQuery.platformBrightnessOf(context));
    final active = regions.activeRegion;

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: const LatLng(45.42, -75.69),
              initialZoom: 3,
              minZoom: 2,
              maxZoom: 19,
              backgroundColor: Theme.of(context).colorScheme.surface,
            ),
            children: [
              if (_basemapSource == null)
                TopoBackground(animate: Motion.enabled(context))
              else
                BasemapLayer(source: _basemapSource!, mode: mode),
            ],
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ThemeToggleButton(),
                    const SizedBox(height: 10),
                    FloatingActionButton.small(
                      heroTag: 'maps',
                      tooltip: 'Maps',
                      onPressed: _openRegions,
                      child: const Icon(Icons.layers_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (regions.loaded && active == null)
            Center(
              child: Card(
                margin: const EdgeInsets.all(24),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('No offline map yet'),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _openRegions, child: const Text('Choose a map')),
                    ],
                  ),
                ),
              ),
            ),
          // OpenStreetMap's licence requires visible attribution.
          if (active != null)
            Positioned(
              left: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 12,
              child: Chip(
                avatar: Icon(regions.files.storesOffline ? Icons.offline_pin_rounded : Icons.public_rounded),
                label: Text('${active.name} · © OpenStreetMap · Protomaps'),
              ),
            ),
        ],
      ),
    );
  }
}
