import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../map/hazard_marker.dart';
import '../theme/motion.dart';
import 'hazard.dart';
import 'hazard_engine.dart';
import 'hazard_repository.dart';

/// Bottom sheet for reporting a hazard at a map position.
Future<void> showReportHazardSheet(BuildContext context, {required double latitude, required double longitude}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ReportHazardSheet(latitude: latitude, longitude: longitude),
  );
}

class _ReportHazardSheet extends StatefulWidget {
  const _ReportHazardSheet({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  @override
  State<_ReportHazardSheet> createState() => _ReportHazardSheetState();
}

class _ReportHazardSheetState extends State<_ReportHazardSheet> {
  HazardType? _type;
  HazardSeverity _severity = HazardSeverity.moderate;
  final _details = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final type = _type;
    if (type == null) return;
    setState(() => _sending = true);
    await context.read<HazardRepository>().report(
          type: type,
          severity: _severity,
          latitude: widget.latitude,
          longitude: widget.longitude,
          description: _details.text,
        );
    await HapticFeedback.mediumImpact();
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reported. It will show for everyone once others nearby confirm it.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final animate = Motion.enabled(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Report a hazard', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'At ${widget.latitude.toStringAsFixed(5)}, ${widget.longitude.toStringAsFixed(5)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (i, type) in HazardType.values.indexed)
                _staggered(animate, i, ChoiceChip(
                  avatar: Icon(type.icon, color: type.color, size: 18),
                  label: Text(type.label),
                  selected: _type == type,
                  onSelected: (_) {
                    HapticFeedback.selectionClick();
                    setState(() => _type = type);
                  },
                )),
            ],
          ),
          const SizedBox(height: 20),
          Text('How serious?', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<HazardSeverity>(
            segments: [
              for (final s in HazardSeverity.values) ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {_severity},
            onSelectionChanged: (s) => setState(() => _severity = s.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _details,
            maxLength: 280,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'What do you see? (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _type == null || _sending ? null : _submit,
              icon: const Icon(Icons.campaign_rounded),
              label: Text(_type == null ? 'Choose a hazard type' : 'Report ${_type!.label.toLowerCase()}'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pops the hazard-type chips in one after another (skipped in reduced motion).
Widget _staggered(bool animate, int index, Widget child) => animate
    ? child.animate(delay: (25 * index).ms).fadeIn(duration: 200.ms).scaleXY(begin: 0.9, end: 1)
    : child;

/// Bottom sheet showing a hazard's status, time left and vote buttons.
Future<void> showHazardDetailsSheet(BuildContext context, String hazardId) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => _HazardDetailsSheet(hazardId: hazardId),
  );
}

class _HazardDetailsSheet extends StatelessWidget {
  const _HazardDetailsSheet({required this.hazardId});

  final String hazardId;

  static String _ago(Duration d) {
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  static String _left(Duration d) {
    if (d.inHours < 1) return '${d.inMinutes} min';
    if (d.inDays < 1) return '${d.inHours} h ${d.inMinutes % 60} min';
    return '${d.inDays} d ${d.inHours % 24} h';
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<HazardRepository>();
    final hazard = repo.byId(hazardId);
    if (hazard == null) return const SizedBox(height: 120);
    final assessment = repo.assess(hazard);
    final theme = Theme.of(context);
    final mine = hazard.reportedBy == repo.deviceId;
    final myVote = repo.myVote(hazard);

    final (statusLabel, statusIcon) = switch (assessment.status) {
      HazardStatus.unverified => ('Unverified: needs confirmation', Icons.hourglass_top_rounded),
      HazardStatus.verified => (hazard.official ? 'Official source' : 'Verified by people nearby', Icons.verified_rounded),
      HazardStatus.disputed => ('Disputed: someone says it is gone', Icons.help_outline_rounded),
      HazardStatus.cleared => ('Cleared', Icons.check_circle_outline_rounded),
      HazardStatus.expired => ('Expired', Icons.history_rounded),
    };

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
                backgroundColor: hazard.type.color,
                child: Icon(hazard.type.icon, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(hazard.type.label, style: theme.textTheme.titleLarge),
                    Text('${hazard.severity.label} severity · reported ${_ago(repo.now.difference(hazard.reportedAt))}'),
                  ],
                ),
              ),
            ],
          ),
          if (hazard.description.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('"${hazard.description}"', style: theme.textTheme.bodyLarge),
          ],
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(statusIcon),
            title: Text(statusLabel),
            subtitle: Text(
              '${assessment.confirmWeight.toStringAsFixed(1)} confirmations · '
              '${assessment.clearWeight.toStringAsFixed(1)} "gone" votes · '
              'expires in ${_left(assessment.remaining(repo.now))} unless confirmed',
            ),
          ),
          // Linear timer showing how much of the lifetime is left.
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: assessment.remaining(repo.now).inSeconds / hazard.type.lifetime.inSeconds,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 20),
          if (mine)
            const Text('You reported this. Others nearby need to confirm it.')
          else
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      repo.vote(hazard.id, VoteKind.confirm);
                    },
                    icon: Icon(myVote == VoteKind.confirm ? Icons.check_circle_rounded : Icons.visibility_rounded),
                    label: const Text('Still there'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      repo.vote(hazard.id, VoteKind.clear);
                    },
                    icon: Icon(myVote == VoteKind.clear ? Icons.check_circle_rounded : Icons.do_not_disturb_on_outlined),
                    label: const Text("It's gone"),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
