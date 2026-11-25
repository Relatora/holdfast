/// Ranks and achievements for people who report hazards. Pure rules over a
/// [ReporterRecord] and training progress, so they are unit-tested and the
/// same on every device.
///
/// The point is to say thank you: reporting takes effort and some courage,
/// and the badges mark what that effort did for others ("Confirmed by 10
/// people"), not how often someone tapped a button.
library;

import 'package:material_ui/material_ui.dart';

import '../hazards/reputation.dart';

/// A reporter's rank, from their track record.
enum Tier {
  observer('Observer', 'Every reporter starts here.', Icons.visibility_rounded, Color(0xFF78909C)),
  scout('Scout', '3 reports that held up, or finished training.', Icons.explore_rounded, Color(0xFF43A047)),
  sentinel('Sentinel', '10 reports that held up, counting 1.3× or more.', Icons.shield_rounded, Color(0xFF1E88E5)),
  guardian('Guardian', '25 reports that held up, counting 1.6× or more.', Icons.workspace_premium_rounded, Color(0xFFFFB300));

  const Tier(this.label, this.requirement, this.icon, this.color);
  final String label;
  final String requirement;
  final IconData icon;
  final Color color;

  static Tier of(ReporterRecord r) {
    if (r.goodReports >= 25 && r.multiplier >= 1.6) return guardian;
    if (r.goodReports >= 10 && r.multiplier >= 1.3) return sentinel;
    if (r.goodReports >= 3 || r.trained) return scout;
    return observer;
  }

  Tier? get next => this == guardian ? null : values[index + 1];
}

/// What an achievement is judged on.
class AchievementInput {
  const AchievementInput({required this.record, required this.reportsMade, required this.trainingStars});

  final ReporterRecord record;

  /// Reports this device has filed, settled or not.
  final int reportsMade;

  /// Stars per training scenario completed (0-3), by scenario id.
  final Map<String, int> trainingStars;
}

class Achievement {
  const Achievement({
    required this.id,
    required this.title,
    required this.howTo,
    required this.icon,
    required this.unlocked,
  });

  /// Stable id, stored to remember which unlocks have been celebrated.
  final String id;
  final String title;

  /// How to earn it, shown while it's locked.
  final String howTo;
  final IconData icon;
  final bool Function(AchievementInput input) unlocked;
}

/// Number of training scenarios; kept here so the badge rule doesn't depend
/// on the training UI.
int trainingScenarioCount = 9;

final achievements = <Achievement>[
  Achievement(
    id: 'firstReport',
    title: 'First report',
    howTo: 'Report a hazard you can see.',
    icon: Icons.campaign_rounded,
    unlocked: (i) => i.reportsMade >= 1,
  ),
  Achievement(
    id: 'firstConfirmed',
    title: 'Backed up',
    howTo: 'Have a report confirmed by someone else.',
    icon: Icons.handshake_rounded,
    unlocked: (i) => i.record.confirmationsReceived >= 1,
  ),
  Achievement(
    id: 'heldUp5',
    title: 'Reliable eyes',
    howTo: '5 reports that held up.',
    icon: Icons.verified_rounded,
    unlocked: (i) => i.record.goodReports >= 5,
  ),
  Achievement(
    id: 'heldUp25',
    title: 'Lookout',
    howTo: '25 reports that held up.',
    icon: Icons.travel_explore_rounded,
    unlocked: (i) => i.record.goodReports >= 25,
  ),
  Achievement(
    id: 'heldUp100',
    title: 'Beacon',
    howTo: '100 reports that held up.',
    icon: Icons.lightbulb_rounded,
    unlocked: (i) => i.record.goodReports >= 100,
  ),
  Achievement(
    id: 'confirmedBy10',
    title: 'Trusted voice',
    howTo: 'Have your reports confirmed by 10 people in all.',
    icon: Icons.groups_rounded,
    unlocked: (i) => i.record.confirmationsReceived >= 10,
  ),
  Achievement(
    id: 'goodVotes10',
    title: 'Second pair of eyes',
    howTo: '10 votes on other reports that turned out right.',
    icon: Icons.fact_check_rounded,
    unlocked: (i) => i.record.goodVotes >= 10,
  ),
  Achievement(
    id: 'firstTraining',
    title: 'Drill done',
    howTo: 'Finish any training scenario.',
    icon: Icons.school_rounded,
    unlocked: (i) => i.trainingStars.values.any((s) => s > 0),
  ),
  Achievement(
    id: 'trained',
    title: 'Trained responder',
    howTo: 'Finish every training scenario.',
    icon: Icons.military_tech_rounded,
    unlocked: (i) => i.trainingStars.values.where((s) => s > 0).length >= trainingScenarioCount,
  ),
  Achievement(
    id: 'allStars',
    title: 'Ready for anything',
    howTo: 'Three stars on every training scenario.',
    icon: Icons.stars_rounded,
    unlocked: (i) =>
        i.trainingStars.length >= trainingScenarioCount && i.trainingStars.values.every((s) => s >= 3),
  ),
];
