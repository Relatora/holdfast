/// The moving layer over the hazard drawings: wind streaks and drifting
/// motes along plumes, tsunami wave fronts racing out from their origin,
/// an erupting vent throwing embers and ash, the pulse of a radiation
/// source and the shockwave of a detonation.
///
/// It sits on top of the static plume, ring and zone layers, which stay the
/// readable record (with their labels and "estimate" wording); this layer
/// only shows the motion. It is one CustomPainter driven by one Ticker,
/// so its cost doesn't grow with widgets per particle, and it is left out
/// entirely when motion is off (reduced motion, battery saver) or when no
/// hazard on the map moves.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../../hazards/effects/nuclear_effects.dart';
import '../../hazards/effects/spread.dart';
import '../../hazards/hazard.dart';
import '../../hazards/hazard_details.dart';
import '../hazard_marker.dart';
import 'effects_model.dart';

/// True when [hazard] has anything to animate.
bool hasEffects(Hazard hazard) =>
    (hazard.type.spreadsWithWind && hazard.wind != null) ||
    hazard.type == HazardType.volcanicEruption ||
    hazard.type == HazardType.radiation ||
    hazard.nuclear != null ||
    hazard.tsunami != null;

class EffectsLayer extends StatefulWidget {
  const EffectsLayer({super.key, required this.hazards, required this.nightVision, required this.dark});

  final List<Hazard> hazards;

  /// Red only, as the rest of the map in night vision.
  final bool nightVision;

  /// A dark map: wind streaks are drawn light; on a light map, dark.
  final bool dark;

  @override
  State<EffectsLayer> createState() => _EffectsLayerState();
}

class _EffectsLayerState extends State<EffectsLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((elapsed) => _seconds.value = elapsed.inMicroseconds / 1e6);
  final _seconds = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: MobileLayerTransformer(
        child: CustomPaint(
          size: camera.size,
          painter: _EffectsPainter(
            camera: camera,
            hazards: widget.hazards,
            seconds: _seconds,
            nightVision: widget.nightVision,
            dark: widget.dark,
          ),
        ),
      ),
    );
  }
}

class _EffectsPainter extends CustomPainter {
  _EffectsPainter({
    required this.camera,
    required this.hazards,
    required this.seconds,
    required this.nightVision,
    required this.dark,
  }) : super(repaint: seconds);

  final MapCamera camera;
  final List<Hazard> hazards;
  final ValueNotifier<double> seconds;
  final bool nightVision;
  final bool dark;

  static const _distance = Distance();
  static const _nightRed = Color(0xFFFF2200);

  Color _c(Color color) => nightVision ? _nightRed.withValues(alpha: color.a) : color;
  Offset _px(LatLng at) => camera.getOffsetFromOrigin(at);

  @override
  void paint(Canvas canvas, Size size) {
    final t = seconds.value;
    final screen = Offset.zero & size;
    for (final hazard in hazards) {
      final origin = LatLng(hazard.latitude, hazard.longitude);
      final centre = _px(origin);
      final pxPerMeter = (_px(_distance.offset(origin, 1000, 90)) - centre).distance / 1000;
      // Skip what can't be on screen: everything here stays within 300 km.
      if (!screen.inflate(300000 * pxPerMeter + 60).contains(centre)) continue;

      final window = _windowFor(hazard, pxPerMeter, size);
      _wind(canvas, hazard, t, window);
      _motes(canvas, hazard, t, pxPerMeter, window);
      _tsunami(canvas, hazard, t, centre, pxPerMeter);
      if (hazard.type == HazardType.volcanicEruption) _vent(canvas, hazard, t, centre);
      if (hazard.type == HazardType.radiation) _pulse(canvas, hazard, t, centre);
      if (hazard.nuclear case final nuclear?) _shockwave(canvas, nuclear, t, centre, pxPerMeter);
    }
  }

  /// The stretch of a plume around the screen, in metres along its axis:
  /// where the screen's middle falls on the axis, give or take a screen and
  /// a half. Motes are spent there, not on the far end of a 60 km plume
  /// nobody can see at street level.
  ({double from, double to})? _windowFor(Hazard hazard, double pxPerMeter, Size size) {
    final axis = plumeAxis(hazard);
    if (axis == null || pxPerMeter <= 0) return null;
    final middle = camera.center;
    final meters = _distance.as(LengthUnit.Meter, axis.origin, middle);
    final bearing = _distance.bearing(axis.origin, middle);
    final along = meters * math.cos((bearing - axis.towardDegrees) * math.pi / 180);
    final reach = size.longestSide / pxPerMeter * 0.75;
    return (from: along - reach, to: along + reach);
  }

