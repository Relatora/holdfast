/// The Holdfast mark: a beacon that stays lit inside a Faraday cage, over
/// the contour lines of a topographic map.
///
/// * The contour lines are the map: the app is a map first.
/// * The lattice dome is a Faraday cage: what's inside comes through a
///   solar storm that takes out the grid.
/// * The amber beacon is you, still lit, still sending.
///
/// One painter draws the launcher icon (rendered to PNGs by
/// `tool/render_icons_test.dart`) and the animated splash screen, which
/// drives the [MarkProgress] values to assemble the mark piece by piece.
/// Everything is drawn in a unit square scaled to the canvas, so it is
/// sharp at any size.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// The mark's palette: the app's dark "tactical" theme.
abstract final class MarkColors {
  static const slate = Color(0xFF0F1417);
  static const slateLight = Color(0xFF1C262D);
  static const contour = Color(0xFF3FC1A8); // the theme's teal
  static const cage = Color(0xFFF4EFE6); // the theme's sand, as bright metal
  static const beacon = Color(0xFFFFB020); // the theme's amber
}

/// How far each part of the mark has been drawn, 0 to 1. All 1 is the
/// finished mark (the icon); the splash screen animates them.
@immutable
class MarkProgress {
  const MarkProgress({this.contours = 1, this.cage = 1, this.beacon = 1, this.signal = 1, this.flicker = 0});

  static const complete = MarkProgress();

  /// The contour lines, drawn outward from the summit.
  final double contours;

  /// The lattice dome: its outline first, then the bars.
  final double cage;

  /// The beacon's light, from out to fully lit.
  final double beacon;

  /// The signal arcs either side of the beacon.
  final double signal;

  /// 0 to 1: how much a passing solar storm disturbs the contour lines
  /// (the splash screen's shockwave). The cage and beacon never flicker.
  final double flicker;
}

/// Which layers to draw. The launcher icon needs them separately on
/// Android (an adaptive icon is a background and a foreground the system
/// masks and moves), and as one picture everywhere else.
enum MarkLayers {
  /// Rounded tile, contours, cage and beacon: the whole icon.
  full,

  /// Square slate background with contours, edge to edge.
  background,

  /// Cage and beacon only, on transparent, sized for the adaptive icon's
  /// safe zone.
  foreground,

  /// The foreground as one flat colour, for Android's themed icons.
  monochrome,

  /// Contours, cage and beacon with no tile, for the splash screen, which
  /// draws on its own slate background.
  splash,
}

class HoldfastMarkPainter extends CustomPainter {
  const HoldfastMarkPainter({this.progress = MarkProgress.complete, this.layers = MarkLayers.full});

  final MarkProgress progress;
  final MarkLayers layers;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(side);

