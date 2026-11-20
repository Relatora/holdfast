import 'dart:math' as math;

import 'package:flutter_animate/flutter_animate.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../hazards/hazard.dart';
import '../hazards/hazard_repository.dart';
import '../home/home_screen.dart';
import '../regions/region_store.dart';
import '../settings/app_settings.dart';
import '../theme/motion.dart';
import 'scenario.dart';
import 'scenarios.dart';
import 'training_controller.dart';

/// The training hub: every scenario, the player's best stars, and a start
/// button. Practice before you need it.
class TrainingScreen extends StatelessWidget {
  const TrainingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final regions = context.watch<RegionStore>();
    final theme = Theme.of(context);
    final stars = settings.trainingStars;
    final finished = stars.values.where((s) => s > 0).length;
    final region = regions.activeRegion;

    return Scaffold(
      appBar: AppBar(title: const Text('Training')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            "Practise before you need it. Each scenario plays out on your own map with pretend "
            'reports from pretend neighbours: nothing you do here is real, and nothing is sent anywhere.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: finished / scenarios.length,
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
            // The theme's default track is close to the amber fill, which
            // made "0 of 8" look complete.
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 6),
          Text(
            '$finished of ${scenarios.length} done. Finishing them all earns "Trained responder" '
            'and gives your reports a small head start.',
            style: theme.textTheme.bodySmall,
          ),
          if (region == null)
            const Card(
              margin: EdgeInsets.only(top: 16),
              child: ListTile(
                leading: Icon(Icons.map_outlined),
                title: Text('Download a map first'),
                subtitle: Text('Scenarios are set on your map, around its centre.'),
              ),
            ),
          const SizedBox(height: 12),
          for (final scenario in scenarios)
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Icon(scenario.icon)),
                title: Text(scenario.title),
                subtitle: Text(scenario.briefing, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: _Stars(stars[scenario.id] ?? 0),
                onTap: region == null
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => TrainingRunScreen(scenario: scenario, center: region.center),
                        )),
              ),
            ),
        ],
      ),
    );
  }
}

class _Stars extends StatelessWidget {
  const _Stars(this.count, {this.size = 20});
  final int count;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Icon(
              i < count ? Icons.star_rounded : Icons.star_outline_rounded,
              size: size,
              color: i < count ? const Color(0xFFFFB300) : Theme.of(context).colorScheme.outline,
            ),
        ],
      );
}

/// One scenario in progress: the normal map, running on a sandbox, under a
/// banner that never lets you forget it's practice.
class TrainingRunScreen extends StatefulWidget {
  const TrainingRunScreen({super.key, required this.scenario, required this.center});

  final Scenario scenario;
  final LatLng center;

  @override
  State<TrainingRunScreen> createState() => _TrainingRunScreenState();
}

class _TrainingRunScreenState extends State<TrainingRunScreen> {
  late final TrainingController _controller;
  late final Set<HazardCategory> _filterBefore;
  bool _started = false;
  bool _showObjectives = true;
  bool _reportedResult = false;

