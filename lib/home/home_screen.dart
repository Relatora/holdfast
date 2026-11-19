import 'package:material_ui/material_ui.dart';

import '../map/topo_background.dart';
import '../theme/motion.dart';
import '../theme/theme_toggle_button.dart';

/// Placeholder home: the contour background and the theme toggle, so the
/// theme system can be exercised before the map arrives.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          TopoBackground(animate: Motion.enabled(context)),
          Center(child: Text('Holdfast', style: Theme.of(context).textTheme.displaySmall)),
          const SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(padding: EdgeInsets.all(12), child: ThemeToggleButton()),
            ),
          ),
        ],
      ),
    );
  }
}
