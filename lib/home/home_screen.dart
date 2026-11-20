import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../hazards/hazard_engine.dart';
import '../hazards/hazard_repository.dart';
import '../hazards/hazard_sheets.dart';
import '../map/basemap_layer.dart';
import '../map/hazard_marker.dart';
import '../map/poi_marker.dart';
import '../map/radar_sweep.dart';
import '../map/topo_background.dart';
import '../onboarding/onboarding_carousel.dart';
import '../onboarding/onboarding_gate.dart';
import '../pois/poi.dart';
import '../pois/poi_index.dart';
import '../pois/poi_sheets.dart';
import '../regions/region.dart';
import '../regions/my_maps_sheet.dart';
import '../regions/region_store.dart';
import '../regions/regions_screen.dart';
import '../routing/directions.dart';
import '../routing/directions_panel.dart';
import '../routing/router.dart';
import '../settings/app_settings.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme_mode.dart';
import '../theme/motion.dart';
import '../theme/theme_toggle_button.dart';
import 'map_overlays.dart';

/// The main screen: the offline map with supplies, hazards and controls.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final _map = MapController();
  late final RegionStore _regions = context.read<RegionStore>();

  /// Supply locations of the active region.
  PoiIndex _pois = PoiIndex.empty;
  String? _poisRegionId;
  String? _basemapSource;

  final Set<PoiCategory> _categories = {};
  List<Poi> _visiblePois = const [];
  String? _highlightedPoi;

  /// True for a moment after the pin set changes on purpose (new filter,
  /// radar results), so pins drop in. Panning never replays the drop.
  bool _dropping = false;
  Timer? _dropTimer;
  Timer? _viewportDebounce;
  bool _radarRunning = false;
  AnimationController? _flight;

  /// Above this zoom every place in view is shown; below it, only places in
  /// a selected category, so a zoomed-out map isn't buried in pins.
  static const _allPinsZoom = 13.5;
  static const _maxPins = 250;

  /// Directions: the panel's state and the route on the map.
  late final Directions _directions = Directions(
    loadPack: () async {
      final region = _regions.activeRegion;
      return region == null ? null : _regions.routingPack(region);
    },
    mapCenter: () => _map.camera.center,
  )..addListener(_onDirectionsChanged);
  RoutePlan? _shownPlan;
  late final HazardRepository _hazardRepo = context.read<HazardRepository>();

  @override
  void initState() {
    super.initState();
    _regions.addListener(_onRegionsChanged);
    // New or expired hazard reports change what a route should avoid.
    _hazardRepo.addListener(_onHazardsChanged);
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
    _hazardRepo.removeListener(_onHazardsChanged);
    _directions.dispose();
    _dropTimer?.cancel();
    _viewportDebounce?.cancel();
    _flight?.dispose();
    super.dispose();
  }

  // ---- Region & data loading -------------------------------------------------

  void _onRegionsChanged() {
    final active = _regions.activeRegion;
    if (active?.id == _poisRegionId) return;
    _poisRegionId = active?.id;
    if (active == null) {
      setState(() {
        _pois = PoiIndex.empty;
        _basemapSource = null;
        _visiblePois = const [];
      });
      return;
    }
    _loadRegion(active);
  }

  Future<void> _loadRegion(Region region) async {
    final source = await _regions.basemapSource(region);
    final raw = await _regions.poisJson(region);
    if (!mounted || _poisRegionId != region.id) return;
    final firstRegion = _basemapSource == null;
    setState(() {
      _basemapSource = source;
      _pois = raw == null ? PoiIndex.empty : PoiIndex.fromPack(jsonDecode(raw) as Map<String, Object?>);
    });
    // Fly between regions, but jump straight to the first one: flying in from
    // the zoomed-out world view requests (and cancels) tiles at every zoom on
    // the way, a burst that's all cost and no information.
    if (firstRegion) {
      _map.move(region.center, region.fitZoom + 1.5);
      _updateVisiblePois();
    } else {
      _flyTo(region.center, region.fitZoom + 1.5);
    }
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

  /// Opens the Maps screen. Tapping a downloaded map there returns it, and
  /// the map flies to it.
  Future<void> _openRegions() async {
    final chosen = await Navigator.of(context).push<Region>(MaterialPageRoute(builder: (_) => const RegionsScreen()));
    if (chosen != null && mounted) _goToRegion(chosen);
  }

  /// "My maps": the quick switcher behind the status chip.
  Future<void> _openMyMaps() async {
    switch (await showMyMaps(context)) {
      case GoToMap(:final region):
        _goToRegion(region);
      case ManageMaps():
        _openRegions();
      case null:
        break;
    }
  }

  /// Shows [region]: switching to it loads it and flies there
  /// ([_onRegionsChanged]); if it is already the active map, just fly back.
  Future<void> _goToRegion(Region region) async {
    if (_regions.activeRegion?.id != region.id) {
      await _regions.activate(region);
    } else {
      _flyTo(region.center, region.fitZoom + 1.5);
    }
  }

  void _openSettings() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SettingsScreen(
        mapCenter: () => _map.camera.center,
        onShowWelcome: () => showOnboarding(context).then((result) {
          if (result == OnboardingResult.chooseMaps && mounted) _openRegions();
        }),
      ),
    ),
  );

  // ---- Pins ------------------------------------------------------------------

  /// Picks which supply pins to draw for the current viewport.
  void _updateVisiblePois({bool drop = false}) {
    if (_pois.isEmpty) return;
    final camera = _map.camera;
    final bounds = camera.visibleBounds;
    final showAll = camera.zoom >= _allPinsZoom;
    final center = camera.center;
    final candidates = [
      for (final poi in _pois.pois)
        if ((_categories.isEmpty ? showAll : _categories.contains(poi.category)) &&
            bounds.contains(LatLng(poi.latitude, poi.longitude)))
          poi,
    ];
    // Closest to the centre first, so the cap trims the edges of the screen.
    candidates.sort(
      (a, b) => distanceMeters(
        center.latitude,
        center.longitude,
        a.latitude,
        a.longitude,
      ).compareTo(distanceMeters(center.latitude, center.longitude, b.latitude, b.longitude)),
    );
    setState(() {
      _visiblePois = candidates.take(_maxPins).toList();
      if (drop) _startDrop();
    });
  }

  void _startDrop() {
    _dropping = true;
    _dropTimer?.cancel();
    _dropTimer = Timer(const Duration(milliseconds: 900), () => setState(() => _dropping = false));
  }

  void _toggleCategory(PoiCategory category) {
    HapticFeedback.selectionClick();
    setState(() => _categories.contains(category) ? _categories.remove(category) : _categories.add(category));
    _updateVisiblePois(drop: true);
  }

  // ---- Camera ----------------------------------------------------------------

  /// Animated "fly to": eases position and zoom together and briefly zooms
  /// out mid-flight when the hop is long, like a camera pulling back to show
  /// where it's going.
  void _flyTo(LatLng target, double zoom, {Duration duration = const Duration(milliseconds: 1100)}) {
    if (!Motion.enabledNow(context)) {
      _map.move(target, zoom);
      _updateVisiblePois();
      return;
    }
    _flight?.dispose();
    final start = _map.camera;
    final controller = _flight = AnimationController(vsync: this, duration: duration);
    final distanceKm =
        distanceMeters(start.center.latitude, start.center.longitude, target.latitude, target.longitude) / 1000;
    final pullBack = (math.log(1 + distanceKm) / math.ln10 * 1.2).clamp(0.0, 3.0);
    final curve = CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic);
    controller
      ..addListener(() {
        final t = curve.value;
        final lat = start.center.latitude + (target.latitude - start.center.latitude) * t;
        final lng = start.center.longitude + (target.longitude - start.center.longitude) * t;
        final z = start.zoom + (zoom - start.zoom) * t - pullBack * math.sin(math.pi * t);
        _map.move(LatLng(lat, lng), z);
      })
      ..forward().whenComplete(() => _updateVisiblePois());
  }

  /// The on-screen zoom buttons. Pinch and the scroll wheel already zoom,
  /// but not every setup has them: a laptop trackpad driving an Android
  /// emulator, a desktop without a wheel, or a gloved hand on a phone.
  void _zoomBy(double delta) {
    final camera = _map.camera;
    // Quick taps add up: while a zoom is still animating, step from where
    // it is heading rather than from wherever the camera is mid-flight.
    final zooming = _flight != null && identical(_flight, _zoomFlight) && _flight!.isAnimating;
    final zoom = ((zooming ? _zoomTarget : camera.zoom)! + delta).clamp(2.0, 19.0);
    _flyTo(camera.center, zoom, duration: const Duration(milliseconds: 250));
    _zoomTarget = zoom;
    _zoomFlight = _flight;
  }

  /// Where the last zoom-button animation ([_zoomFlight]) is heading.
  double? _zoomTarget;
  AnimationController? _zoomFlight;

  // ---- Actions ---------------------------------------------------------------

  void _runRadar() {
    if (_radarRunning) return;
    HapticFeedback.mediumImpact();
    if (!Motion.enabledNow(context)) {
      _showNearest();
      return;
    }
    setState(() => _radarRunning = true);
  }

  Future<void> _showNearest() async {
    setState(() => _radarRunning = false);
    final center = _map.camera.center;
    final hits = _categories.isEmpty
        ? _pois.nearestPerCategory(center.latitude, center.longitude)
        : _pois.nearest(center.latitude, center.longitude, categories: _categories);
    final chosen = await showNearestSheet(context, hits);
    if (chosen != null && mounted) _focusPoi(chosen);
  }

  void _focusPoi(Poi poi) {
    // Remember the view before flying to the place: it is where a route
    // starts when the device has no location of its own.
    final viewBefore = _map.camera.center;
    setState(() => _highlightedPoi = poi.id);
    _flyTo(LatLng(poi.latitude, poi.longitude), math.max(_map.camera.zoom, 15));
    final center = _map.camera.center;
    showPlaceSheet(
      context,
      poi,
      meters: distanceMeters(center.latitude, center.longitude, poi.latitude, poi.longitude),
      onDirections: () => _openDirections(LatLng(poi.latitude, poi.longitude), poi.title, viewCenter: viewBefore),
    ).whenComplete(() {
      if (mounted) setState(() => _highlightedPoi = null);
    });
    // Make sure the focused place is drawn even if its category is hidden.
    if (!_visiblePois.contains(poi)) setState(() => _visiblePois = [..._visiblePois, poi]);
  }

  // ---- Directions ------------------------------------------------------------

  /// Hazards currently shown on the map, as areas a route should avoid.
  List<Avoid> _avoidNow() {
    final showUnverified = context.read<AppSettings>().showUnverifiedHazards;
    return avoidAreas([
      for (final h in _hazardRepo.hazards)
        if (isVisible(_hazardRepo.assess(h), showUnverified: showUnverified)) h,
    ]);
  }

  void _openDirections(LatLng to, String label, {LatLng? viewCenter}) {
    final region = _regions.activeRegion;
    if (region == null) return;
    _directions.open(to: to, label: label, regionId: region.id, avoid: _avoidNow(), viewCenter: viewCenter);
  }

  void _onHazardsChanged() => _directions.updateAvoid(_avoidNow());

  /// Rebuilds, and frames a newly planned route so the whole of it shows
  /// above the panel.
  void _onDirectionsChanged() {
    if (!mounted) return;
    setState(() {});
    final plan = _directions.plan;
    if (plan == null || identical(plan, _shownPlan)) return;
    _shownPlan = plan;
    final points = [for (final leg in plan.legs) ...leg.points];
    if (points.length < 2) return;
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: EdgeInsets.fromLTRB(40, 150, 70, MediaQuery.sizeOf(context).height * 0.55),
        maxZoom: 17,
      ),
    );
    _updateVisiblePois();
  }

  /// Long-press on the map: plan a route to the spot, or report a hazard.
  Future<void> _onLongPress(LatLng point) async {
    HapticFeedback.heavyImpact();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.directions_rounded),
              title: const Text('Directions to here'),
              onTap: () => Navigator.pop(context, 'directions'),
            ),
            ListTile(
              leading: const Icon(Icons.add_alert_rounded),
              title: const Text('Report a hazard here'),
              onTap: () => Navigator.pop(context, 'hazard'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'directions':
        _openDirections(point, 'the marked spot');
      case 'hazard':
        showReportHazardSheet(context, latitude: point.latitude, longitude: point.longitude);
    }
  }

  // ---- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final regions = context.watch<RegionStore>();
    final hazardsRepo = context.watch<HazardRepository>();
    final scheme = Theme.of(context).colorScheme;
    final mode = resolveThemeMode(settings.themeMode, MediaQuery.platformBrightnessOf(context));
    final nightVision = mode == AppThemeMode.nightVision;
    final animate = Motion.enabled(context);
    final active = regions.activeRegion;

    final hazards = [
      for (final hazard in hazardsRepo.hazards)
        if (isVisible(hazardsRepo.assess(hazard), showUnverified: settings.showUnverifiedHazards))
          (hazard: hazard, assessment: hazardsRepo.assess(hazard)),
    ];

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: const LatLng(45.42, -75.69),
              initialZoom: 3,
              minZoom: 2,
              maxZoom: BasemapLayer.maxMapZoom,
              backgroundColor: scheme.surface,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onPositionChanged: (_, hasGesture) {
                _viewportDebounce?.cancel();
                _viewportDebounce = Timer(const Duration(milliseconds: 120), _updateVisiblePois);
              },
              onLongPress: (_, point) => _onLongPress(point),
            ),
            children: [
              if (_basemapSource == null)
                TopoBackground(animate: animate)
              else
                BasemapLayer(source: _basemapSource!, mode: mode),
              if (_directions.plan case final plan?) ...routeLayers(plan, scheme),
              MarkerLayer(
                markers: [
                  for (final (i, poi) in _visiblePois.indexed)
                    Marker(
                      key: ValueKey(poi.id),
                      point: LatLng(poi.latitude, poi.longitude),
                      width: PoiMarker.width,
                      height: PoiMarker.height,
                      alignment: Alignment.topCenter,
                      child: GestureDetector(
                        onTap: () => _focusPoi(poi),
                        child: PoiMarker(
                          poi: poi,
                          animate: animate && _dropping,
                          highlighted: poi.id == _highlightedPoi,
                          dropDelay: Duration(milliseconds: math.min(i, 30) * 18),
                          nightVision: nightVision,
                        ),
                      ),
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  for (final (:hazard, :assessment) in hazards)
                    Marker(
                      key: ValueKey(hazard.id),
                      point: LatLng(hazard.latitude, hazard.longitude),
                      width: HazardMarker.size,
                      height: HazardMarker.size,
                      child: Center(
                        child: GestureDetector(
                          onTap: () => showHazardDetailsSheet(context, hazard.id),
                          child: HazardMarker(
                            hazard: hazard,
                            assessment: assessment,
                            animate: animate,
                            nightVision: nightVision,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),

          if (_radarRunning)
            Positioned.fill(
              child: RadarSweep(color: scheme.primary, onDone: _showNearest),
            ),

          // Top: search and category filters.
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: PlaceSearchBar(index: _pois, onSelected: _focusPoi, onOpenSettings: _openSettings),
                ),
                const SizedBox(height: 8),
                CategoryChips(
                  selected: _categories,
                  onToggle: _toggleCategory,
                  animate: animate,
                  nightVision: nightVision,
                ),
              ],
            ),
          ),

          // Right: map tools.
          Positioned(
            right: 12,
            top: MediaQuery.paddingOf(context).top + 130,
            child: Column(
              children: [
                const ThemeToggleButton(),
                const SizedBox(height: 10),
                FloatingActionButton.small(
                  heroTag: 'maps',
                  tooltip: 'Maps',
                  onPressed: _openRegions,
                  child: const Icon(Icons.layers_rounded),
                ),
                const SizedBox(height: 10),
                ZoomButtons(onZoomIn: () => _zoomBy(1), onZoomOut: () => _zoomBy(-1)),
              ],
            ),
          ),

          // Bottom: the directions panel while it's open...
          if (_directions.isOpen)
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 12,
              child: Center(
                child: DirectionsPanel(
                  directions: _directions,
                  onStepTap: (step) => _flyTo(step.at, math.max(_map.camera.zoom, 16)),
                ),
              ),
            )
          // ...otherwise status, attribution and the main actions.
          else
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 12,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SyncStatusChip(status: hazardsRepo.syncStatus),
                        const SizedBox(height: 6),
                        RegionStatusChip(
                          region: active,
                          offline: regions.files.storesOffline,
                          onTap: _openMyMaps,
                        ),
                        const SizedBox(height: 6),
                        const AttributionChip(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'report',
                        tooltip: 'Report a hazard here (or long-press the map)',
                        backgroundColor: scheme.errorContainer,
                        foregroundColor: scheme.onErrorContainer,
                        onPressed: () {
                          final c = _map.camera.center;
                          showReportHazardSheet(context, latitude: c.latitude, longitude: c.longitude);
                        },
                        child: const Icon(Icons.add_alert_rounded),
                      ),
                      const SizedBox(height: 10),
                      FloatingActionButton.extended(
                        heroTag: 'nearest',
                        onPressed: _pois.isEmpty ? _openRegions : _runRadar,
                        icon: Icon(_pois.isEmpty ? Icons.download_rounded : Icons.radar_rounded),
                        label: Text(_pois.isEmpty ? 'Get a map' : 'Nearest supplies'),
                      ),
                    ],
                  ),
                ],
              ),
            ),

          if (regions.loaded && active == null) Center(child: NoMapCard(onChoose: _openRegions)),
        ],
      ),
    );
  }
}
