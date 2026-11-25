import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/contamination/contaminants.dart';
import 'package:holdfast/contamination/interpolation.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_details.dart';
import 'package:holdfast/pois/poi.dart';
import 'package:holdfast/reputation/achievements.dart';
import 'package:holdfast/training/scenario.dart';
import 'package:holdfast/training/scenarios.dart';
import 'package:holdfast/training/training_controller.dart';
import 'package:holdfast/training/training_hooks.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('the scenarios', () {
    test('ids are unique and the badge count matches', () {
      final ids = scenarios.map((s) => s.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(scenarios, hasLength(trainingScenarioCount));
    });

    test('every scripted hazard\'s details parse (a typo would draw nothing)', () {
      expect(scenarioDetailsParse(), isTrue);
    });

    test('each has objectives, a lesson and events', () {
      for (final s in scenarios) {
        expect(s.objectives, isNotEmpty, reason: s.id);
        expect(s.events, isNotEmpty, reason: s.id);
        expect(s.lesson.length, greaterThan(40), reason: s.id);
      }
    });
  });

  group('scoring', () {
    final s = scenarios.first; // 3 objectives, par 150 s
    test('stars', () {
      expect(starsFor(s, {0, 1, 2}, const Duration(seconds: 100)), 3);
      expect(starsFor(s, {0, 1, 2}, const Duration(seconds: 400)), 2);
      expect(starsFor(s, {0, 1}, const Duration(seconds: 100)), 1);
      expect(starsFor(s, {}, const Duration(seconds: 10)), 0);
    });

    test('finishing faster scores more; unfinished earns only its objectives', () {
      expect(scoreFor(s, {0, 1, 2}, const Duration(seconds: 30)), greaterThan(scoreFor(s, {0, 1, 2}, const Duration(seconds: 250))));
      expect(scoreFor(s, {0}, const Duration(seconds: 1)), s.objectives[0].points);
    });
  });

  group('a run', () {
    late DateTime now;
    late TrainingController controller;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      now = DateTime.utc(2026, 11, 20, 12);
      controller = TrainingController(
        scenario: scenarios.firstWhere((s) => s.id == 'iceStorm'),
        center: const LatLng(45.42, -75.69),
        playerId: 'me',
        clock: () => now,
        tick: const Duration(days: 1), // the test drives the clock
      );
      await controller.start();
    });

    tearDown(() => controller.dispose());

    test('scripted reports and votes arrive on time, as notices', () {
      expect(controller.sandbox.hazards, isEmpty);
      now = now.add(const Duration(seconds: 5));
      controller.advance();
      final lines = controller.sandbox.hazards.single;
      expect(lines.type, HazardType.powerLines);
      expect(controller.notices.value, contains('downed power lines'));
      // About 600 m from the centre.
      expect(const Distance()(const LatLng(45.42, -75.69), LatLng(lines.latitude, lines.longitude)), closeTo(600, 5));

      now = now.add(const Duration(seconds: 20));
      controller.advance();
      expect(controller.sandbox.hazards.single.votes, hasLength(1));
    });

    test('objectives tick off from the player\'s own actions; all done finishes with stars', () async {
      now = now.add(const Duration(seconds: 5));
      controller.advance();
      final lines = controller.sandbox.hazards.single;

      await controller.sandbox.vote(lines.id, VoteKind.confirm);
      expect(controller.done, {0});

      TrainingHooks.report(const OpenedPlace(PoiCategory.shelter));
      await Future<void>.delayed(Duration.zero); // hooks arrive in a microtask
      expect(controller.done, {0, 1});

      now = now.add(const Duration(seconds: 30));
      await controller.sandbox.report(type: HazardType.roadBlocked, severity: HazardSeverity.moderate, latitude: 45.42, longitude: -75.69);
      expect(controller.finished, isTrue);
      expect(controller.stars, 3, reason: 'all three within par');
    });

    test('the sandbox never writes to storage', () async {
      await controller.sandbox.report(type: HazardType.fire, severity: HazardSeverity.high, latitude: 45, longitude: -75);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('hazardLog'), isNull);
      expect(controller.sandbox.sync, isNull, reason: 'and never syncs');
    });

    test('a report from the scenario carries its details', () {
      final drill = TrainingController(
        scenario: scenarios.firstWhere((s) => s.id == 'nuclearDrill'),
        center: const LatLng(45.42, -75.69),
        playerId: 'me',
        clock: () => now,
        tick: const Duration(days: 1),
      );
      addTearDown(drill.dispose);
      return drill.start().then((_) {
        now = now.add(const Duration(seconds: 5));
        drill.advance();
        final blast = drill.sandbox.hazards.single;
        expect(blast.nuclear?.burst, BurstType.surface);
        expect(blast.wind?.fromCompass, 'NW');
      });
    });
  });

  test('the lead dust release: neighbour readings arrive, and reading and adding them count', () async {
    SharedPreferences.setMockInitialValues({});
    var now = DateTime.utc(2026, 11, 25, 15);
    final lead = TrainingController(
      scenario: scenarios.firstWhere((s) => s.id == 'leadDustRelease'),
      center: const LatLng(40.80, -91.26),
      playerId: 'me',
      clock: () => now,
      tick: const Duration(days: 1),
    );
    await lead.start();
    addTearDown(lead.dispose);

    now = now.add(const Duration(seconds: 5));
    lead.advance();
    final release = lead.sandbox.hazards.single;
    expect(release.type, HazardType.leadDust);
    expect(release.wind!.fromCompass, 'NE', reason: 'it drifts towards the player');

    now = now.add(const Duration(seconds: 40));
    lead.advance();
    final readings = lead.sandbox.liveSamples;
    expect(readings, hasLength(5));
    expect(readings.map((s) => s.level), contains(ContaminationLevel.dangerous));
    expect(estimateZones(readings), hasLength(1), reason: 'enough readings for a zone');

    final objectives = lead.scenario.objectives;
    TrainingHooks.report(const FoundMyLocation());
    TrainingHooks.report(OpenedSample(readings.first.contaminant));
    await Future<void>.delayed(Duration.zero);
    expect(lead.done, containsAll([objectives.indexWhere((o) => o.text.contains('location')), objectives.indexWhere((o) => o.text.contains('soil reading'))]));

    await lead.sandbox.addSample(
      contaminant: Contaminant.lead,
      value: 180,
      method: SampleMethod.kit,
      latitude: 40.80,
      longitude: -91.26,
    );
    expect(lead.done, contains(objectives.indexWhere((o) => o.text.contains('add a lead reading'))));
  });
}
