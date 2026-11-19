/// Hazards travel between devices as an append-only log of small events.
///
/// Instead of syncing "the current state of hazard X", every device shares
/// the facts it knows: "device A reported a flood here at 10:02", "device B
/// confirmed it at 10:40". Folding the same set of facts always produces the
/// same hazards, in any order, with duplicates ignored. That makes sync safe
/// over flaky links: the internet, a satellite text channel, or phone-to-phone
/// mesh can each deliver events late, twice, or out of order.
library;

import 'hazard.dart';

enum HazardEventKind { report, vote }

/// One fact about one hazard.
class HazardEvent {
  const HazardEvent({
    required this.id,
    required this.kind,
    required this.hazardId,
    required this.deviceId,
    required this.at,
    required this.payload,
  });

  /// Globally unique (UUID v4). Lets every store de-duplicate cheaply.
  final String id;
  final HazardEventKind kind;
  final String hazardId;
  final String deviceId;
  final DateTime at;

  /// For [HazardEventKind.report]: the hazard's JSON without votes.
  /// For [HazardEventKind.vote]: the vote's JSON.
  final Map<String, Object?> payload;

  factory HazardEvent.report(String eventId, Hazard hazard) => HazardEvent(
        id: eventId,
        kind: HazardEventKind.report,
        hazardId: hazard.id,
        deviceId: hazard.reportedBy,
        at: hazard.reportedAt,
        payload: hazard.toJson()..remove('votes'),
      );

  factory HazardEvent.vote(String eventId, String hazardId, HazardVote vote) => HazardEvent(
        id: eventId,
        kind: HazardEventKind.vote,
        hazardId: hazardId,
        deviceId: vote.deviceId,
        at: vote.at,
        payload: vote.toJson(),
      );

  /// Latitude and longitude ride along at the top level so the server can
  /// answer "events inside this map area" without understanding payloads.
  double? get latitude => (payload['lat'] as num?)?.toDouble();
  double? get longitude => (payload['lon'] as num?)?.toDouble();

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'hazardId': hazardId,
        'deviceId': deviceId,
        'at': at.toUtc().toIso8601String(),
        if (latitude != null) 'lat': latitude,
        if (longitude != null) 'lon': longitude,
        'payload': payload,
      };

  factory HazardEvent.fromJson(Map<String, Object?> json) => HazardEvent(
        id: json['id']! as String,
        kind: HazardEventKind.values.byName(json['kind']! as String),
        hazardId: json['hazardId']! as String,
        deviceId: json['deviceId']! as String,
        at: DateTime.parse(json['at']! as String),
        payload: (json['payload']! as Map).cast<String, Object?>(),
      );
}

/// Rebuilds hazards from an unordered, possibly duplicated set of events.
///
/// * Duplicate event ids are applied once.
/// * Votes that arrive before their report are kept and attached once the
///   report shows up (common on mesh links).
/// * The result is independent of input order.
Map<String, Hazard> foldHazardEvents(Iterable<HazardEvent> events) {
  final seen = <String>{};
  final reports = <String, Hazard>{};
  final votes = <String, List<HazardVote>>{};

  for (final event in events) {
    if (!seen.add(event.id)) continue;
    switch (event.kind) {
      case HazardEventKind.report:
        // If two reports claim one id, the earliest wins on every device.
        final candidate = Hazard.fromJson({...event.payload, 'votes': const []});
        final existing = reports[event.hazardId];
        if (existing == null || candidate.reportedAt.isBefore(existing.reportedAt)) {
          reports[event.hazardId] = candidate;
        }
      case HazardEventKind.vote:
        votes.putIfAbsent(event.hazardId, () => []).add(HazardVote.fromJson(event.payload));
    }
  }

  return {
    for (final entry in reports.entries)
      entry.key: (votes[entry.key] ?? const <HazardVote>[])
          .fold(entry.value, (hazard, vote) => hazard.withVote(vote)),
  };
}
