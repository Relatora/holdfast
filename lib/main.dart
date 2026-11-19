/// Holdfast: an offline survival map.
///
/// Start-up loads the three long-lived stores (settings, regions, hazards)
/// and hands them to the widget tree through `provider`. Each store is a
/// [ChangeNotifier], so screens rebuild exactly when the data they read
/// changes.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'config.dart';
import 'hazards/hazard_repository.dart';
import 'regions/region_store.dart';
import 'settings/app_settings.dart';
import 'sync/sync_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await AppSettings.load();
  final regions = RegionStore();
  final hazards = HazardRepository(
    deviceId: settings.deviceId,
    sync: SyncClient(Config.serverUrl),
  );
  // Regions finish loading in the background (the server check can be
  // slow); the home screen shows the map as soon as local state is ready.
  regions.load();
  await hazards.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: regions),
        ChangeNotifierProvider.value(value: hazards),
      ],
      child: const HoldfastApp(),
    ),
  );
}