  // ---- Wind -----------------------------------------------------------------

  void _wind(Canvas canvas, Hazard hazard, double t, ({double from, double to})? window) {
    final streaks = windStreaks(hazard, t, count: 30, window: window);
    if (streaks.isEmpty) return;
    final base = dark ? const Color(0xFFFFFFFF) : const Color(0xFF263238);
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2;
    for (final s in streaks) {
      final a = _px(s.from), b = _px(s.to);
      // A comet: bright at the head, fading to nothing at the tail.
      paint.shader = ui.Gradient.linear(a, b, [
        _c(base.withValues(alpha: 0)),
        _c(base.withValues(alpha: 0.7 * s.opacity)),
      ]);
      canvas.drawLine(a, b, paint);
    }
  }

  // ---- Plume motes ------------------------------------------------------------

  void _motes(Canvas canvas, Hazard hazard, double t, double pxPerMeter, ({double from, double to})? window) {
    final style = moteStyleFor(hazard.type);
    final axis = plumeAxis(hazard);
    if (style == null || axis == null || window == null) return;
    // About one mote per 8 px of the plume's shown stretch, within limits.
    final shown = math.min(window.to, axis.lengthMeters) - math.max(window.from, 0);
    if (shown <= 0) return;
    final count = (shown * pxPerMeter / 8).clamp(16, 140).round();
    final motes = plumeMotes(hazard, t, count: count, window: window);
    final paint = Paint();
    for (final m in motes) {
      if (m.opacity <= 0.01) continue;
      final p = _px(m.at);
      switch (style) {
        case MoteStyle.chemical || MoteStyle.smoke || MoteStyle.gas:
          final color = switch (style) {
            MoteStyle.chemical => const Color(0xFFB5D334),
            MoteStyle.gas => const Color(0xFFB388FF),
            _ => const Color(0xFF8D7B6A),
          };
          final r = 7.0 * m.size;
          paint
            ..shader = ui.Gradient.radial(p, r, [
              _c(color.withValues(alpha: 0.42 * m.opacity)),
              _c(color.withValues(alpha: 0)),
            ])
            ..maskFilter = null;
          canvas.drawCircle(p, r, paint);
        case MoteStyle.radiation:
          // Sparks that twinkle.
          final twinkle = 0.5 + 0.5 * math.sin(t * 7 + m.seed * 40);
          paint
            ..shader = null
            ..color = _c(const Color(0xFFE6FF5A).withValues(alpha: 0.9 * m.opacity * twinkle));
          canvas.drawCircle(p, 1.6 * m.size, paint);
          paint.color = _c(const Color(0xFFC6FF00).withValues(alpha: 0.25 * m.opacity * twinkle));
          canvas.drawCircle(p, 4.5 * m.size, paint);
        case MoteStyle.lead:
          // Pale dust with a dark rim, so it shows on the plume's own colour.
          final at = p + Offset(0, 3 * (1 - m.opacity));
          paint
            ..shader = null
            ..color = _c(const Color(0xFF263238).withValues(alpha: 0.5 * m.opacity));
          canvas.drawCircle(at, 3 * m.size, paint);
          paint.color = _c(const Color(0xFFCFD8DC).withValues(alpha: 0.95 * m.opacity));
          canvas.drawCircle(at, 2 * m.size, paint);
        case MoteStyle.ash:
          // Charcoal flakes with a pale rim, drifting with a slight flutter,
          // so they read on the plume's own colour.
          final flutter = math.sin(t * 3 + m.seed * 20) * 2;
          final flake = Rect.fromCenter(center: p + Offset(flutter, 0), width: 5 * m.size, height: 3.4 * m.size);
          paint
            ..shader = null
            ..color = _c(const Color(0xFFEEEEEE).withValues(alpha: 0.6 * m.opacity));
          canvas.drawOval(flake.inflate(1), paint);
          paint.color = _c(const Color(0xFF424242).withValues(alpha: 0.9 * m.opacity));
          canvas.drawOval(flake, paint);
      }
    }
  }

  // ---- Tsunami ------------------------------------------------------------------

