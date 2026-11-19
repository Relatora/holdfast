import 'dart:ui' as ui;

import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../settings/app_settings.dart';
import '../theme/motion.dart';

/// What the person chose when the carousel closed.
enum OnboardingResult { chooseMaps, later }

/// Shows the welcome flashcards over a blurred app. Resolves to
/// [OnboardingResult.chooseMaps] when the person taps "Choose maps".
Future<OnboardingResult> showOnboarding(BuildContext context) async {
  final result = await showGeneralDialog<OnboardingResult>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black26,
    transitionDuration: const Duration(milliseconds: 420),
    pageBuilder: (_, _, _) => const OnboardingCarousel(),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8 * curved.value, sigmaY: 8 * curved.value),
        child: FadeTransition(
          opacity: curved,
          child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(curved), child: child),
        ),
      );
    },
  );
  return result ?? OnboardingResult.later;
}

class _Card {
  const _Card(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}

const _cards = [
  _Card(
    Icons.wifi_off_rounded,
    'Maps that work with no signal',
    'Download a region once. Search, find supplies and see hazards with no '
        'internet at all. GPS keeps working without a connection.',
  ),
  _Card(
    Icons.inventory_2_rounded,
    'Find supplies fast',
    'Big-box stores, groceries, hardware, pharmacies, drinking water, fuel '
        'and shelters, sorted by what you need and how far away it is.',
  ),
  _Card(
    Icons.warning_amber_rounded,
    'Mark hazards, warn others',
    'Report fires, floods and blocked roads. A report shows for everyone once '
        'others confirm it, and fades away when nobody does.',
  ),
  _Card(
    Icons.cell_tower_rounded,
    'Stay connected off-grid',
    'Reports sync over Wi-Fi, cell or Starlink whenever any link is up. '
        'Phone-to-phone mesh and LoRa radio support are on the way.',
  ),
  _Card(
    Icons.download_for_offline_rounded,
    'Choose your first map',
    'Pick a city, a province, a whole country, a continent, or the entire '
        'world. Bigger regions need more space, and you can add more later.',
  ),
];

/// Five swipeable flashcards with a parallax tilt, animated page dots and a
/// "Don't show me this again" box that's saved as soon as it's ticked.
class OnboardingCarousel extends StatefulWidget {
  const OnboardingCarousel({super.key});

  @override
  State<OnboardingCarousel> createState() => _OnboardingCarouselState();
}

class _OnboardingCarouselState extends State<OnboardingCarousel> {
  final _pages = PageController(viewportFraction: 0.86);
  double _page = 0;

  @override
  void initState() {
    super.initState();
    _pages.addListener(() => setState(() => _page = _pages.page ?? 0));
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  bool get _onLast => _page.round() == _cards.length - 1;

  void _next() => _pages.nextPage(
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = context.watch<AppSettings>();
    final animate = Motion.enabled(context);

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: _cards.length,
                    itemBuilder: (context, index) {
                      // Distance from the centred page drives scale and tilt.
                      final offset = (_page - index).clamp(-1.0, 1.0);
                      return Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.0012) // perspective
                          ..rotateY(animate ? offset * -0.35 : 0)
                          ..scaleByDouble(1 - offset.abs() * 0.08, 1 - offset.abs() * 0.08, 1, 1),
                        child: _Flashcard(
                          card: _cards[index],
                          index: index,
                          active: _page.round() == index,
                          animate: animate,
                          onChooseMaps: () => Navigator.pop(context, OnboardingResult.chooseMaps),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                _Dots(count: _cards.length, page: _page, color: scheme.primary),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  // Checkbox on its own line so its label never wraps beside
                  // the wider "Choose maps" button on narrow phones.
                  child: Row(
                    children: [
                      Expanded(
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          dense: true,
                          value: settings.onboardingDismissed,
                          onChanged: (value) => settings.onboardingDismissed = value ?? false,
                          title: Text(
                            "Don't show me this again",
                            style: TextStyle(color: scheme.onSurface),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, OnboardingResult.later),
                        child: const Text('Skip'),
                      ),
                      const SizedBox(width: 4),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: _onLast
                            ? FilledButton.icon(
                                key: const ValueKey('choose'),
                                onPressed: () => Navigator.pop(context, OnboardingResult.chooseMaps),
                                icon: const Icon(Icons.map_rounded),
                                label: const Text('Choose maps'),
                              )
                            : FilledButton(
                                key: const ValueKey('next'),
                                onPressed: _next,
                                child: const Text('Next'),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Flashcard extends StatelessWidget {
  const _Flashcard({
    required this.card,
    required this.index,
    required this.active,
    required this.animate,
    required this.onChooseMaps,
  });

  final _Card card;
  final int index;
  final bool active;
  final bool animate;
  final VoidCallback onChooseMaps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isLast = index == _cards.length - 1;

    Widget icon = Container(
      width: 112,
      height: 112,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.primary.withValues(alpha: 0.14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.5), width: 2),
      ),
      child: Icon(card.icon, size: 56, color: scheme.primary),
    );
    if (animate) {
      // A slow "breathing" glow keeps the card alive without distracting.
      icon = icon
          .animate(onPlay: (c) => c.repeat(reverse: true))
          .scaleXY(begin: 1, end: 1.06, duration: 1600.ms, curve: Curves.easeInOut)
          .boxShadow(
            begin: const BoxShadow(color: Colors.transparent, blurRadius: 0),
            end: BoxShadow(color: scheme.primary.withValues(alpha: 0.35), blurRadius: 36, spreadRadius: 2),
            borderRadius: BorderRadius.circular(56),
          );
    }

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(height: 32),
        Text(
          card.title,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 14),
        Text(
          card.body,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
        ),
        if (isLast) ...[
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final label in ['City', 'Province', 'Country', 'Continent', 'World'])
                ActionChip(label: Text(label), onPressed: onChooseMaps),
            ],
          ),
        ],
      ],
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primaryContainer.withValues(alpha: 0.55), scheme.surfaceContainer],
          ),
        ),
        // Centred when it fits, scrollable when it doesn't (small phones,
        // landscape, or large accessibility text).
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: (constraints.maxHeight - 56).clamp(0, double.infinity)),
              child: Center(
                child: animate && active
                    ? content.animate(key: ValueKey(index)).fadeIn(duration: 350.ms).slideY(begin: 0.06, end: 0)
                    : content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Page indicator where the current dot stretches into a pill.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.page, required this.color});

  final int count;
  final double page;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          Builder(builder: (context) {
            final closeness = (1 - (page - i).abs()).clamp(0.0, 1.0);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: 8 + 18 * closeness,
              height: 8,
              decoration: BoxDecoration(
                color: Color.lerp(color.withValues(alpha: 0.3), color, closeness),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
      ],
    );
  }
}
