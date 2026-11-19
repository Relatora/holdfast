import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_events.dart';

void main() {
  final reportedAt = DateTime.utc(2026, 11, 19, 9);
  final hazard = Hazard(
    id: 'h1',
    type: HazardType.fire,
    severity: HazardSeverity.extreme,
    latitude: 45.4,
    longitude: -75.7,
    reportedBy: 'phone-a',
    reportedAt: reportedAt,
  );
  final report = HazardEvent.report('e1', hazard);
  final vote = HazardEvent.vote(
    'e2',
    'h1',
    HazardVote(deviceId: 'phone-b', kind: VoteKind.confirm, at: reportedAt.add(const Duration(minutes: 5))),
  );

  test('folding a report and a vote attaches the vote', () {
    final hazards = foldHazardEvents([report, vote]);
    expect(hazards['h1']!.votes, hasLength(1));
  });

  test('order does not matter: a vote that arrives first is kept', () {
    final hazards = foldHazardEvents([vote, report]);
    expect(hazards['h1']!.votes.single.deviceId, 'phone-b');
  });

  test('duplicate deliveries are applied once', () {
    final hazards = foldHazardEvents([report, vote, vote, report]);
    expect(hazards, hasLength(1));
    expect(hazards['h1']!.votes, hasLength(1));
  });

  test('votes for an unknown hazard produce nothing until the report arrives', () {
    expect(foldHazardEvents([vote]), isEmpty);
  });

  test('events survive a JSON round trip (the sync wire format)', () {
    final decoded = HazardEvent.fromJson(report.toJson());
    final hazards = foldHazardEvents([decoded]);
    expect(hazards['h1']!.type, HazardType.fire);
    expect(decoded.latitude, 45.4);
  });
}
