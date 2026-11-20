import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';

import '../favorites/star_button.dart';
import '../theme/motion.dart';
import 'poi.dart';
import 'poi_index.dart';

/// Details for one supply location. [onDirections], when given, adds a
/// Directions button that closes the sheet and plans a route there.
Future<void> showPlaceSheet(BuildContext context, Poi poi, {double? meters, VoidCallback? onDirections}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final rows = <(IconData, String)>[
        if (poi.address != null) (Icons.place_outlined, poi.address!),
        if (poi.tags['opening_hours'] != null) (Icons.schedule_rounded, poi.tags['opening_hours']!),
        if (poi.tags['phone'] != null) (Icons.call_outlined, poi.tags['phone']!),
        if (poi.tags['generator:source'] != null) (Icons.bolt_rounded, 'Generator: ${poi.tags['generator:source']}'),
      ];
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: poi.category.color,
                  child: Icon(poi.category.icon, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(poi.title, style: theme.textTheme.titleLarge),
                      Text([poi.category.label, if (meters != null) formatDistance(meters)].join(' · ')),
                    ],
                  ),
                ),
                StarButton(poi: poi),
              ],
            ),
            if (onDirections != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.pop(context);
                  onDirections();
                },
                icon: const Icon(Icons.directions_rounded),
                label: const Text('Directions'),
              ),
            ],
            const SizedBox(height: 12),
            for (final (icon, text) in rows)
              ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: Icon(icon), title: Text(text)),
            const SizedBox(height: 8),
            Text(
              'Crowd-reported stock and opening status is planned. Until then, '
              'treat hours as normal-day hours, which may not apply in an emergency.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    },
  );
}

/// The radar's result: the closest place of each kind, nearest first.
Future<Poi?> showNearestSheet(BuildContext context, List<PoiHit> hits) {
  return showModalBottomSheet<Poi>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      final animate = Motion.enabled(context);
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text('Nearest supplies', style: Theme.of(context).textTheme.titleLarge),
            ),
            if (hits.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No supply locations in this map yet. Download a region with a supply pack.'),
              ),
            for (final (i, hit) in hits.indexed)
              _maybeAnimate(
                animate,
                i,
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: hit.poi.category.color,
                    child: Icon(hit.poi.category.icon, color: Colors.white, size: 20),
                  ),
                  title: Text(hit.poi.title),
                  subtitle: Text(hit.poi.category.label),
                  trailing: Text(formatDistance(hit.meters), style: Theme.of(context).textTheme.titleSmall),
                  onTap: () => Navigator.pop(context, hit.poi),
                ),
              ),
          ],
        ),
      );
    },
  );
}

Widget _maybeAnimate(bool animate, int index, Widget child) => animate
    ? child.animate(delay: (50 * index).ms).fadeIn(duration: 220.ms).slideY(begin: 0.3, end: 0)
    : child;
