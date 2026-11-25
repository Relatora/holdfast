import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The kinds of system notification Holdfast sends. Each kind reuses one
/// notification id, so a newer notice replaces the last instead of piling
/// up, and has its own Android channel the user can silence separately.
enum NoticeKind {
  mapUpdates(1, 'map_updates', 'Map updates', 'Newer maps for regions on this device.'),
  thanks(2, 'report_thanks', 'Thanks for reports', 'When someone confirms a hazard you reported.');

  const NoticeKind(this.id, this.channelId, this.channelName, this.channelDescription);

  final int id;
  final String channelId;
  final String channelName;
  final String channelDescription;
}

/// What the app asks of the system's notification centre. An interface so
/// tests (and the web preview) can use [NoNotifications].
abstract interface class Notifications {
  Future<void> show(NoticeKind kind, {required String title, required String body});

  /// Asks for permission where the platform requires it (Android 13+,
  /// macOS). True when notifications may be shown.
  Future<bool> requestPermission();
}

/// Shows nothing: the web preview, and tests.
class NoNotifications implements Notifications {
  const NoNotifications();

  @override
  Future<void> show(NoticeKind kind, {required String title, required String body}) async {}

  @override
  Future<bool> requestPermission() async => false;
}

/// Notifications through the operating system, via
/// `flutter_local_notifications`. They are shown while the app runs; no
/// background service wakes it up.
class SystemNotifications implements Notifications {
  SystemNotifications._(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  /// Sets the plugin up. [onTap] runs with the [NoticeKind] of a
  /// notification the user tapped, including one that launched the app.
  /// Returns [NoNotifications] where notifications aren't available.
  static Future<Notifications> start({required void Function(NoticeKind kind) onTap}) async {
    if (kIsWeb) return const NoNotifications();
    final plugin = FlutterLocalNotificationsPlugin();
    void handle(String? payload) {
      for (final kind in NoticeKind.values) {
        if (kind.name == payload) onTap(kind);
      }
    }

    try {
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // Permission is asked for later, at a moment that explains itself.
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(defaultActionName: 'Open Holdfast'),
          windows: WindowsInitializationSettings(
            appName: 'Holdfast',
            appUserModelId: 'Holdfast.Holdfast.App',
            // Identifies Holdfast's notification activator; fixed for good.
            guid: '6b3d7c1e-2f0a-4c8e-9a51-3e7f2d4b8c90',
          ),
        ),
        onDidReceiveNotificationResponse: (response) => handle(response.payload),
      );
      final launch = await plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) handle(launch!.notificationResponse?.payload);
    } catch (error) {
      // A desktop without a notification service (some Linux setups) must
      // not stop the app from starting; the in-app indicators still work.
      debugPrint('Notifications unavailable: $error');
      return const NoNotifications();
    }
    return SystemNotifications._(plugin);
  }

  @override
  Future<void> show(NoticeKind kind, {required String title, required String body}) async {
    try {
      await _plugin.show(
        id: kind.id,
        title: title,
        body: body,
        payload: kind.name,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kind.channelId,
            kind.channelName,
            channelDescription: kind.channelDescription,
            styleInformation: BigTextStyleInformation(body),
          ),
          // Desktop notices are silent (#76). Nothing Holdfast posts is
          // urgent: a newer map can wait until morning, and the default
          // chime woke someone at night. The toast still lands in the
          // notification centre. Android keeps its per-channel sound, which
          // people can change in the system settings for each kind.
          macOS: const DarwinNotificationDetails(presentSound: false),
          iOS: const DarwinNotificationDetails(),
          linux: const LinuxNotificationDetails(suppressSound: true),
          windows: WindowsNotificationDetails(audio: WindowsNotificationAudio.silent()),
        ),
      );
    } catch (error) {
      debugPrint('Notification failed: $error');
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      final android =
          _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) return await android.requestNotificationsPermission() ?? false;
      final mac = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      if (mac != null) return await mac.requestPermissions(alert: true, sound: true) ?? false;
      final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) return await ios.requestPermissions(alert: true, sound: true) ?? false;
    } catch (error) {
      debugPrint('Notification permission request failed: $error');
      return false;
    }
    return true; // Windows and Linux don't ask
  }
}
