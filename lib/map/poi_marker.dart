import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';

import '../pois/poi.dart';

/// A supply location: a small teardrop pin in the category's colour.
///
/// [dropDelay] staggers the drop-in so a page of results lands one pin after
/// another instead of popping in all at once.
class PoiMarker extends StatelessWidget {
  const PoiMarker({
    super.key,
    required this.poi,
    required this.animate,
    this.highlighted = false,
    this.dropDelay = Duration.zero,
    this.nightVision = false,
  });

  final Poi poi;
  final bool animate;
  final bool highlighted;
  final Duration dropDelay;
  final bool nightVision;

  static const width = 40.0;
  static const height = 48.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = nightVision ? scheme.primary : poi.category.color;
    final scale = highlighted ? 1.25 : 1.0;

    final Widget pin = AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.surface, width: 2),
              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6, offset: Offset(0, 2))],
            ),
            child: Icon(poi.category.icon, size: 18, color: nightVision ? Colors.black : Colors.white),
          ),
          // The pin's point, so the marker sits *on* the location.
          CustomPaint(size: const Size(12, 8), painter: _PinTipPainter(color)),
        ],
      ),
    );

    if (!animate) return pin;
    return pin
        .animate(delay: dropDelay)
        .fadeIn(duration: 180.ms)
        .moveY(begin: -24, end: 0, duration: 420.ms, curve: Curves.bounceOut);
  }
}

class _PinTipPainter extends CustomPainter {
  _PinTipPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PinTipPainter old) => old.color != color;
}