    switch (layers) {
      case MarkLayers.full:
        // A squircle-ish tile (iOS-like corner radius), clipped so the
        // contours stay inside it.
        final tile = RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 1, 1), const Radius.circular(0.225));
        canvas.clipRRect(tile);
        _background(canvas);
        _contours(canvas);
        _cageAndBeacon(canvas, scale: 1);
      case MarkLayers.background:
        _background(canvas);
        _contours(canvas);
      case MarkLayers.foreground:
        // Android shows only the middle 66 % circle of a 108 dp adaptive
        // icon. Enlarged to fill it, and lifted so the dome (whose weight
        // sits low) is centred in the circle with its base line inside.
        _cageAndBeacon(canvas, scale: 0.8, lift: 0.06);
      case MarkLayers.monochrome:
        _cageAndBeacon(canvas, scale: 0.8, lift: 0.06, flat: Colors.white);
      case MarkLayers.splash:
        _contours(canvas);
        _cageAndBeacon(canvas, scale: 1);
    }
    canvas.restore();
  }

  void _background(Canvas canvas) {
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(0.5, 0.42),
          0.75,
          const [MarkColors.slateLight, MarkColors.slate],
        ),
    );
  }

  /// Seven closed contour lines around a summit just above the cage, each
  /// a circle bent by a few slow sine waves so they read as terrain, not a
  /// target. Deterministic: the icon is the same on every render.
  void _contours(Canvas canvas) {
    const summit = Offset(0.5, 0.47);
    const rings = 7;
    for (var i = 0; i < rings; i++) {
      // Rings appear from the summit outward as [progress.contours] grows.
      final start = i / rings * 0.7;
      final t = ((progress.contours - start) / 0.3).clamp(0.0, 1.0);
      if (t <= 0) continue;
      final radius = 0.09 + i * 0.075;
      final path = Path();
      const steps = 96;
      for (var s = 0; s <= steps; s++) {
        final a = s / steps * 2 * math.pi;
        // Each ring gets its own wobble, and the outer ones wobble more.
        final wobble = 1 +
            (0.06 + i * 0.012) * math.sin(3 * a + i * 0.9) +
            0.035 * math.sin(5 * a - i * 1.7) +
            0.02 * math.cos(2 * a + i * 2.3);
        // The storm shakes the lines: a fast ripple scaled by flicker.
        final shake = progress.flicker * 0.018 * math.sin(14 * a + i * 3.1);
        final r = radius * wobble + shake;
        final p = Offset(summit.dx + r * math.cos(a), summit.dy + r * 0.86 * math.sin(a));
        s == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      // Index contours (every third) are bolder, as on printed maps.
      final index = i % 3 == 2;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = index ? 0.009 : 0.005
        ..strokeJoin = StrokeJoin.round
        ..color = MarkColors.contour.withValues(alpha: (index ? 0.42 : 0.26) * (1 - progress.flicker * 0.5));
      canvas.drawPath(t < 1 ? _trim(path, t) : path, paint);
    }
  }

  /// The beacon under a lattice dome standing on a base line. [scale]
  /// shrinks it about the centre and [lift] moves it up (for the adaptive
  /// icon's visible circle); [flat] draws everything in one colour (the
  /// themed icon).
  void _cageAndBeacon(Canvas canvas, {required double scale, double lift = 0, Color? flat}) {
    canvas.save();
    canvas.translate(0.5, 0.5 - lift);
    canvas.scale(scale);
    canvas.translate(-0.5, -0.5);

    const base = Offset(0.5, 0.71); // centre of the dome's base
    const r = 0.30; // dome radius
    final cageColor = flat ?? MarkColors.cage;
    final beaconColor = flat ?? MarkColors.beacon;

    // --- Beacon, inside and behind the bars -------------------------------
    const beacon = Offset(0.5, 0.6);
    final lit = progress.beacon;
    if (lit > 0) {
      if (flat == null) {
        // A warm glow filling the cage.
        canvas.drawCircle(
          beacon,
          0.24,
          Paint()
            ..shader = ui.Gradient.radial(beacon, 0.24, [
              beaconColor.withValues(alpha: 0.55 * lit),
              beaconColor.withValues(alpha: 0.0),
            ]),
        );
      }
      canvas.drawCircle(beacon, 0.062 * (0.6 + 0.4 * lit), Paint()..color = beaconColor.withValues(alpha: lit));
      if (flat == null) {
        canvas.drawCircle(beacon, 0.026 * lit, Paint()..color = const Color(0xFFFFF4D6).withValues(alpha: lit));
      }
    }

    // Two signal arcs either side: still sending.
    if (progress.signal > 0) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 0.022
        ..color = beaconColor.withValues(alpha: progress.signal);
      for (final (i, radius) in [0.1, 0.148].indexed) {
        final sweep = 0.9 * ((progress.signal * 2 - i).clamp(0.0, 1.0));
        if (sweep <= 0) continue;
        final rect = Rect.fromCircle(center: beacon, radius: radius);
        canvas.drawArc(rect, -sweep / 2, sweep, false, paint); // right
        canvas.drawArc(rect, math.pi - sweep / 2, sweep, false, paint); // left
      }
    }

    // --- The cage ----------------------------------------------------------
    final c = progress.cage;
    if (c > 0) {
      final bar = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = cageColor;
      final domeRect = Rect.fromCircle(center: base, radius: r);

      // Outline: the dome's arc sweeps over from both feet, then the base.
      final outline = (c / 0.45).clamp(0.0, 1.0);
      bar.strokeWidth = 0.03;
      canvas.drawArc(domeRect, math.pi, math.pi / 2 * outline, false, bar);
      canvas.drawArc(domeRect, 0, -math.pi / 2 * outline, false, bar);
      final baseHalf = (r + 0.06) * outline;
      canvas.drawLine(Offset(base.dx - baseHalf, base.dy), Offset(base.dx + baseHalf, base.dy), bar..strokeWidth = 0.034);

      // Bars: two pairs of meridians (half-ellipses) and one parallel
      // high above the beacon, so the dome reads as a sphere of mesh
      // without a bar cutting through the light, even at icon size.
      final bars = ((c - 0.45) / 0.55).clamp(0.0, 1.0);
      if (bars > 0) {
        bar.strokeWidth = 0.013;
        bar.color = cageColor.withValues(alpha: 0.85 * bars);
        for (final f in [0.42, 0.8]) {
          final meridian = Rect.fromCenter(center: base, width: 2 * r * f, height: 2 * r);
          canvas.drawArc(meridian, math.pi, math.pi, false, bar);
        }
        const h = 0.72;
        final y = base.dy - r * h;
        final half = r * math.sqrt(1 - h * h);
        canvas.drawLine(Offset(base.dx - half, y), Offset(base.dx + half, y), bar);
      }
    }
    canvas.restore();
  }

  /// The first [t] of a path's length.
  static Path _trim(Path path, double t) {
    final out = Path();
    for (final metric in path.computeMetrics()) {
      out.addPath(metric.extractPath(0, metric.length * t), Offset.zero);
    }
    return out;
  }

  @override
  bool shouldRepaint(HoldfastMarkPainter old) =>
      old.layers != layers ||
      old.progress.contours != progress.contours ||
      old.progress.cage != progress.cage ||
      old.progress.beacon != progress.beacon ||
      old.progress.signal != progress.signal ||
      old.progress.flicker != progress.flicker;
}

/// The mark as a widget.
class HoldfastMark extends StatelessWidget {
  const HoldfastMark({super.key, this.size = 96, this.progress = MarkProgress.complete, this.layers = MarkLayers.full});

  final double size;
  final MarkProgress progress;
  final MarkLayers layers;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: HoldfastMarkPainter(progress: progress, layers: layers)),
      );
}
