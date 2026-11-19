/// Holdfast: an offline survival map.
///
/// Start-up loads the long-lived stores and hands them to the widget tree
/// through `provider`.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'regions/region_store.dart';
import 'settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final regions = RegionStore();
  // Regions finish loading in the background (the server check can be slow).
  regions.load();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: regions),
      ],
      child: const HoldfastApp(),
    ),
  );
}
