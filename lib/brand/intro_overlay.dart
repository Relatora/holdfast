/// The animated intro shown over the app as it starts.
///
/// A short story in four seconds, drawn with the same painter as the icon:
/// 1. The contour lines of a map draw themselves outward.
/// 2. A sun flares at the top of the screen and throws a shockwave down
///    across it: a coronal mass ejection. The contour lines shake as it
///    passes, the way a solar storm shakes the power grid.
/// 3. A Faraday cage closes over a beacon, which lights up and keeps
///    sending: what's shielded comes through.
/// 4. The name, then why the app exists.
///
/// The system's static splash (flutter_native_splash) shows the same slate
/// background and mark before Flutter starts, so the hand-over is seamless.
///
/// Tap, click or press any key to continue; it also moves on by itself
/// once the message has had time to be read. With reduced motion (or
/// battery saver) the finished frame shows at once. Night vision turns it
/// red, like the rest of the app. A Settings switch turns it off.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'holdfast_mark.dart';

/// The intro's words. Kept here, plain, so they read the same in the
/// widget and its tests.
abstract final class IntroText {
  static const message = 'Until the next Carrington event, a solar storm big enough to take down power grids '
      'and satellites, Holdfast fills the gap: maps, hazards and directions that work with no signal.';
  static const ps = 'P.S. Keep a spare phone or radio in a Faraday cage, a sealed metal box, and it comes '
      'through untouched.';
  static const hint = 'Tap or press any key to continue';
}

class IntroOverlay extends StatefulWidget {
  const IntroOverlay({
    super.key,
    required this.child,
    required this.enabled,
    required this.animate,
    this.nightVision = false,
    this.readingTime = const Duration(seconds: 7),
  });

  /// The app, which builds and loads underneath while the intro plays.
  final Widget child;

  /// Off in Settings: the app shows straight away.
  final bool enabled;

  /// False under reduced motion or battery saver: the finished frame only.
  final bool animate;
  final bool nightVision;

  /// How long the finished intro stays up before moving on by itself.
  final Duration readingTime;

  @override
  State<IntroOverlay> createState() => _IntroOverlayState();
}

class _IntroOverlayState extends State<IntroOverlay> with TickerProviderStateMixin {
  static const _story = Duration(milliseconds: 4200);

  late final AnimationController _play = AnimationController(vsync: this, duration: _story);
  late final AnimationController _exit = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  Timer? _autoDismiss;
  late bool _showing = widget.enabled;

  @override
  void initState() {
    super.initState();
    if (!_showing) return;
    HardwareKeyboard.instance.addHandler(_onKey);
    if (!widget.animate) {
      _play.value = 1;
      _autoDismiss = Timer(widget.readingTime, _dismiss);
      return;
    }
    // Start once the first frame is on screen: the app is busy building
    // the map underneath until then, and the opening of the story would
    // be lost to that first, slow frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showing) return;
      _play.forward();
      _autoDismiss = Timer(_story + widget.readingTime, _dismiss);
    });
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _play.dispose();
    _exit.dispose();
    super.dispose();
  }

  /// Any key continues, and is swallowed so it doesn't also reach the map.
  bool _onKey(KeyEvent event) {
    if (!_showing) return false;
    if (event is KeyDownEvent) _dismiss();
    return true;
  }

  Future<void> _dismiss() async {
    if (!_showing || _exit.isAnimating) return;
    _autoDismiss?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (widget.animate) await _exit.forward();
    if (mounted) setState(() => _showing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_showing) return widget.child;
    Widget intro = AnimatedBuilder(
      animation: Listenable.merge([_play, _exit]),
      builder: (context, _) => Opacity(
        opacity: 1 - _exit.value,
        child: _IntroFrame(t: _play.value * _story.inMilliseconds / 1000, onContinue: _dismiss),
      ),
    );
    if (widget.nightVision) {
      // Red only: keep everything's brightness, drop green and blue.
      intro = ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          0.5, 0.4, 0.1, 0, 0, //
          0, 0, 0, 0, 0,
          0, 0, 0, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: intro,
      );
    }
    return Stack(
      textDirection: TextDirection.ltr,
      children: [widget.child, Positioned.fill(child: intro)],
    );
  }
}

/// Where each beat of the story sits on the timeline, in seconds, eased.
double _beat(double t, double start, double end, [Curve curve = Curves.easeOutCubic]) =>
    curve.transform(((t - start) / (end - start)).clamp(0.0, 1.0));

/// One frame of the intro at [t] seconds.
class _IntroFrame extends StatelessWidget {
  const _IntroFrame({required this.t, required this.onContinue});

  final double t;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final markSize = math.min(260.0, math.min(size.width * 0.55, size.height * 0.32));
    // The shockwave front, as a fraction of the way across the screen.
    final wave = _beat(t, 0.7, 2.3, Curves.easeInOutSine);
    // The storm disturbs the contours while the front crosses the mark.
    final markDepth = 0.45; // the mark's centre, as a fraction of the height
    final flicker = wave <= 0 || wave >= 1 ? 0.0 : math.exp(-math.pow((wave - markDepth) / 0.12, 2));

