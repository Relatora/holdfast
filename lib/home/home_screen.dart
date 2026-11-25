import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../contamination/interpolation.dart';
import '../contamination/sample.dart';
import '../contamination/sample_layer.dart';
import '../contamination/sample_sheet.dart';
import '../hazards/effects/nuclear_view.dart';
import '../hazards/effects/spread_view.dart';
import '../hazards/hazard.dart' show HazardCategory;
import '../hazards/hazard_engine.dart';
import '../hazards/hazard_filter.dart';
import '../hazards/hazard_repository.dart';
import '../hazards/hazard_sheets.dart';
import '../hazards/hazards_sheet.dart';
import '../location/locate_flow.dart';
import '../location/locator.dart';
import '../reputation/achievement_badge.dart';
import '../reputation/achievements.dart';
import '../reputation/my_reporting_screen.dart';
import '../map/basemap_layer.dart';
import '../map/hazard_marker.dart';
import '../map/location_layer.dart';
import '../map/poi_marker.dart';
import '../map/radar_sweep.dart';
import '../map/saved_area_layers.dart';
import '../map/topo_background.dart';
import '../net/network_gate.dart';
import '../notify/notifications.dart';
import '../onboarding/onboarding_carousel.dart';
import '../onboarding/onboarding_gate.dart';
import '../pois/poi.dart';
import '../pois/poi_index.dart';
import '../pois/poi_sheets.dart';
import '../regions/region.dart';
import '../regions/my_maps_sheet.dart';
import '../regions/region_files.dart' show SidePack;
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
import '../training/training_hooks.dart';
import 'map_overlays.dart';

