import 'dart:math' as math;

import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';

import '../hazards/hazard.dart';
import '../hazards/hazard_details.dart';
import '../hazards/hazard_engine.dart';
import '../theme/app_theme.dart';

/// Colour and icon for each hazard type on light and dark maps.
extension HazardTypeStyle on HazardType {
  IconData get icon => switch (this) {
        HazardType.fire => Icons.local_fire_department_rounded,
        HazardType.flood => Icons.flood_rounded,
        HazardType.roadBlocked => Icons.block_rounded,
        HazardType.powerLines => Icons.electric_bolt_rounded,
        HazardType.gasLeak => Icons.gas_meter_rounded,
        HazardType.chemicalSpill => Icons.science_rounded,
        HazardType.structuralCollapse => Icons.domain_disabled_rounded,
        HazardType.unrest => Icons.groups_rounded,
        HazardType.contaminatedWater => Icons.water_damage_rounded,
        HazardType.police => Icons.local_police_rounded,
        HazardType.peopleHurt => Icons.personal_injury_rounded,
        HazardType.volcanicAsh => Icons.cloud_rounded,
        HazardType.volcanicEruption => Icons.volcano_rounded,
        HazardType.lava => Icons.whatshot_rounded,
        HazardType.tsunami => Icons.tsunami_rounded,
        HazardType.nuclearDetonation => Icons.brightness_7_rounded,
        HazardType.radiation => Icons.warning_amber_rounded,
        HazardType.leadDust => Icons.grain_rounded,
        HazardType.other => Icons.report_rounded,
      };

  Color get color => switch (this) {
        HazardType.fire => const Color(0xFFFF5A1F),
        HazardType.flood => const Color(0xFF2F80ED),
        HazardType.roadBlocked => const Color(0xFFF2A007),
        HazardType.powerLines => const Color(0xFFF5C400),
        HazardType.gasLeak => const Color(0xFF9B51E0),
        HazardType.chemicalSpill => const Color(0xFF27AE60),
        HazardType.structuralCollapse => const Color(0xFF8D6E63),
        HazardType.unrest => AppTheme.danger,
        HazardType.contaminatedWater => const Color(0xFF00A3A3),
        HazardType.police => const Color(0xFF3D5AFE),
        HazardType.peopleHurt => const Color(0xFFE53970),
        HazardType.volcanicAsh => const Color(0xFF78909C),
        HazardType.volcanicEruption => const Color(0xFF8E2A12),
        HazardType.lava => const Color(0xFFD84315),
        HazardType.tsunami => const Color(0xFF0277BD),
        HazardType.nuclearDetonation => const Color(0xFFB71C1C),
        HazardType.radiation => const Color(0xFFC6A700),
        // Lead's own dull blue-grey, darker than ash so the two read apart.
        HazardType.leadDust => const Color(0xFF546E8A),
        HazardType.other => const Color(0xFF757575),
      };
}

/// Traffic-light colours for radiation levels, darkest for the worst.
extension RadiationLevelStyle on RadiationLevel {
  Color get color => switch (this) {
        RadiationLevel.normal => const Color(0xFF43A047),
        RadiationLevel.elevated => const Color(0xFFC0CA33),
        RadiationLevel.high => const Color(0xFFFFA000),
        RadiationLevel.veryHigh => const Color(0xFFE64A19),
        RadiationLevel.dangerous => const Color(0xFF8E24AA),
      };
}

/// Icon for each hazard category, used by the report sheet and filters.
extension HazardCategoryStyle on HazardCategory {
  IconData get icon => switch (this) {
        HazardCategory.fire => Icons.local_fire_department_rounded,
        HazardCategory.water => Icons.water_rounded,
        HazardCategory.transport => Icons.traffic_rounded,
        HazardCategory.utilities => Icons.bolt_rounded,
        HazardCategory.chemical => Icons.science_rounded,
        HazardCategory.geological => Icons.landslide_rounded,
        HazardCategory.people => Icons.groups_rounded,
        HazardCategory.other => Icons.report_rounded,
      };
}

/// A hazard on the map: an icon badge with rings pulsing out of it.
///
/// * Severity sets the pulse speed and ring size, so an extreme hazard reads
///   as urgent at a glance.
/// * When a hazard becomes verified it "locks in" with a one-off scale and
///   glow, so people notice the change of status.
/// * Unverified hazards are drawn dashed and translucent; disputed ones get a
///   question badge.
/// * [HazardAssessment.opacity] fades markers out over their final hour.
class HazardMarker extends StatefulWidget {
  const HazardMarker({
    super.key,
    required this.hazard,
    required this.assessment,
    required this.animate,
    this.nightVision = false,
  });

  final Hazard hazard;
  final HazardAssessment assessment;