    final progress = MarkProgress(
      contours: _beat(t, 0, 1.3, Curves.easeOut),
      cage: _beat(t, 1.4, 2.4),
      beacon: _beat(t, 2.1, 2.6),
      signal: _beat(t, 2.3, 3.0),
      flicker: flicker.toDouble(),
    );
    final word = _beat(t, 2.5, 3.1);
    final message = _beat(t, 2.9, 3.6);
    final ps = _beat(t, 3.4, 4.1);
    final hint = _beat(t, 3.9, 4.2);

    final bodyStyle = TextStyle(
      fontFamily: 'Barlow',
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 1.45,
      color: MarkColors.cage.withValues(alpha: 0.92),
      decoration: TextDecoration.none,
    );

    return Semantics(
      button: true,
      label: 'Holdfast. ${IntroText.message} ${IntroText.ps}',
      excludeSemantics: true,
      onTap: onContinue,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onContinue,
        child: ColoredBox(
          color: MarkColors.slate,
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _StormPainter(t: t, wave: wave))),
              SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          HoldfastMark(size: markSize, progress: progress, layers: MarkLayers.splash),
                          const SizedBox(height: 18),
                          // The name sets in from wide letter spacing, like
                          // a stencil being lowered into place.
                          Opacity(
                            opacity: word,
                            child: Text(
                              'HOLDFAST',
                              style: TextStyle(
                                fontFamily: 'Barlow Condensed',
                                fontWeight: FontWeight.w700,
                                fontSize: 40,
                                letterSpacing: 4 + 14 * (1 - word),
                                color: MarkColors.cage,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          _Reveal(
                            value: message,
                            child: Text(IntroText.message, textAlign: TextAlign.center, style: bodyStyle),
                          ),
                          const SizedBox(height: 14),
                          _Reveal(
                            value: ps,
                            child: Text(
                              IntroText.ps,
                              textAlign: TextAlign.center,
                              style: bodyStyle.copyWith(
                                fontSize: 14,
                                fontStyle: FontStyle.italic,
                                color: MarkColors.beacon.withValues(alpha: 0.9),
                              ),
                            ),
                          ),
                          const SizedBox(height: 28),
                          Opacity(
                            opacity: hint * 0.6,
                            child: Text(IntroText.hint, style: bodyStyle.copyWith(fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fades a paragraph in while it rises a few pixels.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.value, required this.child});
  final double value;
  final Widget child;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: value,
        child: Transform.translate(offset: Offset(0, 10 * (1 - value)), child: child),
      );
}

/// The sun above the top edge and the shockwave it throws.
class _StormPainter extends CustomPainter {
  _StormPainter({required this.t, required this.wave});

  /// Seconds since the start.
  final double t;

  /// The shockwave front, 0 (at the sun) to 1 (off the bottom edge).
  final double wave;

  @override
  void paint(Canvas canvas, Size size) {
    final sun = Offset(size.width / 2, -size.height * 0.1);
    final reach = size.height * 1.25;

    // The sun: a glow that swells as it flares, then settles.
    final flare = _beat(t, 0.3, 0.9) * (1 - 0.6 * _beat(t, 1.6, 3.0));
    if (flare > 0) {
      final radius = size.width * (0.35 + 0.25 * flare);
      canvas.drawCircle(
        sun,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(sun, radius, [
            const Color(0xFFFFE6A8).withValues(alpha: 0.55 * flare),
            MarkColors.beacon.withValues(alpha: 0.22 * flare),
            MarkColors.beacon.withValues(alpha: 0),
          ], [0, 0.35, 1]),
      );
    }

    if (wave <= 0 || wave >= 1) return;
    final front = reach * wave;
    final fade = 1 - wave;

    // Streaks of plasma racing ahead along the front.
    final rays = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.6;
    for (var i = 0; i < 28; i++) {
      final a = math.pi * (0.12 + 0.76 * i / 27);
      final jitter = math.sin(i * 12.9898) * 0.5 + 0.5;
      final r1 = front * (0.82 + 0.1 * jitter), r2 = front * (0.98 + 0.04 * jitter);
      rays.color = const Color(0xFFFFE6A8).withValues(alpha: 0.55 * fade * jitter);
      canvas.drawLine(sun + Offset.fromDirection(a, r1), sun + Offset.fromDirection(a, r2), rays);
    }

    // The shock front: a bright arc with a soft trailing glow.
    final rect = Rect.fromCircle(center: sun, radius: front);
    canvas.drawArc(
      rect,
      0,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 34
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22)
        ..color = MarkColors.beacon.withValues(alpha: 0.5 * fade),
    );
    canvas.drawArc(
      rect,
      0,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFFFFF4D6).withValues(alpha: 0.95 * fade),
    );
  }

  @override
  bool shouldRepaint(_StormPainter old) => old.t != t;
}
