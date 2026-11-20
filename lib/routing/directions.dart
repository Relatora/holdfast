/// State for the directions panel: where to, how, from where, and the
/// resulting route.
library;


import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../hazards/effects/nuclear_effects.dart';
import '../hazards/effects/spread.dart';
import '../hazards/hazard.dart';
import '../hazards/hazard_details.dart';
import 'router.dart';
import 'routing_graph.dart';

/// How far around a hazard a route should stay, by type. Floods, fires and
/// chemical spills cover an area; a downed line or a collapse blocks a
/// street. Contaminated water doesn't affect travel at all.
///
/// The nuclear and radiation figures are a floor: once effect rings and
/// wind plumes exist for a report, those shapes are avoided as well.
double avoidRadiusMeters(HazardType type) => switch (type) {
      HazardType.nuclearDetonation => 5000,
      HazardType.volcanicAsh => 2000,
      HazardType.tsunami => 1500,
      HazardType.radiation => 1000,
      HazardType.fire || HazardType.chemicalSpill || HazardType.lava => 500,
      HazardType.flood || HazardType.gasLeak => 300,
      HazardType.unrest => 250,
      HazardType.police || HazardType.other => 100,
      HazardType.powerLines || HazardType.structuralCollapse => 60,
      HazardType.roadBlocked || HazardType.peopleHurt => 40,
      HazardType.contaminatedWater => 0,
    };

List<Avoid> avoidAreas(Iterable<Hazard> hazards) => [
      for (final h in hazards) ...[
        if (_radiusFor(h) > 0) Avoid(LatLng(h.latitude, h.longitude), _radiusFor(h)),
        // Where smoke, gas, ash or fallout is likely to be within 3 hours.
        for (final c in plumeCircles(h)) Avoid(c.center, c.radius),
      ],
    ];

/// A nuclear detonation with a known yield is avoided out to the furthest
/// of its 5 psi (collapsed buildings, blocked roads), burn and radiation
/// rings, rather than the type's fixed floor.
double _radiusFor(Hazard hazard) {
  final nuclear = hazard.nuclear;
  if (nuclear == null) return avoidRadiusMeters(hazard.type);
  final reach = nuclearEffects(nuclear)
      .where((r) => r.kind != RingKind.lightBlast)
      .fold(0.0, (m, r) => math.max(m, r.radiusMeters));
  return math.max(reach, avoidRadiusMeters(hazard.type));
}

/// The device's position, or null when it has none or may not share it.
///
/// GPS works with no network at all, which is the point; but a desktop
/// without a location service, or a refused permission, is normal and
/// simply means routes start from the middle of the map instead.
Future<LatLng?> currentLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 8)),
    );
    return LatLng(position.latitude, position.longitude);
  } catch (_) {
    return null;
  }
}

RoutingGraph _decode(Uint8List bytes) => RoutingGraph.decode(bytes);

class Directions extends ChangeNotifier {
  Directions({
    required this.loadPack,
    required this.mapCenter,
    this.locate = currentLocation,
  });

  /// Loads the active region's routing pack (null when it has none).
  final Future<Uint8List?> Function() loadPack;

  /// The middle of the map right now: the fallback start point.
  final LatLng Function() mapCenter;
  final Future<LatLng?> Function() locate;

  Router? _router;
  String? _routerRegion;

  LatLng? destination;
  String destinationLabel = '';
  TravelMode mode = TravelMode.walk;

  LatLng? origin;

  /// True when [origin] is the device's position rather than the map centre.
  bool fromMyLocation = false;
  LatLng? _myLocation;

  /// Where the map was centred when directions were asked for. Opening a
  /// place flies the map to it, so "the map centre" afterwards would be the
  /// destination itself; the caller passes the view from before the flight.
  LatLng? _viewCenter;

  RoutePlan? plan;
  String? error;

  /// Something worth knowing that isn't an error, e.g. why the route starts
  /// from the map view instead of the device's position.
  String? notice;
  bool busy = false;

  List<Avoid> _avoid = const [];

  bool get isOpen => destination != null;

  /// Opens directions to [to]. [regionId] keys the cached router, so the
  /// pack is only decoded again after switching maps.
  Future<void> open({
    required LatLng to,
    required String label,
    required String regionId,
    required List<Avoid> avoid,
    LatLng? viewCenter,
  }) async {
    destination = to;
    _viewCenter = viewCenter;
    destinationLabel = label;
    _avoid = avoid;
    plan = null;
    error = null;
    busy = true;
    notifyListeners();

    if (_routerRegion != regionId) {
      _router = null;
      final bytes = await loadPack();
      if (bytes != null) {
        try {
          // Decoding a city's 7 MB pack takes a moment: keep it off the UI
          // thread where the platform allows.
          _router = Router(await compute(_decode, bytes));
          _routerRegion = regionId;
        } on RoutingFormatException catch (e) {
          error = 'This map\'s directions data could not be read (${e.message}).';
        }
      }
    }
    if (_router == null) {
      busy = false;
      error ??= 'Directions aren\'t available for this map yet. They are built for city maps; '
          'download a city to get them.';
      notifyListeners();
      return;
    }

    _myLocation ??= await locate();
    notice = null;
    final here = _myLocation;
    if (here != null && !_router!.covers(here)) {
      // A real position, but outside this map: starting there can only
      // fail, so start from the map view and say why.
      fromMyLocation = false;
      notice = 'You are outside this map, so the route starts from the map view.';
    } else {
      fromMyLocation = here != null;
    }
    origin = fromMyLocation ? here : (_viewCenter ?? mapCenter());
    _replan();
  }

  void setMode(TravelMode value) {
    if (mode == value) return;
    mode = value;
    _replan();
  }

  /// Switches the start between the device's position and the map centre.
  Future<void> useMyLocation(bool value) async {
    notice = null;
    if (value) {
      _myLocation = await locate();
      final here = _myLocation;
      if (here == null) {
        notice = 'This device isn\'t sharing a location, so the route starts from the map view.';
        notifyListeners();
        return;
      }
      if (_router != null && !_router!.covers(here)) {
        notice = 'You are outside this map, so the route starts from the map view.';
        notifyListeners();
        return;
      }
    }
    fromMyLocation = value;
    origin = value ? _myLocation : (_viewCenter ?? mapCenter());
    _replan();
  }

  /// New hazard reports arrived: plan again around them.
  void updateAvoid(List<Avoid> avoid) {
    if (!isOpen) return;
    _avoid = avoid;
    _replan();
  }

  void close() {
    destination = null;
    plan = null;
    error = null;
    notice = null;
    busy = false;
    notifyListeners();
  }

  void _replan() {
    final router = _router, from = origin, to = destination;
    if (router == null || from == null || to == null) return;
    try {
      plan = router.plan(from, to, mode, avoid: _avoid);
      error = null;
    } on NoRouteException catch (e) {
      plan = null;
      error = e.message;
    }
    busy = false;
    notifyListeners();
  }
}
