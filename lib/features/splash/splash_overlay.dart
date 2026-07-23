import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

/// Studio-grade launch splash for MewSify.
///
/// 3.2 s of coordinated motion driven by ONE AnimationController:
///
///   0.00 – 0.30s   Radial vignette + diagonal sheen sweep across bg.
///   0.15 – 1.00s   Seven equalizer bars rise into the gradient tile,
///                  each with its own stagger + overshoot easing.
///   0.85 – 1.30s   Tile scales in and a soft green glow blooms.
///   1.05 – 2.60s   Three concentric ripple rings pulse outward from
///                  the tile — the "sound-wave" motion that reads as
///                  "music", not a generic app splash.
///   1.20 – 1.90s   "MewSify" wordmark reveals **one letter at a time**
///                  with a soft slide-up + fade per letter.
///   1.80 – 2.20s   Tagline fades in.
///   2.05 – 2.45s   "Created with ❤ by MOIN" credit fades in.
///   2.90 – 3.20s   Whole overlay dissolves out.
///
/// Everything renders inside a single RepaintBoundary + one Ticker —
/// one paint call per frame regardless of complexity.
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
    duration: const Duration(milliseconds: 3200),
  );

  // Bars rise 0.15-1.00s (relative: 0.047-0.313)
  late final Animation<double> _barsAppear = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.047, 0.313, curve: Curves.easeOutCubic),
  );

  // Tile scale + overshoot 0.85-1.30s (0.266-0.406)
  late final Animation<double> _tileScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.82, end: 1.06)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.06, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 20,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 45),
  ]).animate(_c);

  late final Animation<double> _tileGlow = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.30, 0.55, curve: Curves.easeOutCubic),
  );

  // Ripples run 1.05-2.60s (0.328-0.813) — plenty of time for three
  // staggered rings to complete their outward pulse.
  late final Animation<double> _ripplePhase = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.328, 0.813),
  );

  // Wordmark letters 1.20-1.90s (0.375-0.594)
  late final Animation<double> _wordmarkPhase = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.375, 0.594),
  );

  late final Animation<double> _taglineOpacity =
      CurvedAnimation(parent: _c, curve: const Interval(0.563, 0.688));
  late final Animation<double> _creditOpacity =
      CurvedAnimation(parent: _c, curve: const Interval(0.641, 0.766));

  late final Animation<double> _overlayFade = Tween<double>(
    begin: 1.0,
    end: 0.0,
  ).animate(CurvedAnimation(
    parent: _c,
    curve: const Interval(0.906, 1.0, curve: Curves.easeIn),
  ));

  late final Animation<double> _sheenT = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.0, 0.28, curve: Curves.easeInOut),
  );

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
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment.center,
                          radius: 1.4,
                          colors: [
                            Color(0xFF12181D),
                            Color(0xFF040608),
                          ],
                        ),
                      ),
                    ),
                    _Sheen(t: _sheenT.value),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 320,
                            height: 320,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // Concentric sound-wave ripples behind
                                // the logo — the "musical" touch.
                                CustomPaint(
                                  size: const Size(320, 320),
                                  painter: _RipplePainter(
                                    phase: _ripplePhase.value,
                                  ),
                                ),
                                // Gradient tile with rising bars inside.
                                Transform.scale(
                                  scale: _tileScale.value,
                                  child: _LogoTile(
                                    barsProgress: _barsAppear.value,
                                    settle: _c.value,
                                    glow: _tileGlow.value,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 22),
                          // Letter-by-letter wordmark reveal.
                          _StaggeredWordmark(phase: _wordmarkPhase.value),
                          const SizedBox(height: 12),
                          Opacity(
                            opacity: _taglineOpacity.value,
                            child: const Text(
                              'YOUR MUSIC   ·   YOUR VIBE',
                              style: TextStyle(
                                color: Color(0x88FFFFFF),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 3.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 52,
                      child: Center(
                        child: Opacity(
                          opacity: _creditOpacity.value,
                          child: const _Credit(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The gradient logo tile with the equalizer bars painted inside.
class _LogoTile extends StatelessWidget {
  final double barsProgress;
  final double settle;
  final double glow;
  const _LogoTile({
    required this.barsProgress,
    required this.settle,
    required this.glow,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 132,
      height: 132,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1DE97C), Color(0xFF0AA0AF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1DE97C).withValues(alpha: 0.18 + glow * 0.42),
            blurRadius: 32 + glow * 48,
            spreadRadius: -6 + glow * 8,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Center(
        child: CustomPaint(
          size: const Size(74, 74),
          painter: _EqBarsPainter(
            appear: barsProgress,
            settle: settle,
          ),
        ),
      ),
    );
  }
}

class _EqBarsPainter extends CustomPainter {
  final double appear;
  final double settle;
  _EqBarsPainter({required this.appear, required this.settle});

  static const _target = [0.42, 0.62, 0.86, 1.0, 0.86, 0.62, 0.42];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    const barCount = 7;
    final barWidth = size.width / (barCount * 2 - 1);
    final gap = barWidth;

    for (var i = 0; i < barCount; i++) {
      final localT = ((appear - i * 0.05) / 0.6).clamp(0.0, 1.0);
      final eased = Curves.easeOutBack.transform(localT);
      final breatheAmp = appear >= 1.0 ? 0.06 : 0.0;
      final breathe = math.sin(
              (settle * 2 * math.pi * 1.4) + (i * 0.55)) *
          breatheAmp;
      final targetH = _target[i] + breathe;
      final h = (targetH * eased).clamp(0.0, 1.0) * size.height;
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
  bool shouldRepaint(covariant _EqBarsPainter old) =>
      old.appear != appear || old.settle != settle;
}

/// Three concentric rings that pulse outward from the tile — the
/// classic "sound-wave" motif. Staggered so at any moment there's a
/// visible ring somewhere in the sequence. Fades to zero opacity as
/// each ring expands.
class _RipplePainter extends CustomPainter {
  final double phase; // 0..1
  _RipplePainter({required this.phase});

  @override
  void paint(Canvas canvas, Size size) {
    if (phase <= 0.0) return;
    final center = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      // Each ring's own 0..1 progression, staggered by 1/3 of a cycle.
      var t = (phase * 3 + i / 3) % 1.0;
      // Only show the ring during its "outward" half.
      if (t < 0.05) continue;
      final eased = Curves.easeOutCubic.transform(t);
      final radius = 70 + eased * 90;
      final opacity = (1.0 - t) * 0.35;
      final stroke = 2.4 - (t * 1.6);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.clamp(0.4, 2.4)
        ..color = const Color(0xFF1DE97C).withValues(alpha: opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter old) => old.phase != phase;
}

/// "MewSify" wordmark that reveals letter-by-letter. Each letter has
/// its own 60 ms stagger and slides up + fades in.
class _StaggeredWordmark extends StatelessWidget {
  final double phase; // 0..1 across the whole word
  const _StaggeredWordmark({required this.phase});

  static const _text = 'MewSify';

  @override
  Widget build(BuildContext context) {
    final chars = <Widget>[];
    for (var i = 0; i < _text.length; i++) {
      // Distribute each letter's window inside phase [0..1] with 60%
      // overlap so the reveal feels continuous, not choppy.
      final start = i / (_text.length + 2);
      final end = (i + 2) / (_text.length + 2);
      final t = ((phase - start) / (end - start)).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(t);
      chars.add(Opacity(
        opacity: eased,
        child: Transform.translate(
          offset: Offset(0, (1 - eased) * 18),
          child: Text(
            _text[i],
            style: const TextStyle(
              color: Colors.white,
              fontSize: 40,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.0,
              height: 1.0,
            ),
          ),
        ),
      ));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: chars,
    );
  }
}

class _Sheen extends StatelessWidget {
  final double t;
  const _Sheen({required this.t});

  @override
  Widget build(BuildContext context) {
    if (t <= 0 || t >= 1) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: FractionalTranslation(
          translation: Offset(-1.0 + 2.0 * t, -0.4 + 0.8 * t),
          child: Container(
            width: 400,
            height: 800,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.transparent,
                  const Color(0x11FFFFFF).withValues(alpha: 0.09),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Credit extends StatelessWidget {
  const _Credit();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Created with ',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.3,
          ),
        ),
        Text('❤️', style: TextStyle(fontSize: 13)),
        Text(
          ' by ',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.3,
          ),
        ),
        Text(
          'MOIN',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.4,
          ),
        ),
      ],
    );
  }
}
