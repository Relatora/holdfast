import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../map/hazard_marker.dart';
import '../theme/motion.dart';
import 'hazard.dart';
import 'hazard_details.dart';
import 'hazard_engine.dart';
import 'hazard_repository.dart';

/// Bottom sheet for reporting a hazard at a map position.
///
/// The flow is category → type → (type-specific details) → severity →
/// note. Grouping by category keeps 16 hazard types from becoming a wall of
/// chips, and the details only appear for the types that need them.
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
  HazardCategory _category = HazardCategory.fire;
  HazardType? _type;
  HazardSeverity _severity = HazardSeverity.moderate;
  final _details = TextEditingController();
  bool _sending = false;

  // Nuclear detonation.
  NuclearPreset? _preset = NuclearPreset.hiroshima;
  final _yield = TextEditingController();
  bool _megatons = false;
  BurstType _burst = BurstType.air;

  // Radiation.
  RadiationLevel _radiation = RadiationLevel.elevated;
  final _reading = TextEditingController();

  // Wind (optional, for hazards that drift).
  bool _withWind = false;
  double _windFrom = 270;
  double _windKmh = 15;

  @override
  void dispose() {
    _details.dispose();
    _yield.dispose();
    _reading.dispose();
    super.dispose();
  }

  /// The yield in kt from the preset or the typed number, or null if the
  /// typed number isn't valid.
  double? get _yieldKt {
    if (_preset != null) return _preset!.yieldKt;
    final typed = double.tryParse(_yield.text.trim().replaceAll(',', '.'));
    if (typed == null || typed <= 0) return null;
    return _megatons ? typed * 1000 : typed;
  }

  bool get _ready => _type != null && (_type != HazardType.nuclearDetonation || _yieldKt != null);

  Map<String, Object?> _buildDetails(HazardType type) => hazardDetails(
        wind: type.spreadsWithWind && _withWind ? Wind(fromDegrees: _windFrom, speedKmh: _windKmh) : null,
        radiation: type == HazardType.radiation
            ? RadiationDetails(level: _radiation, reading: double.tryParse(_reading.text.trim().replaceAll(',', '.')))
            : null,
        nuclear: type == HazardType.nuclearDetonation
            ? NuclearDetails(yieldKt: _yieldKt!, preset: _preset, burst: _burst)
            : null,
      );

  /// Severity the report carries: chosen by the reporter, except where the
  /// details already say how bad it is.
  HazardSeverity _severityFor(HazardType type) => switch (type) {
        HazardType.nuclearDetonation => HazardSeverity.extreme,
        HazardType.radiation => _radiation.severity,
        _ => _severity,
      };

  Future<void> _submit() async {
    final type = _type;
    if (type == null || !_ready) return;
    setState(() => _sending = true);
    await context.read<HazardRepository>().report(
          type: type,
          severity: _severityFor(type),
          latitude: widget.latitude,
          longitude: widget.longitude,
          description: _details.text,
          details: _buildDetails(type),
        );
    await HapticFeedback.mediumImpact();
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reported. It will show for everyone once others nearby confirm it.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final animate = Motion.enabled(context);
    final type = _type;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      child: SingleChildScrollView(
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
            const SizedBox(height: 14),
            // Step 1: what kind of thing. A wrap rather than a sideways
            // scroller: a mouse can't drag-scroll a row on desktop or web.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final category in HazardCategory.values)
                  if (category != HazardCategory.other)
                    ChoiceChip(
                      avatar: Icon(category.icon, size: 18),
                      label: Text(category.label),
                      selected: _category == category,
                      onSelected: (_) => setState(() {
                        _category = category;
                        if (_type?.category != category) _type = null;
                      }),
                    ),
              ],
            ),
            const Divider(height: 24),
            const SizedBox(height: 12),
            // Step 2: which hazard.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, t) in _category.types.indexed)
                  _staggered(
                    animate,
                    i,
                    ChoiceChip(
                      key: ValueKey(t),
                      avatar: Icon(t.icon, color: t.color, size: 18),
                      label: Text(t.label),
                      selected: _type == t,
                      onSelected: (_) {
                        HapticFeedback.selectionClick();
                        setState(() => _type = t);
                      },
                    ),
                  ),
              ],
            ),
            // Step 3: details for the types that have them.
            if (type == HazardType.nuclearDetonation) ..._nuclearInputs(theme),
            if (type == HazardType.radiation) ..._radiationInputs(theme),
            if (type != null && type.spreadsWithWind) ..._windInputs(theme),
            if (type != null && type != HazardType.nuclearDetonation && type != HazardType.radiation) ...[
              const SizedBox(height: 20),
              Text('How serious?', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<HazardSeverity>(
                segments: [for (final s in HazardSeverity.values) ButtonSegment(value: s, label: Text(s.label))],
                selected: {_severity},
                onSelectionChanged: (s) => setState(() => _severity = s.first),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _details,
              maxLength: 280,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'What do you see? (optional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: !_ready || _sending ? null : _submit,
                icon: const Icon(Icons.campaign_rounded),
                label: Text(type == null ? 'Choose a hazard type' : 'Report ${type.label.toLowerCase()}'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _nuclearInputs(ThemeData theme) => [
        const SizedBox(height: 20),
        Text('Weapon size', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Pick the closest, or enter the yield if it has been announced.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in NuclearPreset.values)
              ChoiceChip(
                label: Text('${preset.label} · ${NuclearDetails(yieldKt: preset.yieldKt).yieldLabel}'),
                selected: _preset == preset,
                onSelected: (_) => setState(() => _preset = preset),
              ),
            ChoiceChip(
              avatar: const Icon(Icons.edit_rounded, size: 18),
              label: const Text('Enter yield'),
              selected: _preset == null,
              onSelected: (_) => setState(() => _preset = null),
            ),
          ],
        ),
        if (_preset == null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _yield,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Yield',
                    border: const OutlineInputBorder(),
                    errorText: _yield.text.isNotEmpty && _yieldKt == null ? 'Enter a number above 0' : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: false, label: Text('kt')), ButtonSegment(value: true, label: Text('Mt'))],
                selected: {_megatons},
                onSelectionChanged: (s) => setState(() => _megatons = s.first),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        SegmentedButton<BurstType>(
          segments: [for (final b in BurstType.values) ButtonSegment(value: b, label: Text(b.label))],
          selected: {_burst},
          onSelectionChanged: (s) => setState(() => _burst = s.first),
        ),
        const SizedBox(height: 4),
        Text(
          _burst == BurstType.air
              ? 'Exploded in the air: the widest blast damage, little local fallout.'
              : 'Exploded at ground level: a smaller blast, but heavy fallout downwind.',
          style: theme.textTheme.bodySmall,
        ),
      ];

  List<Widget> _radiationInputs(ThemeData theme) => [
        const SizedBox(height: 20),
        Text('How high is it?', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final level in RadiationLevel.values)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            color: _radiation == level ? level.color.withValues(alpha: 0.2) : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: _radiation == level ? level.color : Colors.transparent, width: 2),
            ),
            child: ListTile(
              dense: true,
              leading: CircleAvatar(radius: 10, backgroundColor: level.color),
              title: Text('${level.label} · ${level.range}'),
              subtitle: Text(level.advice),
              onTap: () => setState(() {
                _radiation = level;
                _reading.clear();
              }),
            ),
          ),
        const SizedBox(height: 4),
        TextField(
          controller: _reading,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Meter reading in µSv/h (optional)',
            helperText: 'If you have a meter, the level is set from it.',
            border: OutlineInputBorder(),
          ),
          onChanged: (text) {
            final value = double.tryParse(text.trim().replaceAll(',', '.'));
            if (value != null && value >= 0) setState(() => _radiation = RadiationLevel.forReading(value));
          },
        ),
      ];

  List<Widget> _windInputs(ThemeData theme) {
    final wind = Wind(fromDegrees: _windFrom, speedKmh: _windKmh);
    return [
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Add the wind'),
        subtitle: const Text('Shows where smoke, gas, ash or fallout is likely to drift.'),
        value: _withWind,
        onChanged: (v) => setState(() => _withWind = v),
      ),
      if (_withWind) ...[
        Text('Blowing from', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (i, label) in const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'].indexed)
              ChoiceChip(
                label: Text(label),
                selected: wind.fromCompass == label,
                onSelected: (_) => setState(() => _windFrom = i * 45.0),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Strength: ${wind.strength}, ${wind.speedKmh.round()} km/h', style: theme.textTheme.labelLarge),
        Slider(
          value: _windKmh,
          max: 100,
          divisions: 20,
          label: '${_windKmh.round()} km/h',
          onChanged: (v) => setState(() => _windKmh = v),
        ),
      ],
    ];
  }
}

