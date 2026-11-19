/// Holdfast: an offline survival map.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(ChangeNotifierProvider.value(value: settings, child: const HoldfastApp()));
}
