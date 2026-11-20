import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../sync/sync_client.dart';
import 'hazard.dart';
import 'hazard_engine.dart';
import 'hazard_events.dart';
import 'reputation.dart';

enum SyncStatus { idle, syncing, synced, offline }

/// Owns this device's hazard event log and keeps it in sync.
///
/// * Every report and vote is appended as a [HazardEvent] and saved locally
///   first, so nothing is lost when there's no connection.
/// * Events not yet accepted by the server sit in an outbox and are pushed
///   on the next successful sync.
/// * The visible hazards are always `foldHazardEvents(log)`, recomputed on
///   change and once a minute so expiry and fade-out happen on time.
class HazardRepository extends ChangeNotifier {
  HazardRepository({required this.deviceId, this.sync, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final String deviceId;
  /// Null in tests and when running fully offline.
  final SyncClient? sync;
  final DateTime Function() _clock;
  final _uuid = const Uuid();

  static const _kLog = 'hazardLog';
  static const _kOutbox = 'hazardOutbox';
  static const _kCursor = 'hazardCursor';

  final List<HazardEvent> _log = [];
  final Set<String> _logIds = {};
  final Set<String> _outbox = {};
  int _cursor = 0;
  Map<String, Hazard> _hazards = const {};

  /// Every device's track record, rebuilt with the hazards.
  Map<String, ReporterRecord> _reputation = const {};

  /// For this device's own reports: how many other devices have confirmed
  /// each, last time we looked. A rise means someone just backed us up.
  Map<String, int>? _confirmationsSeen;

  /// The latest "thank you": other people confirmed one of this device's
  /// reports. The map shows it as a toast.
  final thanks = ValueNotifier<ThankYou?>(null);
  Timer? _syncTimer;
  Timer? _clockTimer;

  SyncStatus syncStatus = SyncStatus.idle;
  DateTime? lastSynced;

  DateTime get now => _clock();

  Iterable<Hazard> get hazards => _hazards.values;
  Hazard? byId(String id) => _hazards[id];
  /// Assesses with reputation: reliable reporters' votes count for more.
  HazardAssessment assess(Hazard hazard) =>
      assessHazard(hazard, now, reputation: (device) => weightOf(_reputation, device));

  /// A device's track record (empty for one never seen).
  ReporterRecord recordFor(String device) => _reputation[device] ?? ReporterRecord();

  ReporterRecord get myRecord => recordFor(deviceId);

  /// Publishes that this device finished every training scenario. Other
  /// devices give it a small, capped head start (see [ReporterRecord]).
  Future<void> publishTrainingCredential(List<String> scenarios) async {
    if (myRecord.trained) return;
    await _record(HazardEvent.trainingCredential(_uuid.v4(), deviceId, now.toUtc(), scenarios));
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLog);
    if (raw != null) {
      for (final item in jsonDecode(raw) as List<Object?>) {
        final event = HazardEvent.tryFromJson((item! as Map).cast<String, Object?>());
        if (event != null) _append(event);
      }
    }
    _outbox.addAll(prefs.getStringList(_kOutbox) ?? const []);
    _cursor = prefs.getInt(_kCursor) ?? 0;
    _refold();

    // Re-assess once a minute so hazards expire and fade without a restart.
    // Hazards expire and settle with time, which also moves reputations.
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _refold();
      notifyListeners();
    });
    if (sync != null) {
      unawaited(syncNow());
      _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) => syncNow());
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _clockTimer?.cancel();
    thanks.dispose();
    super.dispose();
  }

  /// Files a new report from this device and returns it.
  Future<Hazard> report({
    required HazardType type,
    required HazardSeverity severity,
    required double latitude,
    required double longitude,
    String description = '',
    Map<String, Object?> details = const {},
  }) async {
    final hazard = Hazard(
      id: _uuid.v4(),
      type: type,
      severity: severity,
      latitude: latitude,
      longitude: longitude,
      description: description.trim(),
      reportedBy: deviceId,
      reportedAt: now.toUtc(),
      details: details,
    );
    await _record(HazardEvent.report(_uuid.v4(), hazard));
    return hazard;
  }

  /// Records this device's "still there" or "it's gone" vote.
  Future<void> vote(String hazardId, VoteKind kind, {double? distanceMeters}) => _record(
        HazardEvent.vote(
          _uuid.v4(),
          hazardId,
          HazardVote(deviceId: deviceId, kind: kind, at: now.toUtc(), distanceMeters: distanceMeters),
        ),
      );

  /// The latest vote this device cast on a hazard, if any.
  VoteKind? myVote(Hazard hazard) {
    HazardVote? latest;
    for (final vote in hazard.votes) {
      if (vote.deviceId == deviceId && (latest == null || vote.at.isAfter(latest.at))) latest = vote;
    }
    return latest?.kind;
  }

  /// Adds a few realistic, already-confirmed hazards around a point so the
  /// map can be demonstrated without waiting for real reports. Demo events
  /// stay on this device: they never enter the outbox.
  Future<void> addDemoHazards(double latitude, double longitude) async {
    final random = math.Random();
    final samples = [
      (HazardType.flood, HazardSeverity.high, 'Water over the road, about knee deep.'),
      (HazardType.fire, HazardSeverity.extreme, 'Smoke visible from the highway.'),
      (HazardType.roadBlocked, HazardSeverity.moderate, 'Trees down across both lanes.'),
      (HazardType.powerLines, HazardSeverity.high, 'Lines sparking near the intersection.'),
      (HazardType.gasLeak, HazardSeverity.moderate, 'Strong smell of gas.'),
    ];
    for (final (i, (type, severity, text)) in samples.indexed) {
      final angle = i * 2 * math.pi / samples.length + random.nextDouble() * 0.5;
      final distance = 0.012 + random.nextDouble() * 0.03; // ~1–4 km
      final reportedAt = now.toUtc().subtract(Duration(minutes: 20 + random.nextInt(90)));
      final hazard = Hazard(
        id: _uuid.v4(),
        type: type,
        severity: severity,
        latitude: latitude + math.sin(angle) * distance,
        longitude: longitude + math.cos(angle) * distance * 1.4,
        description: text,
        reportedBy: 'demo-reporter-$i',
        reportedAt: reportedAt,
      );
      await _record(HazardEvent.report(_uuid.v4(), hazard), outbox: false);
      // The last sample stays unverified so the dashed style shows too.
      final confirmations = i == samples.length - 1 ? 1 : 2;
      for (var c = 0; c < confirmations; c++) {
        await _record(
          HazardEvent.vote(
            _uuid.v4(),
            hazard.id,
            HazardVote(
              deviceId: 'demo-witness-$i-$c',
              kind: VoteKind.confirm,
              at: reportedAt.add(Duration(minutes: 5 + c * 7)),
              distanceMeters: 300,
            ),
          ),
          outbox: false,
        );
      }
    }
  }

  /// Pushes the outbox, then pulls everything new. Failures just mark the
  /// status offline; the outbox keeps the events for next time.
  Future<void> syncNow() async {
    final sync = this.sync;
    if (sync == null || syncStatus == SyncStatus.syncing) return;
    syncStatus = SyncStatus.syncing;
    notifyListeners();
    try {
      final pending = [for (final e in _log) if (_outbox.contains(e.id)) e];
      await sync.push(pending);
      _outbox.removeAll(pending.map((e) => e.id));

      final pulled = await sync.pull(_cursor);
      pulled.events.forEach(_append);
      _cursor = pulled.cursor;
      _refold();
      await _save();
      syncStatus = SyncStatus.synced;
      lastSynced = now;
    } catch (_) {
      syncStatus = SyncStatus.offline;
    }
    notifyListeners();
  }

  Future<void> _record(HazardEvent event, {bool outbox = true}) async {
    _append(event);
    if (outbox) _outbox.add(event.id);
    _refold();
    notifyListeners();
    await _save();
    if (outbox) unawaited(syncNow());
  }

  void _append(HazardEvent event) {
    if (_logIds.add(event.id)) _log.add(event);
  }

  void _refold() {
    _hazards = foldHazardEvents(_log);
    _reputation = computeReputation(_hazards.values, now, trained: trainedDevices(_log));
    _noticeNewConfirmations();
  }

  /// Raises [thanks] when other devices newly confirm one of our reports.
  /// The first pass only records the counts, so history never toasts.
  void _noticeNewConfirmations() {
    final counts = {
      for (final h in _hazards.values)
        if (h.reportedBy == deviceId)
          h.id: h.votes
              .where((v) => v.kind == VoteKind.confirm && v.deviceId != deviceId)
              .map((v) => v.deviceId)
              .toSet()
              .length,
    };
    final seen = _confirmationsSeen;
    _confirmationsSeen = counts;
    if (seen == null) return;
    for (final MapEntry(key: id, value: count) in counts.entries) {
      final before = seen[id] ?? 0;
      if (count > before) {
        thanks.value = ThankYou(hazard: _hazards[id]!, confirmations: count, multiplier: myRecord.multiplier);
      }
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    // Drop events for hazards that ended more than 60 days ago, so the local
    // log can't grow forever. Settled hazards are kept that long because
    // reporters' reputations are built from them. The server keeps the
    // full history.
    final cutoff = now.subtract(const Duration(days: 60));
    final stale = {
      for (final hazard in _hazards.values)
        if (!assess(hazard).status.isActive && assess(hazard).expiresAt.isBefore(cutoff)) hazard.id,
    };
    final keep = [for (final e in _log) if (!stale.contains(e.hazardId)) e.toJson()];
    await prefs.setString(_kLog, jsonEncode(keep));
    await prefs.setStringList(_kOutbox, _outbox.toList());
    await prefs.setInt(_kCursor, _cursor);
  }
}

/// Other people confirmed one of this device's reports.
class ThankYou {
  const ThankYou({required this.hazard, required this.confirmations, required this.multiplier});

  final Hazard hazard;

  /// How many other devices have now confirmed it.
  final int confirmations;

  /// This device's current vote weight, to show the reward.
  final double multiplier;
}
