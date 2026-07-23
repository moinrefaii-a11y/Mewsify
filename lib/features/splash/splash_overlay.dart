import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

/// Studio-grade launch splash for MewSify.
///
/// A single AnimationController drives the whole timeline (2.8 s):
///
///   0.00 - 0.30s  A muted gradient sheen sweeps across the dark
///                 background so the screen doesn't feel dead.
///   0.20 - 1.05s  Seven equalizer bars rise from zero, each with its
///                 own delay + easing, forming the EQ mark. They
///                 continue to breathe on a low-amplitude sine wave
///                 so the icon feels alive rather than frozen.
///   0.85 - 1.30s  The bars glide into a rounded tile and a soft green
///                 glow pulses out from behind them (implicit — done
///                 via the container's box-shadow spread animating).
///   1.20 - 1.75s  Wordmark "MewSify" fades in from below with a
///                 shimmer sweep left-to-right across the letters.
///   1.60 - 2.10s  Tagline reveals under the wordmark.
///   1.90 - 2.30s  "Created by MOIN" credit reveals.
///   2.55 - 2.80s  Whole overlay fades out, revealing the app.
///
/// Everything is rendered inside a single RepaintBoundary + backed by
/// one Ticker, so the whole scene is one draw call per frame.
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
    duration: const Duration(milliseconds: 2800),
  );

  // The bars themselves rise between 200 ms and 1050 ms.
  late final Animation<double> _barsAppear = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.07, 0.375, curve: Curves.easeOutCubic),
  );

  // Container "settle" — the rounded tile that houses the bars.
  late final Animation<double> _tileScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.85, end: 1.05)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.05, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 20,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 45),
  ]).animate(_c);

  late final Animation<double> _tileGlow = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.30, 0.55, curve: Curves.easeOutCubic),
  );

  late final Animation<double> _wordmarkOpacity =
      CurvedAnimation(parent: _c, curve: const Interval(0.42, 0.62));
  late final Animation<double> _wordmarkSlide = Tween<double>(
    begin: 24,
    end: 0,
  ).animate(CurvedAnimation(
    parent: _c,
    curve: const Interval(0.42, 0.62, curve: Curves.easeOutCubic),
  ));

  late final Animation<double> _shimmerT = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.48, 0.75, curve: Curves.easeInOut),
  );

  late final Animation<double> _taglineOpacity =
      CurvedAnimation(parent: _c, curve: const Interval(0.58, 0.78));
  late final Animation<double> _creditOpacity =
      CurvedAnimation(parent: _c, curve: const Interval(0.66, 0.85));

  late final Animation<double> _overlayFade = Tween<double>(
    begin: 1.0,
    end: 0.0,
  ).animate(CurvedAnimation(
    parent: _c,
    curve: const Interval(0.91, 1.0, curve: Curves.easeIn),
  ));

  // Sheen sweep (subtle diagonal highlight).
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
                    // Deep, cool-toned base.
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
                    // Diagonal sheen sweep.
                    _Sheen(t: _sheenT.value),
                    // Main content column.
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Transform.scale(
                            scale: _tileScale.value,
                            child: _LogoTile(
                              barsProgress: _barsAppear.value,
                              settle: _c.value,
                              glow: _tileGlow.value,
                            ),
                          ),
                          const SizedBox(height: 34),
                          Opacity(
                            opacity: _wordmarkOpacity.value,
                            child: Transform.translate(
                              offset: Offset(0, _wordmarkSlide.value),
                              child: _Wordmark(shimmer: _shimmerT.value),
                            ),
                          ),
                          const SizedBox(height: 10),
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
                    // "Created by MOIN" pinned near the bottom.
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
/// The bars themselves are painted by [_EqBarsPainter] which factors
/// in both a rise-in animation ([barsProgress]) and a low-amplitude
/// breathing motion driven by the parent controller's raw [settle].
class _LogoTile extends StatelessWidget {
  final double barsProgress; // 0..1 rise-in
  final double settle; // 0..1 overall controller value (for breathing)
  final double glow; // 0..1 halo intensity
  const _LogoTile({
    required this.barsProgress,
    required this.settle,
    required this.glow,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 128,
      height: 128,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1DE97C), Color(0xFF0AA0AF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1DE97C).withValues(alpha: 0.15 + glow * 0.35),
            blurRadius: 30 + glow * 40,
            spreadRadius: -6 + glow * 6,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Center(
        child: CustomPaint(
          size: const Size(72, 72),
          painter: _EqBarsPainter(
            appear: barsProgress,
            settle: settle,
          ),
        ),
      ),
    );
  }
}

/// Seven bars that rise from zero, each with its own stagger, and
/// after they've settled continue to gently breathe on a sine wave.
class _EqBarsPainter extends CustomPainter {
  final double appear; // 0..1
  final double settle; // 0..1 (raw controller value)
  _EqBarsPainter({required this.appear, required this.settle});

  static const _target = [0.42, 0.62, 0.86, 1.0, 0.86, 0.62, 0.42];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    const barCount = 7;
    final barWidth = size.width / (barCount * 2 - 1);
    final gap = barWidth;

    for (var i = 0; i < barCount; i++) {
      // Stagger: earlier bars rise first.
      final localT =
          ((appear - i * 0.05) / 0.6).clamp(0.0, 1.0);
      final eased = Curves.easeOutBack.transform(localT);
      // Once appear is done, add a breathing wobble.
      final breatheAmp = appear >= 1.0 ? 0.05 : 0.0;
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

/// Diagonal gradient sheen that sweeps across the whole screen while
/// the logo assembles.
class _Sheen extends StatelessWidget {
  final double t; // 0..1
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
                  const Color(0x11FFFFFF).withValues(alpha: 0.08),
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

/// "MewSify" wordmark with a shimmer highlight sweeping across the
/// letters as it fades in.
class _Wordmark extends StatelessWidget {
  final double shimmer; // 0..1
  const _Wordmark({required this.shimmer});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (rect) {
        // A soft white streak that travels left→right across the text.
        final phase = (shimmer * 1.6) - 0.3;
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: [
            (phase - 0.2).clamp(0.0, 1.0),
            phase.clamp(0.0, 1.0),
            (phase + 0.2).clamp(0.0, 1.0),
          ],
          colors: const [
            Color(0xFFFFFFFF),
            Color(0xFFCFEEDA),
            Color(0xFFFFFFFF),
          ],
        ).createShader(rect);
      },
      child: const Text(
        'MewSify',
        style: TextStyle(
          color: Colors.white,
          fontSize: 40,
          fontWeight: FontWeight.w900,
          letterSpacing: -1.0,
          height: 1.0,
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
