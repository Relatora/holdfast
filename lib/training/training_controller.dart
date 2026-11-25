import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../contamination/contaminants.dart';
import '../contamination/sample.dart';
import '../hazards/hazard.dart';
import '../hazards/hazard_events.dart';
import '../hazards/hazard_repository.dart';
import 'scenario.dart';
import 'training_hooks.dart';

/// Runs one scenario in a sandbox: plays its script on a clock, watches what
/// the player does, and scores the result.
///
/// Everything happens in [sandbox], a [HazardRepository.sandbox] that never
/// touches storage or the network. The real hazard map is untouched.
class TrainingController extends ChangeNotifier {
  TrainingController({
    required this.scenario,
    required this.center,
    required String playerId,
    DateTime Function()? clock,
    this.tick = const Duration(seconds: 1),
  })  : _clock = clock ?? DateTime.now,
        sandbox = HazardRepository.sandbox(deviceId: playerId, clock: clock);

  final Scenario scenario;

  /// Where the scenario is set: the middle of the player's map.
  final LatLng center;
  final DateTime Function() _clock;
  final Duration tick;
  final HazardRepository sandbox;

  /// Objectives done, by index.
  final done = <int>{};

  /// The latest scripted notice, shown like a notification.
  final notices = ValueNotifier<String?>(null);

  Duration elapsed = Duration.zero;
  bool finished = false;
  int stars = 0, score = 0;

  late DateTime _startedAt;
  final _fired = <ScriptedEvent>{};
  final _hazardIds = <String, String>{};
  Timer? _timer;
  var _neighbour = 0;

  Future<void> start() async {
    await sandbox.load();
    sandbox.onRecorded = _onRecorded;
    TrainingHooks.listener = _onAction;
    _startedAt = _clock();
    _timer = Timer.periodic(tick, (_) => advance());
    advance();
  }

  /// Moves the scenario clock on and fires every event that is now due.
  /// Public so tests can drive it with a fake clock.
  void advance() {
    if (finished) return;
    elapsed = _clock().difference(_startedAt);
    for (final event in scenario.events) {
      if (_fired.contains(event) || event.at > elapsed) continue;
      _fired.add(event);
      _fire(event);
    }
    notifyListeners();
  }

  void _fire(ScriptedEvent event) {
    final now = _clock().toUtc();
    switch (event) {
      case ScriptedReport():
        final at = const Distance().offset(center, event.meters, event.bearing);
        final id = 'training-${scenario.id}-${event.ref}';
        _hazardIds[event.ref] = id;
        final hazard = Hazard(
          id: id,
          type: event.type,
          severity: event.severity,
          latitude: at.latitude,
          longitude: at.longitude,
          reportedBy: 'neighbour-${_neighbour++}',
          reportedAt: now,
          details: event.details,
        );
        sandbox.receive([HazardEvent.report('$id-report', hazard)]);
      case ScriptedVotes():
        final hazardId = _hazardIds[event.ref];
        if (hazardId == null) break;
        sandbox.receive([
          for (var i = 0; i < event.count; i++)
            HazardEvent.vote(
              '$hazardId-vote-${_neighbour++}',
              hazardId,
              HazardVote(deviceId: 'neighbour-$_neighbour', kind: event.kind, at: now, distanceMeters: 200),
            ),
        ]);
      case ScriptedSample():
        final at = const Distance().offset(center, event.meters, event.bearing);
        final neighbour = 'neighbour-${_neighbour++}';
        final sample = Sample(
          id: 'training-${scenario.id}-sample-$_neighbour',
          contaminant: event.contaminant,
          value: event.value,
          method: SampleMethod.xrf,
          latitude: at.latitude,
          longitude: at.longitude,
          reportedBy: neighbour,
          reportedAt: now,
          depthCm: 2,
        );
        sandbox.receive([
          HazardEvent.sample('${sample.id}-event',
              sampleId: sample.id, deviceId: neighbour, at: now, payload: sample.toJson()),
        ]);
      case ScriptedNotice():
        break;
    }
    notices.value = event.notice;
  }

  /// Reports and votes the player makes in the sandbox.
  void _onRecorded(HazardEvent event) {
    switch (event.kind) {
      case HazardEventKind.report:
        _onAction(ReportedHazard(HazardType.parse(event.payload['type']! as String)));
      case HazardEventKind.vote:
        final hazard = sandbox.byId(event.hazardId);
        if (hazard != null) {
          _onAction(VotedOnHazard(hazard.type, VoteKind.values.byName(event.payload['kind']! as String)));
        }
      case HazardEventKind.sample:
        if (Contaminant.parse(event.payload['contaminant']) case final contaminant?) {
          _onAction(AddedSample(contaminant));
        }
      case HazardEventKind.credential:
        break;
    }
  }

  void _onAction(TrainingAction action) {
    if (finished) return;
    var changed = false;
    for (final (i, objective) in scenario.objectives.indexed) {
      if (!done.contains(i) && objective.done(action)) {
        done.add(i);
        changed = true;
      }
    }
    if (!changed) return;
    if (done.length == scenario.objectives.length) {
      finish();
    } else {
      notifyListeners();
    }
  }

  /// Ends the run and scores it (also called when the player gives up).
  void finish() {
    if (finished) return;
    elapsed = _clock().difference(_startedAt);
    finished = true;
    _timer?.cancel();
    stars = starsFor(scenario, done, elapsed);
    score = scoreFor(scenario, done, elapsed);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (TrainingHooks.listener == _onAction) TrainingHooks.listener = null;
    sandbox.onRecorded = null;
    sandbox.dispose();
    notices.dispose();
    super.dispose();
  }
}
