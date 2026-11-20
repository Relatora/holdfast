import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/hazards/reputation.dart';
import 'package:holdfast/reputation/achievements.dart';

ReporterRecord record({int good = 0, int bad = 0, int confirmations = 0, int goodVotes = 0, bool trained = false}) =>
    ReporterRecord()
      ..goodReports = good
      ..badReports = bad
      ..confirmationsReceived = confirmations
      ..goodVotes = goodVotes
      ..trained = trained;

Set<String> unlocked(AchievementInput input) => {for (final a in achievements) if (a.unlocked(input)) a.id};

void main() {
  group('ranks', () {
    test('everyone starts as an Observer', () {
      expect(Tier.of(record()), Tier.observer);
    });

    test('training or three good reports make a Scout', () {
      expect(Tier.of(record(trained: true)), Tier.scout);
      expect(Tier.of(record(good: 3)), Tier.scout);
    });

    test('higher ranks need both volume and accuracy', () {
      expect(Tier.of(record(good: 12)), Tier.sentinel);
      // Lots of reports, but so many false alarms the weight stays low.
      expect(Tier.of(record(good: 12, bad: 12)), Tier.scout);
      expect(Tier.of(record(good: 30)), Tier.guardian);
    });

    test('each rank names the next', () {
      expect(Tier.observer.next, Tier.scout);
      expect(Tier.guardian.next, isNull);
    });
  });

  group('achievements', () {
    test('a newcomer has none', () {
      expect(unlocked(AchievementInput(record: record(), reportsMade: 0, trainingStars: const {})), isEmpty);
    });

    test('reporting, being backed up and voting well each unlock their own', () {
      final ids = unlocked(AchievementInput(
        record: record(good: 5, confirmations: 10, goodVotes: 10),
        reportsMade: 6,
        trainingStars: const {},
      ));
      expect(ids, containsAll(['firstReport', 'firstConfirmed', 'heldUp5', 'confirmedBy10', 'goodVotes10']));
      expect(ids, isNot(contains('heldUp25')));
    });

    test('training: one scenario, all scenarios, and all with three stars', () {
      final some = {'iceStorm': 2};
      final all = {for (var i = 0; i < trainingScenarioCount; i++) 's$i': 2};
      final perfect = {for (var i = 0; i < trainingScenarioCount; i++) 's$i': 3};
      AchievementInput withStars(Map<String, int> stars) =>
          AchievementInput(record: record(), reportsMade: 0, trainingStars: stars);

      expect(unlocked(withStars(some)), {'firstTraining'});
      expect(unlocked(withStars(all)), {'firstTraining', 'trained'});
      expect(unlocked(withStars(perfect)), {'firstTraining', 'trained', 'allStars'});
    });

    test('ids are unique, since they are stored', () {
      final ids = achievements.map((a) => a.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });
  });
}
