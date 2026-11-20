/// The pieces of a training scenario: what happens (scripted reports and
/// votes from pretend neighbours), what the player is asked to do, and how
/// it is scored. Plain Dart, so scenarios are unit-tested.
library;

import 'package:material_ui/material_ui.dart' show IconData;

import '../hazards/hazard.dart';
import '../pois/poi.dart';
import 'training_hooks.dart';

/// Something that happens at a set time after the scenario starts.
sealed class ScriptedEvent {
  const ScriptedEvent(this.at, this.notice);

  final Duration at;

  /// What the player is told, like a notification: "New report nearby:
  /// downed power lines, 600 m north".
  final String notice;
}

/// A pretend neighbour reports a hazard [meters] away at [bearing] from
/// the scenario's centre. [ref] names it for later votes.
class ScriptedReport extends ScriptedEvent {
  const ScriptedReport({
    required Duration at,
    required String notice,
    required this.ref,
    required this.type,
    required this.bearing,
    required this.meters,
    this.severity = HazardSeverity.high,
    this.details = const {},
  }) : super(at, notice);

  final String ref;
  final HazardType type;
  final double bearing, meters;
  final HazardSeverity severity;
  final Map<String, Object?> details;
}

/// [count] pretend neighbours vote on the report named [ref].
class ScriptedVotes extends ScriptedEvent {
  const ScriptedVotes({
    required Duration at,
    required String notice,
    required this.ref,
    required this.kind,
    this.count = 2,
  }) : super(at, notice);

  final String ref;
  final VoteKind kind;
  final int count;
}

/// A plain notice: a weather update, an official instruction.
class ScriptedNotice extends ScriptedEvent {
  const ScriptedNotice({required Duration at, required String notice}) : super(at, notice);
}

/// Something the player is asked to do, and how to recognise it.
class Objective {
  const Objective(this.text, this.done, {this.points = 100});

  final String text;
  final bool Function(TrainingAction action) done;
  final int points;
}

// Common objectives, so scenarios read like a checklist.
Objective reportA(HazardType type, String text) => Objective(text, (a) => a is ReportedHazard && a.type == type);
Objective confirmA(HazardType type, String text) =>
    Objective(text, (a) => a is VotedOnHazard && a.type == type && a.kind == VoteKind.confirm);
Objective clearA(HazardType type, String text) =>
    Objective(text, (a) => a is VotedOnHazard && a.type == type && a.kind == VoteKind.clear);
Objective open(HazardType type, String text) => Objective(text, (a) => a is OpenedHazard && a.type == type);
Objective findA(PoiCategory category, String text) =>
    Objective(text, (a) => a is OpenedPlace && a.category == category);
Objective filterTo(HazardCategory category, String text) =>
    Objective(text, (a) => a is FilteredHazards && a.shown.contains(category));
Objective routeAround(String text) =>
    Objective(text, (a) => a is PlannedRoute && a.plan.avoided > 0 && !a.plan.throughHazard);
Objective readRings(String text) => Objective(text, (a) => a is ViewedNuclearRings);

class Scenario {
  const Scenario({
    required this.id,
    required this.title,
    required this.icon,
    required this.briefing,
    required this.lesson,
    required this.par,
    required this.events,
    required this.objectives,
  });

  /// Stable: stored with the player's stars.
  final String id;
  final String title;
  final IconData icon;

  /// The situation, read before starting.
  final String briefing;

  /// The "prepare before it happens" message on the finish card.
  final String lesson;

  /// Finishing every objective within this earns three stars.
  final Duration par;

  final List<ScriptedEvent> events;
  final List<Objective> objectives;

  int get maxPoints => objectives.fold(0, (sum, o) => sum + o.points);
}

/// 0-3 stars: 3 for every objective within par, 2 for every objective, 1
/// for at least half, 0 otherwise.
int starsFor(Scenario scenario, Set<int> doneObjectives, Duration took) {
  final all = doneObjectives.length == scenario.objectives.length;
  if (all && took <= scenario.par) return 3;
  if (all) return 2;
  if (doneObjectives.length * 2 >= scenario.objectives.length) return 1;
  return 0;
}

/// Points: each objective's worth, plus up to 50% more for finishing fast.
int scoreFor(Scenario scenario, Set<int> doneObjectives, Duration took) {
  final base = [for (final i in doneObjectives) scenario.objectives[i].points].fold(0, (a, b) => a + b);
  if (doneObjectives.length < scenario.objectives.length) return base;
  final speed = (1 - took.inSeconds / (scenario.par.inSeconds * 2)).clamp(0.0, 1.0);
  return base + (base * 0.5 * speed).round();
}