  /// False in battery-saver / reduced-motion mode: no pulse, no lock-in.
  final bool animate;
  final bool nightVision;

  /// Marker widget size; flutter_map needs it up front.
  static const size = 96.0;

  @override
  State<HazardMarker> createState() => _HazardMarkerState();
}

class _HazardMarkerState extends State<HazardMarker> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: _periodFor(widget.hazard.severity),
  );

  static Duration _periodFor(HazardSeverity severity) => switch (severity) {
        HazardSeverity.low => const Duration(milliseconds: 2800),
        HazardSeverity.moderate => const Duration(milliseconds: 2200),
        HazardSeverity.high => const Duration(milliseconds: 1600),
        HazardSeverity.extreme => const Duration(milliseconds: 1100),
      };

  @override
  void initState() {
    super.initState();
    if (widget.animate) _pulse.repeat();
  }

  @override
  void didUpdateWidget(HazardMarker old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_pulse.isAnimating) _pulse.repeat();
    if (!widget.animate && _pulse.isAnimating) _pulse.stop();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.assessment.status;
    final scheme = Theme.of(context).colorScheme;
    final color = widget.nightVision ? scheme.primary : widget.hazard.type.color;
    final unverified = status == HazardStatus.unverified;
    final badgeSize = 34.0 + widget.hazard.severity.index * 3;

    final badge = Container(
      width: badgeSize,
      height: badgeSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: unverified ? color.withValues(alpha: 0.55) : color,
        border: Border.all(color: scheme.surface, width: 2.5),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 10)],
      ),
      child: Icon(widget.hazard.type.icon, size: badgeSize * 0.56, color: Colors.white),
    );

    Widget marker = Stack(
      alignment: Alignment.center,
      children: [
        if (widget.animate)
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => CustomPaint(
              size: const Size.square(HazardMarker.size),
              painter: _PulsePainter(
                progress: _pulse.value,
                color: color,
                dashed: unverified,
                maxRadius: HazardMarker.size / 2 * (0.7 + widget.hazard.severity.index * 0.1),
              ),
            ),
          ),
        // Status changes swap the badge's key, which replays the lock-in.
        KeyedSubtree(
          key: ValueKey(status),
          child: widget.animate && status == HazardStatus.verified
              ? badge
                  .animate()
                  .scaleXY(begin: 1.6, end: 1, duration: 500.ms, curve: Curves.elasticOut)
                  .then()
                  .shimmer(duration: 700.ms, color: Colors.white54)
              : badge,
        ),
        if (status == HazardStatus.disputed)
          Positioned(
            right: HazardMarker.size / 2 - badgeSize / 2 - 6,
            top: HazardMarker.size / 2 - badgeSize / 2 - 6,
            child: CircleAvatar(
              radius: 9,
              backgroundColor: scheme.surface,
              child: Icon(Icons.question_mark_rounded, size: 13, color: scheme.onSurface),
            ),
          ),
        // A planned release (a scheduled detonation) that hasn't happened
        // yet: a clock, so it doesn't read as already in the air.
        if (widget.hazard.plannedAt(DateTime.now()))
          Positioned(
            left: HazardMarker.size / 2 - badgeSize / 2 - 6,
            top: HazardMarker.size / 2 - badgeSize / 2 - 6,
            child: Semantics(
              label: 'Planned',
              child: CircleAvatar(
                radius: 9,
                backgroundColor: scheme.surface,
                child: Icon(Icons.schedule_rounded, size: 13, color: scheme.onSurface),
              ),
            ),
          ),
      ],
    );

    return Opacity(opacity: widget.assessment.opacity, child: marker);
  }
}

/// Two staggered rings that expand and fade, like a sonar ping.
class _PulsePainter extends CustomPainter {
  _PulsePainter({
    required this.progress,
    required this.color,
    required this.dashed,
    required this.maxRadius,
  });

  final double progress;
  final Color color;
  final bool dashed;
  final double maxRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final phase in [0.0, 0.5]) {
      final t = (progress + phase) % 1.0;
      final radius = 14 + (maxRadius - 14) * Curves.easeOut.transform(t);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * (1 - t) + 0.5
        ..color = color.withValues(alpha: (1 - t) * 0.8);
      if (dashed) {
        // Unverified: a broken ring reads as "not confirmed yet".
        const segments = 12;
        for (var i = 0; i < segments; i += 2) {
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            i * 2 * math.pi / segments + t,
            2 * math.pi / segments,
            false,
            paint,
          );
        }
      } else {
        canvas.drawCircle(center, radius, paint);
        canvas.drawCircle(center, radius, Paint()..color = color.withValues(alpha: (1 - t) * 0.12));
      }
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.progress != progress || old.color != color;
}
