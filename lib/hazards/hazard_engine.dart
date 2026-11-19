/// The rules that turn raw reports and votes into "is this on the map?".
///
/// Pure functions only: give it a hazard and a time, get the same answer on
/// every device. That property is what lets two phones on a mesh network,
/// with no server between them, agree on which hazards are real.
library;

import 'dart:math' as math;

import 'hazard.dart';

/// Where a hazard is in its life.
enum HazardStatus {
  /// Reported, but not enough independent confirmations yet. Hidden unless
  /// the user opts in to unverified reports.
  unverified,

  /// Confirmed by enough independent devices, or from an official feed.
  /// Shown to everyone.
  verified,

  /// Someone says it's gone, but not enough people agree yet.
  disputed,

  /// Enough devices say it's gone.
  cleared,

  /// Nobody has confirmed it for longer than its type's lifetime.
  expired;

  /// Whether this status belongs on the live map at all.
  bool get isActive => this != cleared && this != expired;
}

/// Tunable thresholds. One shared constant today; per-region policies (a
/// rural area has fewer people to confirm anything) are an obvious next step.
class HazardPolicy {
  const HazardPolicy({
    this.confirmationsToVerify = 2.0,
    this.clearsToRemove = 2.0,
    this.nearbyRadiusMeters = 2000,
    this.fadeOutWindow = const Duration(hours: 1),
  });

  /// Weighted confirmations needed before a report is shown to everyone.
  final double confirmationsToVerify;

  /// Weighted "it's gone" votes needed to clear a hazard early.
  final double clearsToRemove;

  /// Votes cast within this distance count in full; farther votes count half.
  final double nearbyRadiusMeters;

  /// Markers fade out over this final stretch before expiry.
  final Duration fadeOutWindow;

  static const standard = HazardPolicy();
}

/// The engine's verdict on one hazard at one moment.
class HazardAssessment {
  const HazardAssessment({
    required this.status,
    required this.confirmWeight,
    required this.clearWeight,
    required this.lastActivity,
    required this.expiresAt,
    required this.opacity,
  });

  final HazardStatus status;

  /// Sum of independent, distance-weighted "still there" votes.
  final double confirmWeight;

  /// Sum of independent, distance-weighted "it's gone" votes.
  final double clearWeight;

  /// The report time or the latest confirmation, whichever is later.
  final DateTime lastActivity;

  /// When the hazard expires if nobody confirms it again.
  final DateTime expiresAt;

  /// 1.0 normally; falls towards 0.0 during the policy's fade-out window so
  /// stale hazards visibly age instead of vanishing abruptly.
  final double opacity;

  Duration remaining(DateTime now) {
    final left = expiresAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }
}

/// How much a single vote counts, based on how close the voter was.
double voteWeight(HazardVote vote, HazardPolicy policy) {
  final distance = vote.distanceMeters;
  if (distance == null) return 0.75; // unknown: some trust, not full trust
  return distance <= policy.nearbyRadiusMeters ? 1.0 : 0.5;
}

/// Assesses [hazard] at time [now].
///
/// The rules, in order:
/// 1. Each device's **latest** vote is the only one that counts, so nobody
///    can vote a hazard into existence by tapping "confirm" ten times.
/// 2. The reporter's own votes are ignored for the same reason.
/// 3. A hazard expires `type.lifetime` after its last sign of life. Any
///    confirmation restarts that clock.
/// 4. Enough weighted "it's gone" votes, outnumbering confirmations, clear it.
/// 5. Any "it's gone" vote short of that marks it disputed.
/// 6. Official hazards, or enough weighted confirmations, verify it.
HazardAssessment assessHazard(
  Hazard hazard,
  DateTime now, {
  HazardPolicy policy = HazardPolicy.standard,
}) {
  // Rule 1 and 2: keep only the most recent vote per independent device.
  final latestByDevice = <String, HazardVote>{};
  for (final vote in hazard.votes) {
    if (vote.deviceId == hazard.reportedBy) continue;
    if (vote.at.isAfter(now)) continue; // ignore clock-skewed future votes
    final previous = latestByDevice[vote.deviceId];
    if (previous == null || vote.at.isAfter(previous.at)) {
      latestByDevice[vote.deviceId] = vote;
    }
  }

  var confirmWeight = 0.0;
  var clearWeight = 0.0;
  var lastActivity = hazard.reportedAt;
  for (final vote in latestByDevice.values) {
    final weight = voteWeight(vote, policy);
    if (vote.kind == VoteKind.confirm) {
      confirmWeight += weight;
      if (vote.at.isAfter(lastActivity)) lastActivity = vote.at;
    } else {
      clearWeight += weight;
    }
  }

  // Rule 3: lifetime runs from the last sign of life.
  final expiresAt = lastActivity.add(hazard.type.lifetime);
  final remaining = expiresAt.difference(now);
  final fadeMs = policy.fadeOutWindow.inMilliseconds;
  final opacity = remaining.isNegative
      ? 0.0
      : math.min(1.0, remaining.inMilliseconds / fadeMs).clamp(0.15, 1.0).toDouble();

  final HazardStatus status;
  if (!remaining.isNegative && remaining != Duration.zero) {
    if (clearWeight >= policy.clearsToRemove && clearWeight > confirmWeight) {
      status = HazardStatus.cleared; // rule 4
    } else if (clearWeight > 0) {
      status = HazardStatus.disputed; // rule 5
    } else if (hazard.official || confirmWeight >= policy.confirmationsToVerify) {
      status = HazardStatus.verified; // rule 6
    } else {
      status = HazardStatus.unverified;
    }
  } else {
    status = HazardStatus.expired;
  }

  return HazardAssessment(
    status: status,
    confirmWeight: confirmWeight,
    clearWeight: clearWeight,
    lastActivity: lastActivity,
    expiresAt: expiresAt,
    opacity: status.isActive ? opacity : 0.0,
  );
}

/// Whether a hazard should be drawn for someone with the given preference.
bool isVisible(HazardAssessment assessment, {required bool showUnverified}) {
  return switch (assessment.status) {
    HazardStatus.verified || HazardStatus.disputed => true,
    HazardStatus.unverified => showUnverified,
    HazardStatus.cleared || HazardStatus.expired => false,
  };
}