/// Pops the hazard-type chips in one after another (skipped in reduced motion).
Widget _staggered(bool animate, int index, Widget child) => animate
    ? child.animate(delay: (25 * index).ms).fadeIn(duration: 200.ms).scaleXY(begin: 0.9, end: 1)
    : child;

/// The type-specific facts a report carries, as rows for the details sheet.
List<Widget> _detailRows(Hazard hazard, ThemeData theme) {
  final nuclear = hazard.nuclear, radiation = hazard.radiation, wind = hazard.wind;
  return [
    if (nuclear != null)
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.brightness_7_rounded),
        title: Text('${nuclear.yieldLabel} ${nuclear.burst.label.toLowerCase()}'),
        subtitle: Text(nuclear.preset?.label ?? 'Yield entered by the reporter'),
      ),
    if (radiation != null)
      Card(
        margin: const EdgeInsets.only(top: 10),
        color: radiation.level.color.withValues(alpha: 0.18),
        child: ListTile(
          leading: CircleAvatar(radius: 12, backgroundColor: radiation.level.color),
          title: Text('${radiation.level.label} radiation · '
              '${radiation.reading != null ? '${radiation.reading} µSv/h measured' : radiation.level.range}'),
          subtitle: Text(radiation.level.advice),
        ),
      ),
    if (wind != null)
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Transform.rotate(
          // The arrow points where the wind carries things.
          angle: wind.towardDegrees * 3.14159265 / 180,
          child: const Icon(Icons.navigation_rounded),
        ),
        title: Text('Wind ${wind.strength}, ${wind.summary}'),
        subtitle: Text(wind.source == WindSource.forecast ? 'From a weather forecast' : 'Reported by hand'),
      ),
  ];
}

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
          ..._detailRows(hazard, theme),
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
