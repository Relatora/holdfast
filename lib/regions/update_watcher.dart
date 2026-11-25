import 'dart:async';

import 'package:flutter/foundation.dart';

import '../notify/notifications.dart';
import '../settings/app_settings.dart';
import 'region.dart';
import 'region_store.dart';

/// A notification to send about newer maps.
@immutable
class UpdateNotice {
  const UpdateNotice({required this.title, required this.body, required this.keys});

  final String title;
  final String body;

  /// The builds it announces (`RegionStore.updateKey`s).
  final List<String> keys;
}

/// Watches for newer builds of the maps on this device and tells the user,
/// as often as they chose in Settings.
///
/// It asks the server at start-up and every [interval] while the app runs
/// (the region store skips that in offline mode), and decides after every
/// change whether a notification is due. There is no background service:
/// a phone that never opens the app is never woken for a map.
class UpdateWatcher {
  UpdateWatcher({
    required this.regions,
    required this.settings,
    required this.notifications,
    this.interval = const Duration(hours: 6),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RegionStore regions;
  final AppSettings settings;
  final Notifications notifications;
  final Duration interval;
  final DateTime Function() _clock;

  Timer? _timer;

  /// Maps on the device at the last change, or null until the store has
  /// loaded: maps already there at start-up are not "arriving".
  int? _readyBefore;

  /// A permission request still waiting for the user's answer. Android
  /// drops a notification posted before permission is granted, so
  /// notifications wait for it.
  Future<bool>? _permission;

  void start() {
    regions.addListener(_onRegionsChanged);
    _timer = Timer.periodic(interval, (_) => regions.refreshHosted());
    _onRegionsChanged();
  }

  void dispose() {
    _timer?.cancel();
    regions.removeListener(_onRegionsChanged);
  }

  void _onRegionsChanged() {
    if (!regions.loaded) return;
    final ready = regions.readyRegions.length;
    // The first map just arrived: now there is something worth being told
    // about, which makes this the moment to ask (once) for permission.
    if (_readyBefore == 0 && ready > 0) _askPermissionOnce();
    _readyBefore = ready;
    unawaited(_notifyIfDue());
  }

  void _askPermissionOnce() {
    if (settings.notificationPermissionAsked) return;
    settings.notificationPermissionAsked = true;
    _permission = notifications.requestPermission().whenComplete(() => _permission = null);
  }

  bool _sending = false;

  Future<void> _notifyIfDue() async {
    if (_sending) return;
    final waiting = [
      for (final region in regions.updatable)
        if (regions.updateKey(region) case final key?) (key: key, region: region),
    ];
    final now = _clock();
    final notice = decide(
      waiting: waiting,
      announced: settings.announcedUpdates,
      lastNotice: settings.lastUpdateNotice,
      frequency: settings.updateNotices,
      now: now,
    );
    if (notice == null) return;
    _sending = true;
    try {
      // Recorded first: a notification that fails to show is not retried
      // every time the store changes.
      settings.recordUpdateNotice(notice.keys, now, keep: {for (final w in waiting) w.key});
      // Someone who had maps before this version never saw the first map
      // arrive; a newer map is the next moment that explains the request.
      _askPermissionOnce();
      if (_permission case final pending?) await pending;
      await notifications.show(NoticeKind.mapUpdates, title: notice.title, body: notice.body);
    } finally {
      _sending = false;
    }
  }

  /// Whether to notify now, and what to say. Pure, so the rules are easy
  /// to test:
  ///
  /// * Each build is announced once ([announced] holds those that were).
  /// * [UpdateNoticeFrequency.everyUpdate] announces new builds at once.
  /// * The summaries wait until [UpdateNoticeFrequency.minGap] has passed
  ///   since the last notification, then cover everything not yet
  ///   announced in one notification.
  /// * [UpdateNoticeFrequency.never] never notifies; the in-app badges
  ///   still show.
  static UpdateNotice? decide({
    required List<({String key, Region region})> waiting,
    required Set<String> announced,
    required DateTime? lastNotice,
    required UpdateNoticeFrequency frequency,
    required DateTime now,
  }) {
    if (frequency == UpdateNoticeFrequency.never) return null;
    final fresh = [for (final w in waiting) if (!announced.contains(w.key)) w];
    if (fresh.isEmpty) return null;
    if (frequency.minGap case final gap? when lastNotice != null && now.difference(lastNotice) < gap) {
      return null;
    }
    final names = [for (final w in fresh) w.region.name];
    final title = switch (names.length) {
      1 => 'Newer map for ${names[0]}',
      2 => 'Newer maps for ${names[0]} and ${names[1]}',
      _ => 'Newer maps for ${names.length} of your maps',
    };
    return UpdateNotice(
      title: title,
      body: 'Update in Holdfast to have the latest roads and places before you need them. '
          'Your current maps keep working until then.',
      keys: [for (final w in fresh) w.key],
    );
  }
}
