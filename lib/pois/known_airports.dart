import 'package:material_ui/material_ui.dart';

import 'poi.dart';

/// The airports on the active map, shared app-wide so a hazard's details
/// sheet can say which ones it is likely to close.
///
/// Bottom sheets open on the app's navigator, above the map screen, so they
/// can't see the map screen's own state; the map screen publishes its
/// airports here instead, and how to fly to one.
class KnownAirports extends ValueNotifier<List<Poi>> {
  KnownAirports() : super(const []);

  /// Shows an airport on the map (set by the map screen).
  void Function(Poi airport)? open;
}