/// The main screen: the offline map with supplies, hazards and controls.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.training = false});

  /// Running inside a training scenario: no welcome cards. Everything else
  /// is the real screen, fed by a sandbox hazard repository.
  final bool training;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final _map = MapController();
  late final RegionStore _regions = context.read<RegionStore>();

  /// Supply locations of the active region.
  PoiIndex _pois = PoiIndex.empty;

  /// [RegionStore.dataKey] of the region whose data is loaded: it changes
  /// when the active map switches *or* is updated, and either way its
  /// places are read again.
  String? _loadedKey;
  bool _shownFirstRegion = false;

  /// Every downloaded map's basemap, the one on screen first, and the data
  /// keys they were read for. The map draws all of them, so moving past
  /// the edge of one downloaded region shows the next.
  List<String> _localSources = const [];
  String? _sourcesKey;

  /// Place packs of regions other than the active one, loaded as they come
  /// into view: downloaded ones from the device, and (online, streaming)
  /// hosted cities from the server, whose pins get a cloud badge.
  final Map<String, ({Region region, PoiIndex index, bool streamed})> _otherPacks = {};
  final Set<String> _requestedPacks = {};

  /// Streamed packs are only fetched this close in: a city's places, not a
  /// continent's worth of requests while flying over it.
  static const _streamPlacesZoom = 11.0;

  /// The downloaded region under the centre of the map, if any.
  Region? _centerRegion;

  /// The camera's zoom when the pins were last picked.
  double _zoom = 3;

  final Set<PoiCategory> _categories = {};
  List<Poi> _visiblePois = const [];

  /// Ids in [_visiblePois] that came from the server, not this device.
  Set<String> _streamedPois = const {};
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
      return region == null ? null : _regions.sidePack(region, SidePack.routing);
    },
    mapCenter: () => _map.camera.center,
    // Start from the dot on the map when there is a fresh one; otherwise
    // try GPS quietly (no sheet: the panel falls back to the map centre).
    locate: () async {
      if (_locator.recent() case final fix?) return fix.at;
      return switch (await _locator.gps()) {
        Located(:final fix) => fix.at,
        LocateFailed() => null,
      };
    },
  )..addListener(_onDirectionsChanged);

  /// Finds the device for the location button, the dot and directions.
  /// Shared through the app when provided; tests get a private one.
  late final DeviceLocator _locator = context.read<DeviceLocator?>() ?? DeviceLocator();
  RoutePlan? _shownPlan;
  late final HazardRepository _hazardRepo = context.read<HazardRepository>();

  @override
  void initState() {
    super.initState();
    _regions.addListener(_onRegionsChanged);
    // New or expired hazard reports change what a route should avoid.
    _hazardRepo.addListener(_onHazardsChanged);
    _hazardRepo.thanks.addListener(_onThanks);
    _locator.addListener(_onLocatorChanged);
    // The store may have finished loading before this screen subscribed, in
    // which case no notification is coming; check its current state once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onRegionsChanged();
      if (!widget.training) _maybeShowOnboarding();
    });
  }

  @override
  void dispose() {
    _regions.removeListener(_onRegionsChanged);
    _hazardRepo.removeListener(_onHazardsChanged);
    _hazardRepo.thanks.removeListener(_onThanks);
    _locator.removeListener(_onLocatorChanged);
    _directions.dispose();
    _dropTimer?.cancel();
    _viewportDebounce?.cancel();
    _flight?.dispose();
    super.dispose();
  }

  // ---- Region & data loading -------------------------------------------------

  void _onRegionsChanged() {
    _loadSources();
    final active = _regions.activeRegion;
    final key = active == null ? null : _regions.dataKey(active);
    if (key == _loadedKey) return;
    final sameRegion = active != null && _loadedKey?.startsWith('${active.id}#') == true;
    _loadedKey = key;
    // The other packs may include the new active region, or an old build.
    _otherPacks.clear();
    _requestedPacks.clear();
    if (active == null) {
      setState(() {
        _pois = PoiIndex.empty;
        _visiblePois = const [];
      });
      return;
    }
    _loadRegion(active, key: key!, moveCamera: !sameRegion);
  }

  /// Maps on this device whose basemap the map can draw.
  List<Region> get _downloaded => [
        for (final r in _regions.deviceRegions)
          if (_regions.stateOf(r).phase case RegionPhase.ready || RegionPhase.updating) r,
      ];

  /// Opens the basemaps of every downloaded map, the one on screen first, and
  /// again whenever one is added, removed or updated.
  Future<void> _loadSources() async {
    final maps = _downloaded;
    final key = maps.map(_regions.dataKey).join(',');
    if (key == _sourcesKey) return;
    _sourcesKey = key;
    final sources = [for (final r in maps) await _regions.basemapSource(r)];
    if (!mounted || _sourcesKey != key) return;
    setState(() => _localSources = sources);
  }

  /// Online, with the setting on and a planet build to stream from.
  bool _streaming(AppSettings settings, NetworkGate? network) =>
      (network?.online ?? true) && settings.streamWorld && _regions.streamUrl != null;

  /// Loads [region]'s places. After an update of the map on screen
  /// ([moveCamera] false) the view stays where it is.
  Future<void> _loadRegion(Region region, {required String key, bool moveCamera = true}) async {
    final raw = await _regions.poisJson(region);
    if (!mounted || _loadedKey != key) return;
    final firstRegion = !_shownFirstRegion;
    _shownFirstRegion = true;
    setState(() {
      _pois = raw == null ? PoiIndex.empty : PoiIndex.fromPack(jsonDecode(raw) as Map<String, Object?>);
    });
    if (!moveCamera) {
      _updateVisiblePois();
      return;
    }
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

  /// Picks which supply pins to draw for the current viewport, and notes
  /// which downloaded region the map is centred on.
  void _updateVisiblePois({bool drop = false}) {
    final camera = _map.camera;
    final bounds = camera.visibleBounds;
    final center = camera.center;
    _centerRegion = _downloadedRegionAt(center);
    _zoom = camera.zoom;
    _loadPacksInView(bounds, camera.zoom);

    final streaming = _streaming(context.read<AppSettings>(), context.read<NetworkGate?>());
    final showAll = camera.zoom >= _allPinsZoom;
    final seen = <String>{};
    final streamed = <String>{};
    final candidates = <Poi>[];
    // The active map's places first: where regions overlap (a city inside a
    // province), the same place is listed once, from the closest match.
    for (final (index, fromServer) in [
      (_pois, false),
      for (final pack in _otherPacks.values)
        // Streamed places go away with the stream (offline mode).
        if (_overlaps(pack.region, bounds) && (streaming || !pack.streamed)) (pack.index, pack.streamed),
    ]) {
      for (final poi in index.pois) {
        if ((_categories.isEmpty ? showAll : _categories.contains(poi.category)) &&
            bounds.contains(LatLng(poi.latitude, poi.longitude)) &&
            seen.add(poi.id)) {
          candidates.add(poi);
          if (fromServer) streamed.add(poi.id);
        }
      }
    }
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
      _streamedPois = streamed;
      if (drop) _startDrop();
    });
  }

  static bool _overlaps(Region r, LatLngBounds b) =>
      r.west <= b.east && r.east >= b.west && r.south <= b.north && r.north >= b.south;

  /// The smallest downloaded region containing [point]: in Ottawa, inside
  /// Ontario, that's Ottawa.
  Region? _downloadedRegionAt(LatLng point) {
    Region? best;
    for (final r in _downloaded) {
      if (r.contains(point.latitude, point.longitude) && (best == null || r.approxBytes < best.approxBytes)) best = r;
    }
    return best;
  }

  /// Starts loading the place packs of regions in view that aren't loaded:
  /// other downloaded maps from the device and, when streaming and close
  /// enough in, hosted cities from the server.
  void _loadPacksInView(LatLngBounds bounds, double zoom) {
    final active = _regions.activeRegion?.id;
    final streaming = _streaming(context.read<AppSettings>(), context.read<NetworkGate?>());
    final downloaded = {for (final r in _downloaded) r.id};
    for (final region in _regions.regions) {
      if (region.id == active || _requestedPacks.contains(region.id) || !_overlaps(region, bounds)) continue;
      final local = downloaded.contains(region.id);
      final stream = !local &&
          streaming &&
          zoom >= _streamPlacesZoom &&
          region.level == RegionLevel.city &&
          _regions.isHosted(region);
      if (!local && !stream) continue;
      _requestedPacks.add(region.id);
      _regions.poisJson(region).then((raw) {
        if (!mounted || raw == null || !_requestedPacks.contains(region.id)) return;
        final index = PoiIndex.fromPack(jsonDecode(raw) as Map<String, Object?>);
        _otherPacks[region.id] = (region: region, index: index, streamed: !local);
        _updateVisiblePois();
      });
    }
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

  void _onLocatorChanged() {
    if (mounted) setState(() {});
  }

  /// The location button: find the device (asking for whatever is needed
  /// on the way) and fly there, close enough to see the whole error circle.
  Future<void> _goToMyLocation() async {
    if (_locator.busy) return;
    final fix = await locateMe(context, _locator);
    if (fix == null || !mounted) return;
    TrainingHooks.report(const FoundMyLocation());
    // A GPS fix: street level. A rough one: wide enough to show its circle
    // (about 16 at 100 m, one zoom level out per doubling).
    final fitZoom = (16 - math.log(math.max(fix.accuracyMeters, 100) / 100) / math.ln2).clamp(9.0, 17.0);
    _flyTo(fix.at, fix.approximate ? fitZoom : math.max(_map.camera.zoom, math.min(fitZoom, 16.5)));
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
    TrainingHooks.report(OpenedPlace(poi.category));
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

  // ---- Hazards ---------------------------------------------------------------

  /// Someone confirmed one of our reports: say thank you, with the badge of
  /// the rank it helps build.
  void _onThanks() {
    final thanks = _hazardRepo.thanks.value;
    if (thanks == null || !mounted) return;
    final tier = Tier.of(_hazardRepo.myRecord);
    final people = thanks.confirmations == 1 ? 'Someone' : '${thanks.confirmations} people';
    // In front, the snackbar below says it; otherwise the system does.
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      context.read<Notifications?>()?.show(
            NoticeKind.thanks,
            title: '$people confirmed your ${thanks.hazard.type.label.toLowerCase()} report',
            body: 'Thank you for reporting. Your reports now count ${thanks.multiplier.toStringAsFixed(1)}×.',
          );
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 6),
      content: Row(
        children: [
          AchievementBadge(icon: tier.icon, color: tier.color, size: 36, celebrate: true, animate: Motion.enabledNow(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$people confirmed your ${thanks.hazard.type.label.toLowerCase()} report. Thank you! '
              'Your reports now count ${thanks.multiplier.toStringAsFixed(1)}×.',
            ),
          ),
        ],
      ),
      action: SnackBarAction(
        label: 'See',
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyReportingScreen())),
      ),
    ));
  }

  Future<void> _openHazards() async {
    final hazard = await showHazardsSheet(context, from: _map.camera.center);
    if (hazard == null || !mounted) return;
    _flyTo(LatLng(hazard.latitude, hazard.longitude), math.max(_map.camera.zoom, 14));
    showHazardDetailsSheet(context, hazard.id);
  }

  // ---- Directions ------------------------------------------------------------

  /// Hazards currently shown on the map, as areas a route should avoid.
  List<Avoid> _avoidNow() {
    final showUnverified = context.read<AppSettings>().showUnverifiedHazards || _hazardRepo.isSandbox;
    final samples = _hazardRepo.liveSamples;
    return [
      ...avoidAreas([
        for (final h in _hazardRepo.hazards)
          if (isVisible(_hazardRepo.assess(h), showUnverified: showUnverified)) h,
      ]),
      // Very high and dangerous ground from soil readings, too.
      ...sampleAvoidAreas(samples, _zonesFor(samples)),
    ];
  }

  /// Estimated zones, recomputed only when the readings change: the grid
  /// is cheap, but not cheap enough for every frame of a pan.
  List<EstimatedZone> _zonesFor(List<Sample> samples) {
    final key = [for (final s in samples) '${s.id}:${s.value}'].join('|');
    if (key != _zonesKey) {
      _zonesKey = key;
      _zones = estimateZones(samples);
    }
    return _zones;
  }

  String? _zonesKey;
  List<EstimatedZone> _zones = const [];

  void _openDirections(LatLng to, String label, {LatLng? viewCenter}) {
    final region = _regions.activeRegion;
    if (region == null) return;
    _directions.open(
      to: to,
      label: label,
      // The data key, not the id: after an update the new routing pack loads.
      regionId: _regions.dataKey(region),
      avoid: _avoidNow(),
      viewCenter: viewCenter,
    );
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
    TrainingHooks.report(PlannedRoute(plan));
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
            ListTile(
              leading: const Icon(Icons.science_rounded),
              title: const Text('Add a soil or radiation reading here'),
              onTap: () => Navigator.pop(context, 'sample'),
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
      case 'sample':
        showAddSampleSheet(context, latitude: point.latitude, longitude: point.longitude);
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
    final streaming = _streaming(settings, context.watch<NetworkGate?>());
    final planet = streaming ? regions.streamUrl : null;

    final shownCategories = settings.hazardCategories;
    final hazards = [
      for (final hazard in hazardsRepo.hazards)
        if (isVisible(hazardsRepo.assess(hazard), showUnverified: settings.showUnverifiedHazards || hazardsRepo.isSandbox) &&
            passesFilter(hazard, shownCategories))
          (hazard: hazard, assessment: hazardsRepo.assess(hazard)),
    ];
    // Readings belong to the chemical & radiological category's filter.
    final samples = shownCategories.isEmpty || shownCategories.contains(HazardCategory.chemical)
        ? hazardsRepo.liveSamples
        : const <Sample>[];
    final zones = _zonesFor(samples);

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
              if (_localSources.isEmpty && planet == null)
                TopoBackground(animate: animate)
              else
                BasemapLayer(local: _localSources, remote: planet, revision: _sourcesKey, mode: mode),
              // Streaming blurs where the device's maps end, so draw it.
              if (streaming) ...savedAreaLayers(_downloaded, scheme, zoom: _zoom),
              ...sampleZoneLayers(zones, onTapLabel: (_) => _openHazards()),
              spreadLayer([for (final h in hazards) h.hazard]),
              nuclearRingsLayer([for (final h in hazards) h.hazard], settings.nuclearView),
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
                          streamed: _streamedPois.contains(poi.id),
                        ),
                      ),
                    ),
                ],
              ),
              sampleDotLayer(
                samples,
                disputed: (s) => hazardsRepo.assessSampleNow(s) == SampleStatus.disputed,
                onTap: (s) => showSampleDetailsSheet(context, s.id),
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
              // Last, so your own position is never hidden under a pin.
              ...locationLayers(_locator.last, scheme),
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
                FloatingActionButton.small(
                  heroTag: 'hazards',
                  tooltip: shownCategories.isEmpty ? 'Hazards' : 'Hazards (filtered)',
                  onPressed: _openHazards,
                  child: Badge(
                    // A dot when the map is filtered, so hidden hazards are
                    // never a surprise; otherwise the count on the map.
                    isLabelVisible: hazards.isNotEmpty || shownCategories.isNotEmpty,
                    label: shownCategories.isEmpty ? Text('${hazards.length}') : null,
                    smallSize: 9,
                    child: const Icon(Icons.warning_amber_rounded),
                  ),
                ),
                const SizedBox(height: 10),
                ZoomButtons(onZoomIn: () => _zoomBy(1), onZoomOut: () => _zoomBy(-1)),
                const SizedBox(height: 10),
                MyLocationButton(
                  busy: _locator.busy,
                  located: _locator.last != null,
                  onPressed: _goToMyLocation,
                ),
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
                          updates: regions.updatable,
                          streaming: streaming,
                          centerRegion: _centerRegion,
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

          // While streaming, the world is on screen already; the Get a map
          // button below still offers a download.
          if (regions.loaded && active == null && !streaming) Center(child: NoMapCard(onChoose: _openRegions)),
        ],
      ),
    );
  }
}
