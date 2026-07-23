import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

/// Full-screen splash inspired by JioSaavn / Spotify launch animations.
///
/// Runs 3.6s total, single AnimationController so the whole animation
/// is coordinated by a single ticker (cheap, no rebuild-storms):
///
///   0.00-0.60s   Logo scales from 0.7 → 1.05 (overshoot) then settles
///                to 1.0 by 0.9s. Simultaneously fades in.
///   0.55-1.20s  Wordmark slides up + fades in.
///   1.10-1.80s  Tagline / credit line fades in.
///   0.00-3.20s  Radial "pulse" behind the logo (three staggered rings
///               expand + fade) plays throughout for that music-app feel.
///   3.00-3.60s  Whole overlay dissolves out.
class SplashOverlay extends StatefulWidget {
  final Widget child;
  const SplashOverlay({super.key, required this.child});

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  );

  // Logo scale — subtle overshoot / settle motion.
  late final Animation<double> _logoScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.72, end: 1.06)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 60,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.06, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 30,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 810),
  ]).animate(_c);

  // Fade-in intervals — CurvedAnimations, cheap to build.
  late final Animation<double> _logoOpacity =
      CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.20));
  late final Animation<double> _wordmarkOpacity =
      CurvedAnimation(parent: _c, curve: const Interval(0.16, 0.34));
  late final Animation<double> _wordmarkSlide = Tween<double>(
    begin: 22,
    end: 0,
  ).animate(CurvedAnimation(
    parent: _c,
    curve: const Interval(0.16, 0.34, curve: Curves.easeOutCubic),
  ));
  late final Animation<double> _creditOpacity =
      CurvedAnimation(parent: _c, curve: const Interval(0.30, 0.52));
  late final Animation<double> _overlayFade = Tween<double>(
    begin: 1.0,
    end: 0.0,
  ).animate(CurvedAnimation(
    parent: _c,
    curve: const Interval(0.85, 1.0, curve: Curves.easeIn),
  ));

  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterNativeSplash.remove();
    });
    _c.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(
      children: [
        widget.child,
        FadeTransition(
          opacity: _overlayFade,
          child: IgnorePointer(
            child: RepaintBoundary(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.3,
                    colors: [Color(0xFF1A1F26), Color(0xFF050708)],
                  ),
                ),
                child: SizedBox.expand(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Continuous ring pulse behind the logo.
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _PulseRingPainter(_c),
                        ),
                      ),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Spacer(flex: 4),
                          FadeTransition(
                            opacity: _logoOpacity,
                            child: ScaleTransition(
                              scale: _logoScale,
                              child: const _StaticLogo(),
                            ),
                          ),
                          const SizedBox(height: 26),
                          AnimatedBuilder(
                            animation: _c,
                            builder: (_, __) => Opacity(
                              opacity: _wordmarkOpacity.value,
                              child: Transform.translate(
                                offset: Offset(0, _wordmarkSlide.value),
                                child: const Text(
                                  'MewSify',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 34,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.6,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          FadeTransition(
                            opacity: _creditOpacity,
                            child: const Text(
                              'YOUR MUSIC, YOUR VIBE',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 3.2,
                              ),
                            ),
                          ),
                          const Spacer(flex: 6),
                          FadeTransition(
                            opacity: _creditOpacity,
                            child: const _Credit(),
                          ),
                          const SizedBox(height: 44),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Three staggered rings expanding outward from the logo, at low
/// opacity. Painted every frame the controller ticks — no rebuild
/// storms because the whole overlay is inside a `RepaintBoundary`.
class _PulseRingPainter extends CustomPainter {
  final Animation<double> t;
  _PulseRingPainter(this.t) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // Only paint while the intro is in its "attention" phase — after
    // 85% of the controller runtime we're fading out and the rings
    // would just add visual noise.
    if (t.value > 0.85) return;
    for (var i = 0; i < 3; i++) {
      // Stagger each ring's phase by 1/3 of the loop.
      final phase = (t.value * 3 + i / 3) % 1.0;
      // Ease out so ring speed matches Spotify-style pulse.
      final eased = Curves.easeOut.transform(phase);
      final radius = 60 + eased * 220;
      final opacity = (1.0 - phase) * 0.25;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = const Color(0xFF1DE97C).withValues(alpha: opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PulseRingPainter old) => old.t != t;
}

/// Static logo (never repaints). Green-teal gradient tile with 7
/// equalizer bars painted once.
class _StaticLogo extends StatelessWidget {
  const _StaticLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 118,
      height: 118,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1DE97C), Color(0xFF0AA0AF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x551DE97C),
            blurRadius: 48,
            spreadRadius: -2,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: const Center(
        child: CustomPaint(
          size: Size(68, 68),
          painter: _BarsPainter(),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  const _BarsPainter();
  static const _heights = [0.40, 0.65, 0.90, 1.0, 0.90, 0.65, 0.40];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    const barCount = 7;
    final barWidth = size.width / (barCount * 2 - 1);
    final gap = barWidth;
    for (var i = 0; i < barCount; i++) {
      final h = _heights[i] * size.height;
      final x = i * (barWidth + gap);
      final y = (size.height - h) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, h),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _Credit extends StatelessWidget {
  const _Credit();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Created with ',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 13,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.3,
          ),
        ),
        Text('❤️', style: TextStyle(fontSize: 14)),
        Text(
          ' by ',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 13,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.3,
          ),
        ),
        Text(
          'MOIN',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.0,
          ),
        ),
      ],
    );
  }
}

// Kept only for import compatibility if any older file references it.
// ignore: unused_element
const _kUnusedMath = math.pi;