  static const _bannerHeight = 48.0;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppSettings>();
    // The hazard filter is a real preference; put it back afterwards.
    _filterBefore = settings.hazardCategories;
    _controller = TrainingController(
      scenario: widget.scenario,
      center: widget.center,
      playerId: settings.deviceId,
    );
    _controller.notices.addListener(_onNotice);
    _controller.addListener(_onProgress);
  }

  @override
  void dispose() {
    // Restore after this frame: changing a setting notifies listeners, which
    // isn't allowed while the tree is being torn down.
    final settings = context.read<AppSettings>();
    final before = _filterBefore;
    WidgetsBinding.instance.addPostFrameCallback((_) => settings.hazardCategories = before);
    _controller.notices.removeListener(_onNotice);
    _controller.removeListener(_onProgress);
    _controller.dispose();
    super.dispose();
  }

  void _onNotice() {
    final notice = _controller.notices.value;
    if (notice == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('[Training] $notice'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 5),
    ));
  }

  void _onProgress() {
    if (!mounted) return;
    setState(() {});
    if (_controller.finished && !_reportedResult) {
      _reportedResult = true;
      _recordResult();
      _showResult();
    }
  }

  Future<void> _recordResult() async {
    final settings = context.read<AppSettings>();
    final realRepo = context.read<HazardRepository>();
    if (_controller.stars > 0) settings.recordTraining(widget.scenario.id, _controller.stars);
    final all = settings.trainingStars;
    final complete = scenarios.every((s) => (all[s.id] ?? 0) > 0);
    if (complete) await realRepo.publishTrainingCredential([for (final s in scenarios) s.id]);
  }

  Future<void> _start() async {
    setState(() => _started = true);
    await _controller.start();
  }

  Future<void> _showResult() async {
    final again = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ResultDialog(controller: _controller),
    );
    if (!mounted) return;
    if (again == true) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => TrainingRunScreen(scenario: widget.scenario, center: widget.center),
      ));
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (!_started) return _Briefing(scenario: widget.scenario, onStart: _start);

    return Scaffold(
      body: Stack(
        children: [
          // The real map screen, fed by the sandbox and pushed down below
          // the banner. It gets its own Navigator *under* the sandbox
          // provider: bottom sheets (report, details, hazards list) open on
          // the nearest Navigator and inherit from its context, so with the
          // app's root Navigator they would read the real repository, and
          // practice reports would land on the real map.
          MediaQuery(
            data: media.copyWith(padding: media.padding.copyWith(top: media.padding.top + _bannerHeight)),
            child: ChangeNotifierProvider<HazardRepository>.value(
              value: _controller.sandbox,
              child: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const HomeScreen(training: true)),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: scheme.tertiaryContainer,
              elevation: 4,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: _bannerHeight,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.school_rounded, color: scheme.onTertiaryContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Training: nothing here is real. ${widget.scenario.title}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text(
                        '${_controller.elapsed.inMinutes}:${(_controller.elapsed.inSeconds % 60).toString().padLeft(2, '0')}',
                        style: TextStyle(
                          color: scheme.onTertiaryContainer,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      IconButton(
                        tooltip: _showObjectives ? 'Hide objectives' : 'Show objectives',
                        onPressed: () => setState(() => _showObjectives = !_showObjectives),
                        icon: Badge(
                          label: Text('${_controller.done.length}/${widget.scenario.objectives.length}'),
                          child: Icon(Icons.checklist_rounded, color: scheme.onTertiaryContainer),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Finish now',
                        onPressed: _controller.finish,
                        icon: Icon(Icons.flag_rounded, color: scheme.onTertiaryContainer),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Objectives float on the left, below the search bar and chips,
          // so they never cover the controls they ask you to use.
          if (_showObjectives)
            Positioned(
              top: media.padding.top + _bannerHeight + 112,
              left: 12,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: math.min(380, media.size.width - 90)),
                child: Material(
                  color: scheme.tertiaryContainer.withValues(alpha: 0.94),
                  elevation: 3,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (i, objective) in widget.scenario.objectives.indexed)
                          _ObjectiveRow(text: objective.text, done: _controller.done.contains(i)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ObjectiveRow extends StatelessWidget {
  const _ObjectiveRow({required this.text, required this.done});
  final String text;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            size: 20,
            color: done ? const Color(0xFF43A047) : scheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onTertiaryContainer,
                decoration: done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
    return done && Motion.enabled(context) ? row.animate().shake(hz: 3, duration: 300.ms) : row;
  }
}

class _Briefing extends StatelessWidget {
  const _Briefing({required this.scenario, required this.onStart});
  final Scenario scenario;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(scenario.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              Icon(scenario.icon, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(scenario.briefing, style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              Text('Your objectives', style: theme.textTheme.titleSmall),
              for (final o in scenario.objectives)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.radio_button_unchecked_rounded),
                  title: Text(o.text),
                ),
              const SizedBox(height: 8),
              Text(
                'Three stars for finishing everything within ${scenario.par.inMinutes} min '
                '${scenario.par.inSeconds % 60 == 0 ? '' : '${scenario.par.inSeconds % 60} s'}. '
                'Pretend reports will arrive as notifications marked [Training].',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(onPressed: onStart, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Start')),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultDialog extends StatelessWidget {
  const _ResultDialog({required this.controller});
  final TrainingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scenario = controller.scenario;
    final animate = Motion.enabled(context);
    Widget stars = _Stars(controller.stars, size: 40);
    if (animate) stars = stars.animate().scale(begin: const Offset(0.4, 0.4), duration: 500.ms, curve: Curves.elasticOut);
    return AlertDialog(
      icon: Icon(scenario.icon),
      title: Text(controller.stars > 0 ? 'Scenario complete' : 'Not quite'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            stars,
            const SizedBox(height: 8),
            Text(
              '${controller.done.length} of ${scenario.objectives.length} objectives · ${controller.score} points · '
              '${controller.elapsed.inMinutes} min ${controller.elapsed.inSeconds % 60} s',
            ),
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Prepare before it happens', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(scenario.lesson),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Try again')),
        FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Done')),
      ],
    );
  }
}