  void _tsunami(Canvas canvas, Hazard hazard, double t, Offset centre, double pxPerMeter) {
    final fronts = tsunamiFronts(hazard, t);
    if (fronts.isEmpty) return;
    final color = hazard.type.color;
    for (final f in fronts) {
      final r = f.radiusMeters * pxPerMeter;
      if (r < 2) continue;
      // The trough: a wide, dark band just behind the crest.
      canvas.drawCircle(
        centre,
        math.max(r - 6, 1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = _c(const Color(0xFF01579B).withValues(alpha: 0.22 * f.opacity)),
      );
      // The crest: a bright thin line with a soft glow.
      canvas.drawCircle(
        centre,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
          ..color = _c(color.withValues(alpha: 0.45 * f.opacity)),
      );
      canvas.drawCircle(
        centre,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = _c(const Color(0xFFE1F5FE).withValues(alpha: 0.9 * f.opacity)),
      );
    }
  }

  // ---- Volcanic vent --------------------------------------------------------------

  void _vent(Canvas canvas, Hazard hazard, double t, Offset vent) {
    // A throbbing glow.
    final throb = 0.75 + 0.25 * math.sin(t * 2.6);
    // Wider than the marker that sits on the vent, so the glow shows round it.
    canvas.drawCircle(
      vent,
      48 * throb,
      Paint()
        ..shader = ui.Gradient.radial(
          vent,
          48 * throb,
          [
            _c(const Color(0xFFFFC107).withValues(alpha: 0.75)),
            _c(const Color(0xFFFF5722).withValues(alpha: 0.35)),
            _c(const Color(0xFFFF5722).withValues(alpha: 0)),
          ],
          [0, 0.45, 1],
        ),
    );

    // The ash column: billows rising, then bending the way the wind blows.
    final wind = hazard.wind;
    final bend = wind == null
        ? Offset.zero
        : Offset(math.sin(wind.towardDegrees * math.pi / 180), -math.cos(wind.towardDegrees * math.pi / 180));
    final ash = Paint();
    for (var i = 0; i < 14; i++) {
      final phase = (t / 4 + i / 14) % 1.0;
      final rise = Offset(0, -70 * math.min(phase * 1.8, 1));
      final drift = bend * (90 * math.max(phase - 0.35, 0));
      final p = vent + rise + drift + Offset(math.sin(i * 2.3 + t) * 4, 0);
      final r = 6 + 16 * phase;
      ash.shader = ui.Gradient.radial(p, r, [
        _c(const Color(0xFF5D5D5D).withValues(alpha: 0.55 * (1 - phase))),
        _c(const Color(0xFF5D5D5D).withValues(alpha: 0)),
      ]);
      canvas.drawCircle(p, r, ash);
    }

    // Embers thrown out of the vent on ballistic arcs.
    final ember = Paint();
    for (var i = 0; i < 22; i++) {
      final period = 1.4 + (i % 5) * 0.15;
      final phase = (t / period + i * 0.137) % 1.0;
      final angle = math.pi * (0.2 + 0.6 * ((i * 0.618) % 1.0));
      final speed = 80 + (i % 7) * 9.0;
      final x = math.cos(angle) * speed * phase;
      final y = -math.sin(angle) * speed * phase + 60 * phase * phase;
      ember.color = _c(
        Color.lerp(const Color(0xFFFFEB3B), const Color(0xFFFF3D00), phase)!.withValues(alpha: 1 - phase),
      );
      canvas.drawCircle(vent + Offset(x, y), 3 * (1 - phase * 0.5), ember);
    }
  }

  // ---- Radiation source -------------------------------------------------------------

  void _pulse(Canvas canvas, Hazard hazard, double t, Offset source) {
    for (var k = 0; k < 2; k++) {
      final phase = (t / 2.4 + k / 2) % 1.0;
      canvas.drawCircle(
        source,
        14 + 40 * phase,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * (1 - phase) + 0.5
          ..color = _c(hazard.type.color.withValues(alpha: 0.8 * (1 - phase))),
      );
    }
  }

  // ---- Detonation ---------------------------------------------------------------------

  void _shockwave(Canvas canvas, NuclearDetails nuclear, double t, Offset ground, double pxPerMeter) {
    // Every 7 s: a flash, then the blast front running out to the widest
    // ring. Long enough between that it reads as a reminder, not a strobe.
    const period = 7.0;
    final phase = (t % period) / period;
    final reach = nuclearEffects(nuclear).map((r) => r.radiusMeters).fold(0.0, math.max) * pxPerMeter;
    if (phase < 0.06) {
      final flash = 1 - phase / 0.06;
      canvas.drawCircle(
        ground,
        24 + 30 * (1 - flash),
        Paint()
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12)
          ..color = _c(const Color(0xFFFFF8E1).withValues(alpha: 0.9 * flash)),
      );
    }
    if (phase < 0.6) {
      final front = phase / 0.6;
      canvas.drawCircle(
        ground,
        reach * front,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
          ..color = _c(const Color(0xFFFFAB40).withValues(alpha: 0.7 * (1 - front))),
      );
    }
  }

  @override
  bool shouldRepaint(_EffectsPainter old) =>
      old.camera != camera || old.hazards != hazards || old.nightVision != nightVision || old.dark != dark;
}
