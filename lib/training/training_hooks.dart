/// How the map tells a running training scenario what the player just did.
///
/// The map, the place sheet and the directions panel don't know training
/// exists; they report actions here, and nothing listens unless a scenario
/// is running. A static hook keeps those screens free of training code
/// paths; it costs one null check per action when no scenario runs.
library;

import 'dart:async';

import '../contamination/contaminants.dart';
import '../hazards/hazard.dart';
import '../pois/poi.dart';
import '../routing/router.dart';

sealed class TrainingAction {
  const TrainingAction();
}

class ReportedHazard extends TrainingAction {
  const ReportedHazard(this.type);
  final HazardType type;
}

class VotedOnHazard extends TrainingAction {
  const VotedOnHazard(this.type, this.kind);
  final HazardType type;
  final VoteKind kind;
}

class OpenedHazard extends TrainingAction {
  const OpenedHazard(this.type);
  final HazardType type;
}

class ViewedNuclearRings extends TrainingAction {
  const ViewedNuclearRings();
}

class OpenedPlace extends TrainingAction {
  const OpenedPlace(this.category);
  final PoiCategory category;
}

class FilteredHazards extends TrainingAction {
  const FilteredHazards(this.shown);
  final Set<HazardCategory> shown;
}

/// The player added a contamination reading.
class AddedSample extends TrainingAction {
  const AddedSample(this.contaminant);
  final Contaminant contaminant;
}

/// The player opened a contamination reading.
class OpenedSample extends TrainingAction {
  const OpenedSample(this.contaminant);
  final Contaminant contaminant;
}

/// The player found their location (any method).
class FoundMyLocation extends TrainingAction {
  const FoundMyLocation();
}

class PlannedRoute extends TrainingAction {
  const PlannedRoute(this.plan);
  final RoutePlan plan;
}

abstract final class TrainingHooks {
  /// Set while a scenario runs.
  static void Function(TrainingAction action)? listener;

  /// Delivered in a microtask: some actions are reported from inside a
  /// `build` (a sheet showing nuclear rings), and the scenario updates its
  /// own UI in response, which must not happen mid-build.
  static void report(TrainingAction action) {
    final l = listener;
    if (l != null) scheduleMicrotask(() => l(action));
  }
}
