import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_engine.dart';

/// A fixed "now" keeps every test independent of the wall clock.
final t0 = DateTime.utc(2026, 11, 19, 12);

Hazard flood({bool official = false, List<HazardVote> votes = const []}) => Hazard(
      id: 'h1',
      type: HazardType.flood, // 72 h lifetime
      severity: HazardSeverity.high,
      latitude: 45.42,
      longitude: -75.69,
      reportedBy: 'reporter',
      reportedAt: t0,
      official: official,
      votes: votes,
    );

HazardVote confirm(String device, {Duration after = const Duration(minutes: 10), double? meters = 100}) =>
    HazardVote(deviceId: device, kind: VoteKind.confirm, at: t0.add(after), distanceMeters: meters);

HazardVote clear(String device, {Duration after = const Duration(minutes: 20), double? meters = 100}) =>
    HazardVote(deviceId: device, kind: VoteKind.clear, at: t0.add(after), distanceMeters: meters);

void main() {
  final soon = t0.add(const Duration(hours: 1));

  group('verification', () {
    test('a fresh report is unverified', () {
      expect(assessHazard(flood(), soon).status, HazardStatus.unverified);
    });

    test('two nearby independent confirmations verify it', () {
      final hazard = flood(votes: [confirm('a'), confirm('b')]);
      expect(assessHazard(hazard, soon).status, HazardStatus.verified);
    });

    test('official hazards are verified with no votes', () {
      expect(assessHazard(flood(official: true), soon).status, HazardStatus.verified);
    });

    test("the reporter's own confirmations don't count", () {
      final hazard = flood(votes: [confirm('reporter'), confirm('reporter'), confirm('a')]);
      final result = assessHazard(hazard, soon);
      expect(result.confirmWeight, 1.0);
      expect(result.status, HazardStatus.unverified);
    });

    test('repeat taps from one device count once', () {
      final hazard = flood(votes: [
        confirm('a'),
        confirm('a', after: const Duration(minutes: 11)),
        confirm('a', after: const Duration(minutes: 12)),
      ]);
      expect(assessHazard(hazard, soon).confirmWeight, 1.0);
    });

    test('far-away votes count half, so it takes more of them', () {
      final far = flood(votes: [confirm('a', meters: 30000), confirm('b', meters: 30000)]);
      expect(assessHazard(far, soon).status, HazardStatus.unverified);

      final more = far.withVote(confirm('c', meters: 30000)).withVote(confirm('d', meters: 30000));
      expect(assessHazard(more, soon).status, HazardStatus.verified);
    });
  });

  group('expiry', () {
    test('expires one lifetime after the report when nobody confirms', () {
      final result = assessHazard(flood(), t0.add(const Duration(hours: 72, seconds: 1)));
      expect(result.status, HazardStatus.expired);
      expect(result.opacity, 0);
    });

    test('a confirmation restarts the lifetime', () {
      final hazard = flood(votes: [confirm('a', after: const Duration(hours: 70))]);
      final result = assessHazard(hazard, t0.add(const Duration(hours: 100)));
      expect(result.status.isActive, isTrue);
      expect(result.expiresAt, t0.add(const Duration(hours: 142)));
    });

    test('fades out during the final hour', () {
      final result = assessHazard(flood(), t0.add(const Duration(hours: 71, minutes: 30)));
      expect(result.opacity, closeTo(0.5, 0.01));
    });

    test('votes from the future (clock skew) are ignored', () {
      final hazard = flood(votes: [confirm('a', after: const Duration(days: 30))]);
      expect(assessHazard(hazard, soon).confirmWeight, 0);
    });
  });

  group('clearing', () {
    test('one "it\'s gone" vote marks it disputed', () {
      final hazard = flood(votes: [confirm('a'), confirm('b'), clear('c')]);
      expect(assessHazard(hazard, soon).status, HazardStatus.disputed);
    });

    test('enough clears that outnumber confirmations remove it', () {
      final hazard = flood(votes: [confirm('a'), clear('b'), clear('c')]);
      expect(assessHazard(hazard, soon).status, HazardStatus.cleared);
    });

    test('a device can change its mind; only its latest vote counts', () {
      final hazard = flood(votes: [
        clear('a', after: const Duration(minutes: 5)),
        confirm('a', after: const Duration(minutes: 30)),
        confirm('b'),
      ]);
      expect(assessHazard(hazard, soon).status, HazardStatus.verified);
    });
  });

  group('visibility', () {
    test('unverified reports are hidden unless the user opts in', () {
      final result = assessHazard(flood(), soon);
      expect(isVisible(result, showUnverified: false), isFalse);
      expect(isVisible(result, showUnverified: true), isTrue);
    });

    test('cleared and expired hazards are never shown', () {
      final cleared = assessHazard(flood(votes: [clear('a'), clear('b')]), soon);
      expect(isVisible(cleared, showUnverified: true), isFalse);
    });
  });
}
