import 'dart:math' as math;

import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';

/// A hexagonal badge with an icon: the shape of every rank and achievement.
/// Locked badges are grey and faint; a fresh unlock can [celebrate] with a
/// pop and a shine (skipped when [animate] is false: reduced motion or
/// battery saver).
class AchievementBadge extends StatelessWidget {
  const AchievementBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 56,
    this.locked = false,
    this.celebrate = false,
    this.animate = true,
  });

  final IconData icon;
  final Color color;
  final double size;
  final bool locked;
  final bool celebrate;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final fill = locked ? Theme.of(context).colorScheme.surfaceContainerHighest : color;
    final badge = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _HexPainter(fill: fill, rim: locked ? fill : Color.lerp(color, Colors.white, 0.35)!),
        child: Center(
          child: Icon(
            locked ? Icons.lock_rounded : icon,
            size: size * 0.46,
            color: locked ? Theme.of(context).colorScheme.outline : Colors.white,
          ),
        ),
      ),
    );
    if (!celebrate || !animate) return badge;
    return badge
        .animate()
        .scale(begin: const Offset(0.3, 0.3), end: const Offset(1, 1), duration: 500.ms, curve: Curves.elasticOut)
        .then()
        .shimmer(duration: 900.ms, color: Colors.white70);
  }
}

class _HexPainter extends CustomPainter {
  const _HexPainter({required this.fill, required this.rim});

  final Color fill, rim;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final a = math.pi / 3 * i - math.pi / 2;
      final p = c + Offset(math.cos(a), math.sin(a)) * r * 0.96;
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = rim
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.1,
    );
  }

  @override
  bool shouldRepaint(_HexPainter old) => old.fill != fill || old.rim != rim;
}
