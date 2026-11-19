import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

/// Switches the app's theme with a circular "reveal" that spreads out from
/// the button that was tapped.
///
/// How it works:
/// 1. The current frame is captured from a [RepaintBoundary] as an image.
/// 2. The image is laid over the app, and the real theme change is applied
///    underneath it.
/// 3. A circular hole is cut in the screenshot and grown until it covers the
///    screen, so the new theme appears to wash outward from the tap.
///
/// Doing it with a snapshot means every widget (including the map) switches
/// in one frame underneath, instead of each one lerping colours separately.
class ThemeReveal extends StatefulWidget {
  const ThemeReveal({super.key, required this.child});

  final Widget child;

  /// Finds the nearest [ThemeRevealState]. Place [ThemeReveal] in
  /// `MaterialApp.builder` so every route can reach it.
  static ThemeRevealState of(BuildContext context) =>
      context.findAncestorStateOfType<ThemeRevealState>()!;

  @override
  State<ThemeReveal> createState() => ThemeRevealState();
}

class ThemeRevealState extends State<ThemeReveal>
    with SingleTickerProviderStateMixin {
  final _boundaryKey = GlobalKey();
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) _clearSnapshot();
    });

  ui.Image? _snapshot;
  Offset _origin = Offset.zero;

  /// Runs [applyChange] behind a reveal centred on [origin] (global
  /// coordinates). With [animate] false the change is applied immediately,
  /// which is what reduced-motion and battery-saver modes ask for.
  Future<void> reveal({
    required Offset origin,
    required VoidCallback applyChange,
    bool animate = true,
  }) async {
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (!animate || boundary is! RenderRepaintBoundary || _controller.isAnimating) {
      applyChange();
      return;
    }
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final ui.Image image;
    try {
      image = await boundary.toImage(pixelRatio: pixelRatio);
    } catch (_) {
      // Some web renderers can't snapshot cross-origin content; fall back to
      // an instant switch rather than failing the tap.
      applyChange();
      return;
    }
    if (!mounted) return;
    setState(() {
      _snapshot = image;
      _origin = origin;
    });
    applyChange();
    await _controller.forward(from: 0);
  }

  void _clearSnapshot() {
    final old = _snapshot;
    setState(() => _snapshot = null);
    old?.dispose();
  }

  @override
  void dispose() {
    _controller.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _boundaryKey, child: widget.child),
        if (snapshot != null)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final t = Curves.easeInOutCubic.transform(_controller.value);
                return ClipPath(
                  clipper: _HoleClipper(center: _origin, progress: t),
                  child: RawImage(image: snapshot, fit: BoxFit.fill),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Clips to "everything except a circle", so the old screenshot stays visible
/// outside the growing circle and the new theme shows through inside it.
class _HoleClipper extends CustomClipper<Path> {
  _HoleClipper({required this.center, required this.progress});

  final Offset center;
  final double progress;

  @override
  Path getClip(Size size) {
    // The circle must end up covering the farthest corner from the tap.
    final corners = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ];
    final maxRadius = corners.map((c) => (c - center).distance).reduce(math.max);
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: center, radius: maxRadius * progress));
  }

  @override
  bool shouldReclip(_HoleClipper old) =>
      old.progress != progress || old.center != center;
}
