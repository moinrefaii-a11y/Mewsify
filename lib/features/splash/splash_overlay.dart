import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

/// Premium launch splash for MewSify.
///
/// Design goal: clean, confident, "expensive-feeling" — closer to
/// Apple Music / Spotify launch than a busy animation. One
/// AnimationController drives the whole 2.6 s sequence. The only
/// moving painter work is a single cheap `Transform.rotate` of a conic
/// gradient (GPU transform, not a repainting CustomPaint), so it stays
/// buttery even on low-end devices.
///
/// Timeline:
///   0.00–0.55s  Disc springs in (scale + fade) while a soft conic
///               sheen rotates behind it, like light catching vinyl.
///   0.35–0.80s  The play-triangle glyph fades in at the disc centre.
///   0.55–0.95s  Wordmark rises + fades.
///   0.80–1.15s  Tagline fades.
///   0.30–2.20s  A thin accent progress line sweeps across the bottom.
///   2.30–2.60s  Whole overlay dissolves to reveal the app.
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
    duration: const Duration(milliseconds: 2600),
  );

  late final Animation<double> _discScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.6, end: 1.05)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 55,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.05, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 25,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 100),
  ]).animate(_c);

  late final Animation<double> _discFade =
      CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.22));
  late final Animation<double> _glyphFade =
      CurvedAnimation(parent: _c, curve: const Interval(0.13, 0.32));
  late final Animation<double> _wordFade =
      CurvedAnimation(parent: _c, curve: const Interval(0.21, 0.38));
  late final Animation<double> _wordRise = Tween<double>(begin: 18, end: 0)
      .animate(CurvedAnimation(
          parent: _c, curve: const Interval(0.21, 0.40, curve: Curves.easeOutCubic)));
  late final Animation<double> _tagFade =
      CurvedAnimation(parent: _c, curve: const Interval(0.31, 0.46));
  late final Animation<double> _barSweep =
      CurvedAnimation(parent: _c, curve: const Interval(0.12, 0.85, curve: Curves.easeInOut));
  late final Animation<double> _fadeOut = Tween<double>(begin: 1, end: 0)
      .animate(CurvedAnimation(
          parent: _c, curve: const Interval(0.88, 1.0, curve: Curves.easeIn)));

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
          opacity: _fadeOut,
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0, -0.15),
                      radius: 1.25,
                      colors: [Color(0xFF16201C), Color(0xFF050707)],
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Disc + glyph
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Spacer(flex: 3),
                            Opacity(
                              opacity: _discFade.value,
                              child: Transform.scale(
                                scale: _discScale.value,
                                child: _Disc(
                                  rotation: _c.value * 2 * math.pi,
                                  glyphOpacity: _glyphFade.value,
                                ),
                              ),
                            ),
                            const SizedBox(height: 32),
                            Opacity(
                              opacity: _wordFade.value,
                              child: Transform.translate(
                                offset: Offset(0, _wordRise.value),
                                child: const Text(
                                  'MewSify',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 36,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Opacity(
                              opacity: _tagFade.value,
                              child: const Text(
                                'YOUR MUSIC · YOUR VIBE',
                                style: TextStyle(
                                  color: Color(0x80FFFFFF),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 3.4,
                                ),
                              ),
                            ),
                            const Spacer(flex: 3),
                            // Thin sweeping progress line.
                            _ProgressLine(t: _barSweep.value),
                            const SizedBox(height: 28),
                            Opacity(
                              opacity: _tagFade.value * 0.9,
                              child: const _Credit(),
                            ),
                            const SizedBox(height: 40),
                          ],
                        ),
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

/// A glossy disc: green→teal gradient fill, a rotating conic sheen for
/// the "light on vinyl" effect, a dark centre label, and a play glyph.
class _Disc extends StatelessWidget {
  final double rotation;
  final double glyphOpacity;
  const _Disc({required this.rotation, required this.glyphOpacity});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer glow.
          Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1DE97C).withValues(alpha: 0.35),
                  blurRadius: 44,
                  spreadRadius: -6,
                ),
              ],
            ),
          ),
          // Rotating conic sheen — cheap GPU transform.
          Transform.rotate(
            angle: rotation,
            child: Container(
              width: 132,
              height: 132,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    Color(0xFF0AA0AF),
                    Color(0xFF1DE97C),
                    Color(0xFF0AA0AF),
                    Color(0xFF127C6A),
                    Color(0xFF0AA0AF),
                  ],
                  stops: [0.0, 0.25, 0.5, 0.75, 1.0],
                ),
              ),
            ),
          ),
          // Dark centre label.
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0B0E0D),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 1,
              ),
            ),
          ),
          // Centre spindle dot.
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF1DE97C),
            ),
          ),
          // Play glyph fading in over the label.
          Opacity(
            opacity: glyphOpacity,
            child: const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 30),
            ),
          ),
        ],
      ),
    );
  }
}

/// A thin horizontal line with a bright accent segment sweeping across
/// it — reads as a premium "loading" bar without a spinner.
class _ProgressLine extends StatelessWidget {
  final double t; // 0..1
  const _ProgressLine({required this.t});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      height: 2,
      child: Stack(
        children: [
          Container(color: Colors.white.withValues(alpha: 0.08)),
          Align(
            alignment: Alignment(-1 + 2 * t, 0),
            child: Container(
              width: 46,
              height: 2,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [
                  Color(0x001DE97C),
                  Color(0xFF1DE97C),
                  Color(0x000AA0AF),
                ]),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ],
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
        Text('Created with ',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
        Text('❤️', style: TextStyle(fontSize: 12)),
        Text(' by ', style: TextStyle(color: Colors.white38, fontSize: 12)),
        Text('MOIN',
            style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5)),
      ],
    );
  }
}
