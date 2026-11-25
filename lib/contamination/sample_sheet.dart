import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../hazards/hazard.dart' show VoteKind;
import '../hazards/hazard_repository.dart';
import '../location/locator.dart';
import '../reputation/achievement_badge.dart';
import '../reputation/achievements.dart';
import 'contaminants.dart';
import 'sample.dart';
import 'sample_layer.dart';

/// Opens the "Add a reading" sheet for a point (the long-pressed spot or
/// the map centre); the sheet can switch to the device's own location.
Future<void> showAddSampleSheet(BuildContext context, {required double latitude, required double longitude}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddSampleSheet(latitude: latitude, longitude: longitude),
    );

class _AddSampleSheet extends StatefulWidget {
  const _AddSampleSheet({required this.latitude, required this.longitude});
  final double latitude, longitude;

  @override
  State<_AddSampleSheet> createState() => _AddSampleSheetState();
}

class _AddSampleSheetState extends State<_AddSampleSheet> {
  Contaminant _contaminant = Contaminant.lead;
  SampleMethod _method = SampleMethod.lab;
  final _value = TextEditingController();
  final _depth = TextEditingController();
  final _note = TextEditingController();
  late double _lat = widget.latitude, _lon = widget.longitude;
  bool _atMyLocation = false;
  bool _locating = false;
  bool _sending = false;

  @override
  void dispose() {
    _value.dispose();
    _depth.dispose();
    _note.dispose();
    super.dispose();
  }

  double? get _reading {
    final v = double.tryParse(_value.text.trim().replaceAll(',', '.'));
    return v == null || v < 0 || !v.isFinite ? null : v;
  }

  void _pick(Contaminant c) => setState(() {
        _contaminant = c;
        // A meter for radiation, a lab or kit for chemicals.
        if (c.exposure == Exposure.radiation) {
          _method = SampleMethod.meter;
        } else if (_method == SampleMethod.meter) {
          _method = SampleMethod.lab;
        }
      });

  Future<void> _useMyLocation() async {
    final locator = context.read<DeviceLocator?>();
    if (locator == null) return;
    setState(() => _locating = true);
    final fix = locator.recent() ?? switch (await locator.gps()) { Located(:final fix) => fix, LocateFailed() => null };
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (fix != null) {
        _lat = fix.at.latitude;
        _lon = fix.at.longitude;
        _atMyLocation = true;
      }
    });
    if (fix == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't find your location. The reading uses the marked spot.")),
      );
    }
  }

  Future<void> _submit() async {
    final value = _reading;
    if (value == null) return;
    setState(() => _sending = true);
    await context.read<HazardRepository>().addSample(
          contaminant: _contaminant,
          value: value,
          method: _method,
          latitude: _lat,
          longitude: _lon,
          depthCm: double.tryParse(_depth.text.trim().replaceAll(',', '.')),
          note: _note.text,
        );
    await HapticFeedback.mediumImpact();
    if (!mounted) return;
    final practice = context.read<HazardRepository>().isSandbox;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(practice
          ? 'Practice reading added. It stays in this training run.'
          : 'Reading added. Others nearby can confirm it or flag it as wrong.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reading = _reading;
    final level = reading == null ? null : _contaminant.levelFor(reading);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Add a reading', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_atMyLocation ? 'At your location' : 'At the marked spot'}: '
                    '${_lat.toStringAsFixed(5)}, ${_lon.toStringAsFixed(5)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (!_atMyLocation && context.read<DeviceLocator?>() != null)
                  TextButton.icon(
                    onPressed: _locating ? null : _useMyLocation,
                    icon: _locating
                        ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.my_location_rounded, size: 18),
                    label: const Text('Use my location'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('What was measured', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in Contaminant.values)
                  ChoiceChip(
                    avatar: Icon(c.icon, size: 18),
                    label: Text(c.label),
                    selected: _contaminant == c,
                    onSelected: (_) => _pick(c),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _value,
              autofocus: false,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Reading',
                suffixText: _contaminant.unit.symbol,
                helperText: _contaminant.unit.label,
                border: const OutlineInputBorder(),
              ),
            ),
            // The verdict appears as the number is typed: people see what
            // their reading means before they share it.
            if (level != null) ...[
              const SizedBox(height: 12),
              _LevelCard(contaminant: _contaminant, level: level),
            ],
            const SizedBox(height: 16),
            Text('How it was measured', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in SampleMethod.values)
                  ChoiceChip(label: Text(m.label), selected: _method == m, onSelected: (_) => setState(() => _method = m)),
              ],
            ),
            if (_contaminant.unit == SampleUnit.mgPerKg) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _depth,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Depth (optional)',
                  suffixText: 'cm',
                  helperText: 'Fresh dust sits in the top few centimetres.',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder()),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: reading == null || _sending ? null : _submit,
                icon: const Icon(Icons.add_location_alt_rounded),
                label: Text(reading == null ? 'Enter the reading' : 'Add reading'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The level, what to do, and where the scale comes from.
class _LevelCard extends StatelessWidget {
  const _LevelCard({required this.contaminant, required this.level});
  final Contaminant contaminant;
  final ContaminationLevel level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: level.color.withValues(alpha: 0.18),
      child: ListTile(
        leading: CircleAvatar(radius: 12, backgroundColor: level.color),
        title: Text(level.label, style: theme.textTheme.titleMedium),
        subtitle: Text('${contaminant.advice(level)}\nScale: ${contaminant.basis}.'),
        isThreeLine: true,
      ),
    );
  }
}

