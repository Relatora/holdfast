import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../hazards/hazard_repository.dart';
import '../notify/notifications.dart';
import '../reputation/my_reporting_screen.dart';
import '../training/training_screen.dart';
import '../theme/app_theme.dart';
import '../theme/app_theme_mode.dart';
import '../theme/theme_toggle_button.dart';
import 'app_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.mapCenter, required this.onShowWelcome});

  /// Where demo hazards are placed.
  final LatLng Function() mapCenter;
  final VoidCallback onShowWelcome;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _Header('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final mode in AppThemeMode.values)
                  Expanded(child: _ThemeSwatch(mode: mode, selected: settings.themeMode == mode)),
              ],
            ),
          ),
          // The web preview streams every map from the server, so it has
          // nothing to offer offline.
          if (!kIsWeb) ...[
            const _Header('Connection'),
            SwitchListTile(
              secondary: Icon(settings.offlineMode ? Icons.airplanemode_active_rounded : Icons.wifi_rounded),
              title: const Text('Offline mode'),
              subtitle: Text(
                settings.offlineMode
                    ? 'Holdfast uses no network. Your maps work as usual; reports wait on this '
                        'device and send when you turn this off.'
                    : 'Keep Holdfast off the network entirely, to save battery or data. '
                        'Maps on this device keep working.',
              ),
              value: settings.offlineMode,
              onChanged: (value) => settings.offlineMode = value,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.public_rounded),
              title: const Text('Show the world beyond your maps'),
              subtitle: const Text(
                'Online, the map streams from Protomaps (protomaps.com) wherever you have no downloaded map, '
                'with your saved areas outlined. Saved areas always come from this device.',
              ),
              value: settings.streamWorld,
              // Offline mode streams nothing, whatever this says.
              onChanged: settings.offlineMode ? null : (value) => settings.streamWorld = value,
            ),
            ListTile(
              leading: Icon(
                settings.updateNotices == UpdateNoticeFrequency.never
                    ? Icons.notifications_off_outlined
                    : Icons.notifications_active_outlined,
              ),
              title: const Text('Map update notifications'),
              subtitle: Text(
                '${settings.updateNotices.label}. Checked when Holdfast starts and every 6 hours while it runs, '
                'never in offline mode.',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _chooseUpdateNotices(context, settings),
            ),
          ],
          const _Header('Power & motion'),
          SwitchListTile(
            secondary: const Icon(Icons.battery_saver_rounded),
            title: const Text('Battery saver'),
            subtitle: const Text('Turns off pulsing markers and other decorative animation.'),
            value: settings.batterySaver,
            onChanged: (value) => settings.batterySaver = value,
          ),
          const _Header('Hazards'),
          ListTile(
            leading: const Icon(Icons.school_rounded),
            title: const Text('Training'),
            subtitle: const Text('Practise with pretend emergencies on your own map. Nothing is real or sent.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TrainingScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.military_tech_rounded),
            title: const Text('My reporting'),
            subtitle: const Text('Your rank, how much your reports count, and achievements.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyReportingScreen())),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.air_rounded),
            title: const Text('Fetch wind for hazards'),
            subtitle: const Text(
              'When online, "Use current wind" asks Open-Meteo for the wind at a hazard, now or at a planned time. '
              'Only the hazard\'s position is sent.',
            ),
            value: settings.fetchWind,
            onChanged: (value) => settings.fetchWind = value,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.hourglass_top_rounded),
            title: const Text('Show unverified reports'),
            subtitle: const Text('Reports nobody else has confirmed yet, drawn dashed.'),
            value: settings.showUnverifiedHazards,
            onChanged: (value) => settings.showUnverifiedHazards = value,
          ),
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: const Text('Add demo hazards'),
            subtitle: const Text('Places a few sample hazards around the map centre. They stay on this device.'),
            onTap: () async {
              final center = mapCenter();
              await context.read<HazardRepository>().addDemoHazards(center.latitude, center.longitude);
              if (context.mounted) Navigator.pop(context);
            },
          ),
          const _Header('Help'),
          ListTile(
            leading: const Icon(Icons.style_rounded),
            title: const Text('Show the welcome cards'),
            onTap: () {
              settings.onboardingDismissed = false;
              Navigator.pop(context);
              onShowWelcome();
            },
          ),
          const _Header('About'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Holdfast is an open-source emergency map. Map data © OpenStreetMap '
              'contributors (ODbL). Basemaps by Protomaps. Hazard reports come from '
              'people like you and can be wrong: always follow local authorities.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Lets the user pick how often to hear about newer maps. Picking anything
/// but Never asks for notification permission where the system needs it.
Future<void> _chooseUpdateNotices(BuildContext context, AppSettings settings) async {
  final chosen = await showModalBottomSheet<UpdateNoticeFrequency>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text('Tell me about newer maps', style: Theme.of(context).textTheme.titleLarge),
          ),
          for (final option in UpdateNoticeFrequency.values)
            ListTile(
              leading: Icon(
                option == settings.updateNotices ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: option == settings.updateNotices ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(option.label),
              subtitle: Text(option.description),
              onTap: () => Navigator.pop(context, option),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (chosen == null) return;
  settings.updateNotices = chosen;
  if (chosen != UpdateNoticeFrequency.never && context.mounted) {
    settings.notificationPermissionAsked = true;
    await context.read<Notifications?>()?.requestPermission();
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}

/// A miniature preview of a palette; tapping it switches with the reveal.
class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.mode, required this.selected});

  final AppThemeMode mode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final brightness = MediaQuery.platformBrightnessOf(context);
    final preview = switch (resolveThemeMode(mode, brightness)) {
      AppThemeMode.dark => AppTheme.dark(),
      AppThemeMode.nightVision => AppTheme.nightVision(),
      _ => AppTheme.light(),
    }
        .colorScheme;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          final box = context.findRenderObject()! as RenderBox;
          switchTheme(context, mode, box.localToGlobal(box.size.center(Offset.zero)));
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2.5 : 1),
          ),
          child: Column(
            children: [
              Container(
                height: 54,
                decoration: BoxDecoration(color: preview.surface, borderRadius: BorderRadius.circular(10)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(radius: 9, backgroundColor: preview.primary),
                    const SizedBox(width: 6),
                    CircleAvatar(radius: 6, backgroundColor: preview.secondary),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(mode.label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
      ),
    );
  }
}
