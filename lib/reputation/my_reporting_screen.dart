import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../hazards/hazard_repository.dart';
import '../settings/app_settings.dart';
import '../theme/motion.dart';
import 'achievement_badge.dart';
import 'achievements.dart';

/// "My reporting": this device's rank, how much its reports count, and the
/// achievements earned so far. Newly unlocked badges pop in once.
class MyReportingScreen extends StatefulWidget {
  const MyReportingScreen({super.key});

  @override
  State<MyReportingScreen> createState() => _MyReportingScreenState();
}

class _MyReportingScreenState extends State<MyReportingScreen> {
  /// Unlocked but not yet celebrated when the screen opened.
  late final Set<String> _fresh;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppSettings>();
    final unlocked = _unlocked(context.read<HazardRepository>(), settings);
    _fresh = unlocked.difference(settings.celebratedAchievements);
    settings.markCelebrated(unlocked);
  }

  static AchievementInput _input(HazardRepository repo, AppSettings settings) => AchievementInput(
        record: repo.myRecord,
        reportsMade: repo.hazards.where((h) => h.reportedBy == repo.deviceId).length,
        trainingStars: settings.trainingStars,
      );

  static Set<String> _unlocked(HazardRepository repo, AppSettings settings) {
    final input = _input(repo, settings);
    return {for (final a in achievements) if (a.unlocked(input)) a.id};
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<HazardRepository>();
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);
    final animate = Motion.enabled(context);
    final record = repo.myRecord;
    final tier = Tier.of(record);
    final input = _input(repo, settings);
    final accuracy = record.accuracy;

    return Scaffold(
      appBar: AppBar(title: const Text('My reporting')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  AchievementBadge(icon: tier.icon, color: tier.color, size: 84, animate: animate),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tier.label, style: theme.textTheme.headlineSmall?.copyWith(color: tier.color)),
                        const SizedBox(height: 4),
                        Text('Your reports and votes count ${record.multiplier.toStringAsFixed(1)}×',
                            style: theme.textTheme.titleMedium),
                        if (tier.next case final next?) ...[
                          const SizedBox(height: 6),
                          Text('Next: ${next.label}. ${next.requirement}', style: theme.textTheme.bodySmall),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Stat(label: 'Reports that held up', value: '${record.goodReports}'),
              _Stat(label: 'Accuracy', value: accuracy == null ? '–' : '${(accuracy * 100).round()}%'),
              _Stat(label: 'Confirmed by others', value: '${record.confirmationsReceived}'),
              _Stat(label: 'Votes that were right', value: '${record.goodVotes}'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Weights come from what became of your past reports once they ended: '
            'confirmed ones raise it, false alarms lower it. Every device works it out the same way.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          Text('Achievements', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 120).floor().clamp(2, 6);
              return GridView.count(
                crossAxisCount: columns,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 0.72,
                children: [
                  for (final a in achievements)
                    _AchievementTile(
                      achievement: a,
                      unlocked: a.unlocked(input),
                      celebrate: _fresh.contains(a.id),
                      color: tier.color,
                      animate: animate,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 160,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: theme.textTheme.headlineSmall),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _AchievementTile extends StatelessWidget {
  const _AchievementTile({
    required this.achievement,
    required this.unlocked,
    required this.celebrate,
    required this.color,
    required this.animate,
  });

  final Achievement achievement;
  final bool unlocked, celebrate, animate;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: achievement.howTo,
      child: Column(
        children: [
          AchievementBadge(
            icon: achievement.icon,
            color: color,
            locked: !unlocked,
            celebrate: celebrate,
            animate: animate,
          ),
          const SizedBox(height: 6),
          Text(
            achievement.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge?.copyWith(color: unlocked ? null : theme.colorScheme.outline),
          ),
          Text(
            unlocked ? 'Earned' : achievement.howTo,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}
