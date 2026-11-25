/// A measured reading at a point: lead in a garden, caesium on a field, a
/// dose rate on a street. Samples share the hazard event log (kind
/// `sample`), so they sync, merge and survive mesh links the same way, and
/// others can confirm or dispute them with ordinary votes.
///
/// Unlike a hazard report, a sample is a number, not an opinion, and it
/// lasts as long as the contamination does (see [Contaminant.lifetime]).
library;

import '../hazards/hazard.dart';
import '../hazards/hazard_events.dart';
import 'contaminants.dart';

class Sample {
  const Sample({
    required this.id,
    required this.contaminant,
    required this.value,
    required this.method,
    required this.latitude,
    required this.longitude,
    required this.reportedBy,
    required this.reportedAt,
    this.takenAt,
    this.depthCm,
    this.note = '',
    this.votes = const [],
  });

  final String id;
  final Contaminant contaminant;

  /// In [Contaminant.unit].
  final double value;
  final SampleMethod method;
  final double latitude, longitude;
  final String reportedBy;
  final DateTime reportedAt;

  /// When the sample was taken, if earlier than it was added (a lab result
  /// comes back days later).
  final DateTime? takenAt;

  /// How deep the soil was taken from, in cm. Lead dust sits in the top few
  /// centimetres; a deeper sample can miss it.
  final double? depthCm;
  final String note;

  /// Others' "matches what I measured" (confirm) and "looks wrong" (clear).
  final List<HazardVote> votes;

  ContaminationLevel get level => contaminant.levelFor(value);

  /// When the reading stops being shown.
  DateTime get expiresAt => (takenAt ?? reportedAt).add(contaminant.lifetime);

  Sample withVote(HazardVote vote) => Sample(
        id: id,
        contaminant: contaminant,
        value: value,
        method: method,
        latitude: latitude,
        longitude: longitude,
        reportedBy: reportedBy,
        reportedAt: reportedAt,
        takenAt: takenAt,
        depthCm: depthCm,
        note: note,
        votes: [...votes, vote],
      );

  /// The event payload. `lat` and `lon` at the top level let the server
  /// answer "events in this map area" without reading samples.
  Map<String, Object?> toJson() => {
        'id': id,
        'contaminant': contaminant.name,
        'value': value,
        'method': method.name,
        'lat': latitude,
        'lon': longitude,
        'reportedBy': reportedBy,
        'reportedAt': reportedAt.toUtc().toIso8601String(),
        if (takenAt != null) 'takenAt': takenAt!.toUtc().toIso8601String(),
        if (depthCm != null) 'depthCm': depthCm,
        if (note.isNotEmpty) 'note': note,
      };

  /// Null for a contaminant this version doesn't know (from a newer app)
  /// or a malformed payload: one odd event never breaks the map.
  static Sample? tryFromJson(Map<String, Object?> json) {
    final contaminant = Contaminant.parse(json['contaminant']);
    final value = json['value'], lat = json['lat'], lon = json['lon'];
    final reportedAt = DateTime.tryParse(json['reportedAt'] as String? ?? '');
    if (contaminant == null || value is! num || lat is! num || lon is! num || reportedAt == null) return null;
    if (value < 0 || !value.isFinite) return null;
    return Sample(
      id: json['id'] as String? ?? '',
      contaminant: contaminant,
      value: value.toDouble(),
      method: SampleMethod.parse(json['method']),
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      reportedBy: json['reportedBy'] as String? ?? '',
      reportedAt: reportedAt,
      takenAt: DateTime.tryParse(json['takenAt'] as String? ?? ''),
      depthCm: (json['depthCm'] as num?)?.toDouble(),
      note: json['note'] as String? ?? '',
    );
  }
}

/// Rebuilds the samples from the shared event log: every `sample` event,
/// with the votes cast on it. Like the hazard fold, duplicates count once
/// and the order doesn't matter.
Map<String, Sample> foldSamples(Iterable<HazardEvent> events) {
  final seen = <String>{};
  final samples = <String, Sample>{};
  final votes = <String, List<HazardVote>>{};
  for (final event in events) {
    if (!seen.add(event.id)) continue;
    switch (event.kind) {
      case HazardEventKind.sample:
        final sample = Sample.tryFromJson({...event.payload, 'id': event.hazardId});
        final existing = samples[event.hazardId];
        if (sample != null && (existing == null || sample.reportedAt.isBefore(existing.reportedAt))) {
          samples[event.hazardId] = sample;
        }
      case HazardEventKind.vote:
        votes.putIfAbsent(event.hazardId, () => []).add(HazardVote.fromJson(event.payload));
      case HazardEventKind.report || HazardEventKind.credential:
        break;
    }
  }
  return {
    for (final MapEntry(:key, :value) in samples.entries)
      key: (votes[key] ?? const <HazardVote>[]).fold(value, (s, v) => s.withVote(v)),
  };
}

/// Whether a sample still counts, and how far to trust it.
enum SampleStatus {
  /// Nobody has disagreed.
  shown,

  /// Someone said it looks wrong; drawn faded, with a question mark.
  disputed,

  /// More (reputation-weighted) people say it's wrong than right: hidden.
  rejected,

  /// Past its lifetime.
  expired,
}

/// How [sample] stands at [now]. Each device's latest vote counts once,
/// the reporter's own votes don't count, and a vote weighs as much as its
/// device's reputation (1.0 for someone new). Two "looks wrong" votes
/// outweighing the agreements reject it.
SampleStatus assessSample(Sample sample, DateTime now, {double Function(String deviceId)? reputation}) {
  if (!now.isBefore(sample.expiresAt)) return SampleStatus.expired;
  final latest = <String, HazardVote>{};
  for (final vote in sample.votes) {
    if (vote.deviceId == sample.reportedBy || vote.at.isAfter(now)) continue;
    final previous = latest[vote.deviceId];
    if (previous == null || vote.at.isAfter(previous.at)) latest[vote.deviceId] = vote;
  }
  var agree = 0.0, disagree = 0.0;
  for (final vote in latest.values) {
    final weight = reputation?.call(vote.deviceId) ?? 1.0;
    if (vote.kind == VoteKind.confirm) {
      agree += weight;
    } else {
      disagree += weight;
    }
  }
  if (disagree >= 2 && disagree > agree) return SampleStatus.rejected;
  if (disagree > 0) return SampleStatus.disputed;
  return SampleStatus.shown;
}
