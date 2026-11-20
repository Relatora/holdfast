import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_engine.dart';
import 'package:holdfast/hazards/hazard_events.dart';
import 'package:holdfast/hazards/hazard_repository.dart';
import 'package:holdfast/hazards/reputation.dart';
import 'package:holdfast/sync/sync_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final t0 = DateTime.utc(2026, 11, 1);

HazardVote vote(String device, VoteKind kind, {int minutes = 10}) =>
    HazardVote(deviceId: device, kind: kind, at: t0.add(Duration(minutes: minutes)), distanceMeters: 100);

Hazard report(String id, String by, {List<HazardVote> votes = const [], HazardType type = HazardType.roadBlocked}) =>
    Hazard(
      id: id,
      type: type,
      severity: HazardSeverity.moderate,
      latitude: 45.42,
      longitude: -75.69,
      reportedBy: by,
      reportedAt: t0,
      votes: votes,
    );

/// Long after every road-block report has expired, so all are settled.
final later = t0.add(const Duration(days: 3));

void main() {
  group('outcomes', () {
    test('a confirmed report held up; one cleared at once with no support was a false alarm', () {
      expect(
        outcomeOf(report('a', 'r', votes: [vote('x', VoteKind.confirm), vote('y', VoteKind.confirm)]), later),
        ReportOutcome.heldUp,
      );
      expect(
        outcomeOf(report('b', 'r', votes: [vote('x', VoteKind.clear), vote('y', VoteKind.clear)]), later),
        ReportOutcome.falseAlarm,
      );
      expect(outcomeOf(report('c', 'r'), later), ReportOutcome.unknown, reason: 'nobody weighed in');
    });

    test('an open report says nothing yet', () {
      expect(outcomeOf(report('a', 'r', votes: [vote('x', VoteKind.confirm)]), t0.add(const Duration(hours: 1))), isNull);
    });
  });

  group('track records', () {
    test('a newcomer counts 1x', () {
      expect(ReporterRecord().multiplier, 1.0);
    });

    test('accurate reports raise the weight, false alarms lower it, within 0.5x-2x', () {
      final good = [
        for (var i = 0; i < 12; i++) report('g$i', 'reliable', votes: [vote('x', VoteKind.confirm), vote('y', VoteKind.confirm)]),
      ];
      final bad = [
        for (var i = 0; i < 6; i++) report('b$i', 'careless', votes: [vote('x', VoteKind.clear), vote('y', VoteKind.clear)]),
      ];
      final records = computeReputation([...good, ...bad], later);
      expect(records['reliable']!.multiplier, inInclusiveRange(1.7, 2.0));
      expect(records['reliable']!.accuracy, 1.0);
      expect(records['careless']!.multiplier, inInclusiveRange(0.5, 0.6));
    });

    test('votes that agreed with the outcome count in the voter\'s favour', () {
      final records = computeReputation([
        report('a', 'r', votes: [vote('right', VoteKind.confirm), vote('x', VoteKind.confirm)]),
        report('b', 'r', votes: [vote('wrong', VoteKind.confirm), vote('x', VoteKind.clear), vote('y', VoteKind.clear)]),
      ], later);
      expect(records['right']!.goodVotes, 1);
      expect(records['wrong']!.badVotes, 1);
      expect(records['right']!.multiplier, greaterThan(records['wrong']!.multiplier));
    });

    test('training gives a small, capped head start', () {
      final records = computeReputation([], later, trained: {'cadet'});
      expect(records['cadet']!.multiplier, inInclusiveRange(1.05, 1.15));
    });

    test('confirmations received are counted once per device', () {
      final records = computeReputation([
        report('a', 'r', votes: [vote('x', VoteKind.confirm), vote('x', VoteKind.confirm, minutes: 20), vote('y', VoteKind.confirm)]),
      ], later);
      expect(records['r']!.confirmationsReceived, 2);
    });
  });

  group('weighted verification', () {
    final open = t0.add(const Duration(hours: 1));
    double trusted(String device) => device.startsWith('trusted') ? 1.8 : 1.0;

    test('two trusted confirmations verify; with a newcomer reporter one trusted vote does not', () {
      final one = report('a', 'newbie', votes: [vote('trusted1', VoteKind.confirm)]);
      expect(assessHazard(one, open, reputation: trusted).status, HazardStatus.unverified);
      final two = report('b', 'newbie', votes: [vote('trusted1', VoteKind.confirm), vote('trusted2', VoteKind.confirm)]);
      expect(assessHazard(two, open, reputation: trusted).status, HazardStatus.verified);
    });

    test("a trusted reporter's own report counts for part of a confirmation", () {
      final byTrusted = report('a', 'trustedReporter', votes: [vote('trusted1', VoteKind.confirm)]);
      // 1.8 (vote) + 0.4 (reporter) >= 2.0
      expect(assessHazard(byTrusted, open, reputation: trusted).status, HazardStatus.verified);
      // Without reputation, the same report is still unverified.
      expect(assessHazard(byTrusted, open).status, HazardStatus.unverified);
    });
  });

  group('repository', () {
    test('says thank you when someone newly confirms one of my reports', () async {
      SharedPreferences.setMockInitialValues({});
      final remote = <Map<String, Object?>>[];
      final client = MockClient((request) async {
        if (request.method == 'POST') return http.Response('{}', 200);
        return http.Response(jsonEncode({'events': remote, 'cursor': remote.length}), 200);
      });
      final repo = HazardRepository(deviceId: 'me', sync: SyncClient('http://test', client: client), clock: () => t0);
      // load() and report() each start a sync in the background; wait for
      // any running one before starting ours, or ours returns at once.
      Future<void> sync() async {
        while (repo.syncStatus == SyncStatus.syncing) {
          await Future<void>.delayed(Duration.zero);
        }
        await repo.syncNow();
      }

      await repo.load();
      final mine = await repo.report(type: HazardType.flood, severity: HazardSeverity.high, latitude: 45, longitude: -75);
      await sync();
      expect(repo.thanks.value, isNull);

      remote.add(HazardEvent.vote('v1', mine.id, vote('neighbour', VoteKind.confirm)).toJson());
      await sync();
      expect(repo.thanks.value?.hazard.id, mine.id);
      expect(repo.thanks.value?.confirmations, 1);
      repo.dispose();
    });

    test('a training credential reaches other devices as a head start', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = HazardRepository(deviceId: 'cadet', clock: () => t0);
      await repo.load();
      expect(repo.myRecord.trained, isFalse);
      await repo.publishTrainingCredential(['iceStorm']);
      expect(repo.myRecord.trained, isTrue);
      expect(repo.myRecord.multiplier, greaterThan(1.0));
      repo.dispose();
    });

    test('an event kind from a newer app is skipped, not fatal', () {
      expect(HazardEvent.tryFromJson({'kind': 'teleport', 'id': 'x'}), isNull);
    });
  });
}
