import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../pois/poi.dart';
import '../theme/motion.dart';
import 'favorites_store.dart';

/// Stars or unstars one place.
///
/// The button listens to [FavoritesStore] itself instead of relying on its
/// parent to rebuild. That matters inside Material's search view, which
/// only rebuilds its suggestions when the query text changes: without this,
/// a tapped star would not fill in until the next keystroke.
class StarButton extends StatelessWidget {
  const StarButton({super.key, required this.poi});

  final Poi poi;

  @override
  Widget build(BuildContext context) {
    final store = context.read<FavoritesStore>();
    final scheme = Theme.of(context).colorScheme;
    final animate = Motion.enabled(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final starred = store.isStarred(poi.id);
        final icon = Icon(
          starred ? Icons.star_rounded : Icons.star_outline_rounded,
          // Keyed by state so the switcher sees a new child and plays the pop.
          key: ValueKey(starred),
          color: starred ? scheme.primary : null,
        );
        return IconButton(
          tooltip: starred ? 'Remove from starred places' : 'Star this place',
          onPressed: () => store.toggleStar(poi),
          icon: animate
              ? AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                    child: child,
                  ),
                  child: icon,
                )
              : icon,
        );
      },
    );
  }
}
