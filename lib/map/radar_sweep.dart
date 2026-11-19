import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// A one-shot radar sweep drawn over the map while "nearest supplies" runs.
///
/// The search itself takes about a millisecond; the sweep exists to show
/// *where* the search is centred and to make the results feel found rather
/// than dumped on screen. It calls [onDone] when the sweep completes.
class RadarSweep extends StatefulWidget {
  const RadarSweep({super.key, required this.color, required this.onDone});

  final Color color;
  final VoidCallback onDone;

  @override
  State<RadarSweep> createState() => _RadarSweepState();
}

class _RadarSweepState extends State<RadarSweep> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..forward().whenComplete(widget.onDone);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _RadarPainter(progress: _controller.value, color: widget.color),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.42;
    // Fade in quickly, hold, then fade out over the last 20%.
    final fade = progress < 0.1 ? progress / 0.1 : (progress > 0.8 ? (1 - progress) / 0.2 : 1.0);

    // Range rings.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: 0.35 * fade);
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(center, radius * i / 3, ring);
    }

    // The sweeping beam: a sector with a gradient trailing behind it.
    final angle = progress * 2 * math.pi * 1.25 - math.pi / 2;
    final beam = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi / 2,
        colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.45 * fade)],
        transform: GradientRotation(angle - math.pi / 2),
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      angle - math.pi / 2,
      math.pi / 2,
      true,
      beam,
    );

    // Leading edge and centre dot.
    final edge = Paint()
      ..strokeWidth = 2
      ..color = color.withValues(alpha: 0.9 * fade);
    canvas.drawLine(center, center + Offset(math.cos(angle), math.sin(angle)) * radius, edge);
    canvas.drawCircle(center, 5, Paint()..color = color.withValues(alpha: fade));
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.progress != progress;
}
