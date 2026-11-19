import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Slowly drifting contour lines shown where there's no map yet.
///
/// An empty grey screen reads as "broken"; contour lines read as "a map
/// goes here", which is the message we want before the first download.
class TopoBackground extends StatefulWidget {
  const TopoBackground({super.key, required this.animate});

  final bool animate;

  @override
  State<TopoBackground> createState() => _TopoBackgroundState();
}

class _TopoBackgroundState extends State<TopoBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 40),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _drift.repeat();
  }

  @override
  void didUpdateWidget(TopoBackground old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_drift.isAnimating) _drift.repeat();
    if (!widget.animate) _drift.stop();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _drift,
        builder: (context, _) => CustomPaint(
          painter: _ContourPainter(
            phase: _drift.value * 2 * math.pi,
            line: scheme.primary.withValues(alpha: 0.13),
            background: scheme.surface,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _ContourPainter extends CustomPainter {
  _ContourPainter({required this.phase, required this.line, required this.background});

  final double phase;
  final Color line;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = line;

    // Two "hills" whose contour rings are bent by a few sine waves, which is
    // enough irregularity to look hand-drawn without any noise library.
    final hills = [
      (Offset(size.width * 0.3, size.height * 0.35), 14),
      (Offset(size.width * 0.75, size.height * 0.7), 11),
    ];
    for (final (center, rings) in hills) {
      for (var ring = 1; ring <= rings; ring++) {
        final base = ring * size.shortestSide * 0.045;
        final path = Path();
        for (var step = 0; step <= 96; step++) {
          final a = step / 96 * 2 * math.pi;
          final wobble = 1 +
              0.10 * math.sin(3 * a + phase + ring * 0.3) +
              0.06 * math.sin(5 * a - phase * 0.7) +
              0.04 * math.cos(2 * a + ring);
          final p = center + Offset(math.cos(a), math.sin(a)) * base * wobble;
          step == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path..close(), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_ContourPainter old) =>
      old.phase != phase || old.line != line || old.background != background;
}
