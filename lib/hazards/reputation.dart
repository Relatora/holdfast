/// How reliable each reporter has been, from what became of their past
/// reports and votes. Plain Dart, computed on every device from the same
/// shared event log, so every device reaches the same weights.
///
/// Only *settled* hazards count (expired or cleared): an open report says
/// nothing yet about whether its reporter was right. Weights therefore
/// change slowly and can't be pumped up by confirming your friends' live
/// reports.
///
/// Known limit: someone running many devices can still build up several
/// "reliable" identities. Signed device keys (issue #14) are the fix; this
/// scores reports, it doesn't prove who made them.
library;

import 'dart:math' as math;

import 'hazard.dart';
import 'hazard_engine.dart';

/// One device's track record.
class ReporterRecord {
  int goodReports = 0;
  int badReports = 0;
  int goodVotes = 0;
  int badVotes = 0;

  /// Other people's confirmations of this device's reports, ever.
  int confirmationsReceived = 0;

  /// Completed every training scenario (a small, capped head start).
  bool trained = false;

  int get settledReports => goodReports + badReports;

  /// Share of settled reports that held up, or null with none yet.
  double? get accuracy => settledReports == 0 ? null : goodReports / settledReports;

  /// Beta-distribution mean of "this reporter is right": starts at 0.5 with
  /// no history (α = β = 1). Reports weigh more than votes, and a bad
  /// report weighs more than a good one, because a false alarm costs more
  /// than a missed confirmation.
  double get score {
    final alpha = 1 + goodReports + 0.5 * goodVotes + (trained ? trainingPrior : 0);
    final beta = 1 + 1.5 * badReports + 0.5 * badVotes;
    return alpha / (alpha + beta);
  }

  /// How much this device's votes count: 1× for a newcomer, from 0.5× for a
  /// poor record up to 2× for a long, accurate one.
  double get multiplier => (2 * score).clamp(minMultiplier, maxMultiplier).toDouble();

  static const minMultiplier = 0.5;
  static const maxMultiplier = 2.0;

  /// Training adds this much to α: about 1.1× for a newcomer, enough to
  /// reward preparing, far too little to verify anything alone. Training
  /// can't be checked by other devices, so it is kept deliberately small.
  static const trainingPrior = 0.25;
}

/// How a settled report turned out.
enum ReportOutcome {
  /// Confirmed by others (or official) and never cleared early.
  heldUp,

  /// Cleared soon after it was made, or disputed without ever being
  /// confirmed.
  falseAlarm,

  /// Expired with no one weighing in either way: no evidence.
  unknown,
}

/// The outcome of [hazard] at [now], or null while it is still open.
ReportOutcome? outcomeOf(Hazard hazard, DateTime now, {HazardPolicy policy = HazardPolicy.standard}) {
  final assessment = assessHazard(hazard, now, policy: policy);
  if (assessment.status.isActive) return null;
  final confirmed = hazard.official || assessment.confirmWeight >= policy.confirmationsToVerify;
  if (assessment.status == HazardStatus.cleared) {
    // A real hazard that was later cleared ("it's gone") is fine; one
    // cleared within a quarter of its lifetime, never confirmed, was a
    // false alarm.
    final clearedAt = hazard.votes
        .where((v) => v.kind == VoteKind.clear)
        .fold<DateTime?>(null, (latest, v) => latest == null || v.at.isAfter(latest) ? v.at : latest);
    final early = clearedAt != null && clearedAt.difference(hazard.reportedAt) < hazard.type.lifetime * 0.25;
    if (!confirmed && early) return ReportOutcome.falseAlarm;
    return confirmed ? ReportOutcome.heldUp : ReportOutcome.unknown;
  }
  if (confirmed) return ReportOutcome.heldUp;
  return assessment.clearWeight > 0 ? ReportOutcome.falseAlarm : ReportOutcome.unknown;
}

/// Track records for every device seen in [hazards].
Map<String, ReporterRecord> computeReputation(
  Iterable<Hazard> hazards,
  DateTime now, {
  Set<String> trained = const {},
}) {
  final records = <String, ReporterRecord>{};
  ReporterRecord recordOf(String device) => records.putIfAbsent(device, ReporterRecord.new);

  for (final hazard in hazards) {
    final reporter = recordOf(hazard.reportedBy);
    reporter.confirmationsReceived += hazard.votes
        .where((v) => v.kind == VoteKind.confirm && v.deviceId != hazard.reportedBy)
        .map((v) => v.deviceId)
        .toSet()
        .length;

    final outcome = outcomeOf(hazard, now);
    if (outcome == null || outcome == ReportOutcome.unknown) continue;
    if (outcome == ReportOutcome.heldUp) {
      reporter.goodReports++;
    } else {
      reporter.badReports++;
    }

    // Each other device's latest vote: right if it agreed with the outcome.
    final latest = <String, HazardVote>{};
    for (final vote in hazard.votes) {
      if (vote.deviceId == hazard.reportedBy) continue;
      final previous = latest[vote.deviceId];
      if (previous == null || vote.at.isAfter(previous.at)) latest[vote.deviceId] = vote;
    }
    for (final vote in latest.values) {
      final record = recordOf(vote.deviceId);
      final agreed = (vote.kind == VoteKind.confirm) == (outcome == ReportOutcome.heldUp);
      // "It's gone" on a hazard that held up is usually just someone
      // reporting that it ended; don't count it against them.
      if (vote.kind == VoteKind.clear && outcome == ReportOutcome.heldUp) continue;
      if (agreed) {
        record.goodVotes++;
      } else {
        record.badVotes++;
      }
    }
  }
  for (final device in trained) {
    recordOf(device).trained = true;
  }
  return records;
}

/// The weight of [deviceId]'s votes under [records]: 1 for unknown devices.
double weightOf(Map<String, ReporterRecord> records, String deviceId) =>
    records[deviceId]?.multiplier ?? 1.0;

/// How much a trusted reporter's own report counts towards verification:
/// half of what their multiplier adds above 1, so a 2× reporter's report
/// is worth half a confirmation and a newcomer's nothing.
double reporterBonus(double multiplier) => math.max(0, (multiplier - 1) * 0.5);