/// A reading's details: what it means, how it was taken, who took it, and
/// buttons for others to back it up or flag it.
Future<void> showSampleDetailsSheet(BuildContext context, String sampleId) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: SingleChildScrollView(child: _SampleDetails(sampleId: sampleId)),
      ),
    );

class _SampleDetails extends StatelessWidget {
  const _SampleDetails({required this.sampleId});
  final String sampleId;

  static String _date(DateTime at) {
    final l = at.toLocal();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${l.day} ${months[l.month - 1]} ${l.year}';
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<HazardRepository>();
    final sample = repo.sampleById(sampleId);
    if (sample == null) return const SizedBox(height: 120);
    final theme = Theme.of(context);
    final status = repo.assessSampleNow(sample);
    final mine = sample.reportedBy == repo.deviceId;
    final record = repo.recordFor(sample.reportedBy);
    final tier = Tier.of(record);
    VoteKind? myVote;
    for (final v in sample.votes) {
      if (v.deviceId == repo.deviceId) myVote = v.kind;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: sample.level.color,
                child: Icon(sample.contaminant.icon, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${sample.contaminant.label}: ${sample.contaminant.format(sample.value)}',
                        style: theme.textTheme.titleLarge),
                    Text('${sample.method.label} · ${_date(sample.takenAt ?? sample.reportedAt)}'
                        '${sample.depthCm != null ? ' · ${sample.depthCm!.round()} cm deep' : ''}'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _LevelCard(contaminant: sample.contaminant, level: sample.level),
          if (sample.note.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('"${sample.note}"', style: theme.textTheme.bodyMedium),
          ],
          if (status == SampleStatus.disputed) ...[
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.help_outline_rounded),
              title: const Text('Someone thinks this reading is wrong'),
              subtitle: const Text('Shown faded until more people back it up or flag it.'),
            ),
          ],
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: AchievementBadge(icon: tier.icon, color: tier.color, size: 36, animate: false),
            title: Text('Added by ${mine ? 'you' : record.settledReports == 0 ? 'a new reporter' : 'a ${tier.label.toLowerCase()}'}'),
            subtitle: Text('counts ${record.multiplier.toStringAsFixed(1)}× · shown until ${_date(sample.expiresAt)}'),
          ),
          if (!mine) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: myVote == VoteKind.confirm ? null : () => repo.vote(sample.id, VoteKind.confirm),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Matches mine'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: myVote == VoteKind.clear ? null : () => repo.vote(sample.id, VoteKind.clear),
                    icon: const Icon(Icons.flag_outlined),
                    label: const Text('Looks wrong'),
                  ),
                ),
              ],
            ),
          ] else
            Text('You added this reading. Others nearby can confirm it or flag it.', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
