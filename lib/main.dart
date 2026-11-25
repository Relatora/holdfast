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
import 'favorites/favorites_store.dart';
import 'hazards/hazard_repository.dart';
import 'net/network_gate.dart';
import 'location/cell_pack.dart';
import 'location/locator.dart';
import 'location/tower_locator.dart';
import 'notify/notifications.dart';
import 'regions/region_files.dart';
import 'regions/region_store.dart';
import 'regions/regions_screen.dart';
import 'regions/update_watcher.dart';
import 'reputation/my_reporting_screen.dart';
import 'settings/app_settings.dart';
import 'sync/sync_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await AppSettings.load();
  final favorites = await FavoritesStore.load();

  // Every HTTP client goes through the gate, so offline mode really means
  // no network. The setting drives the gate for the app's whole life.
  final network = NetworkGate(online: !settings.offlineMode);
  settings.addListener(() => network.online = !settings.offlineMode);

  final regions = RegionStore(
    files: RegionFiles(newClient: () => GatedClient(network)),
    client: GatedClient(network),
    network: network,
  );
  final hazards = HazardRepository(
    deviceId: settings.deviceId,
    sync: SyncClient(Config.serverUrl, client: GatedClient(network)),
    network: network,
  );
  // Tapping a notification opens the screen it is about, including one
  // that launched the app (before the navigator exists: retry after the
  // first frame).
  final navigator = GlobalKey<NavigatorState>();
  void open(NoticeKind kind) {
    final state = navigator.currentState;
    if (state == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => open(kind));
      return;
    }
    state.push(MaterialPageRoute<void>(
      builder: (_) => switch (kind) {
        NoticeKind.mapUpdates => const RegionsScreen(),
        NoticeKind.thanks => const MyReportingScreen(),
      },
    ));
  }

  final notifications = await SystemNotifications.start(onTap: open);

  // Where you are: GPS first; when it can't get a fix, the towers the phone
  // hears, placed with the downloaded maps' tower packs. Read from the
  // device only: positioning must never wait on the network.
  final locator = DeviceLocator()
    ..addRoughSource(TowerLocator(loadPacks: () async {
      final packs = <CellPack>[];
      for (final region in regions.readyRegions) {
        try {
          if (await regions.files.readPack(region.id, SidePack.cells) case final bytes?) {
            packs.add(CellPack.decode(bytes));
          }
        } on Object catch (error) {
          debugPrint('Cell-tower pack for ${region.id} unreadable: $error');
        }
      }
      return packs;
    }).locate);

  // Regions finish loading in the background (the server check can be
  // slow); the home screen shows the map as soon as local state is ready.
  regions.load();
  await hazards.load();
  UpdateWatcher(regions: regions, settings: settings, notifications: notifications).start();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: network),
        ChangeNotifierProvider.value(value: favorites),
        ChangeNotifierProvider.value(value: regions),
        ChangeNotifierProvider.value(value: hazards),
        // One locator for the whole app, so the dot survives screen changes.
        ChangeNotifierProvider.value(value: locator),
        Provider<Notifications>.value(value: notifications),
      ],
      child: HoldfastApp(navigatorKey: navigator),
    ),
  );
}
