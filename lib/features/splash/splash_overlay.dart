import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

/// Minimal, premium launch splash.
///
/// Deliberately restrained — the way Apple / Spotify launch: the real
/// app icon, a soft glow, a clean wordmark, and a thin indeterminate
/// loading bar. No hand-drawn shapes, no busy motion. Background matches
/// the native splash colour (#0F0F10) so there's zero flash on handoff.
///
/// One AnimationController, 1.9 s:
///   0.00–0.45s  Icon scales up (0.82→1.0) + fades in, glow blooms.
///   0.30–0.60s  Wordmark rises + fades.
///   0.45–0.70s  Tagline fades.
///   0.15–1.55s  Thin loading bar sweeps.
///   1.60–1.90s  Overlay dissolves to reveal the app.
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
    duration: const Duration(milliseconds: 1900),
  );

  late final Animation<double> _iconScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.82, end: 1.03)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.03, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 20,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 100),
  ]).animate(_c);

  late final Animation<double> _iconFade =
      CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.24));
  late final Animation<double> _glow =
      CurvedAnimation(parent: _c, curve: const Interval(0.10, 0.45));
  late final Animation<double> _wordFade =
      CurvedAnimation(parent: _c, curve: const Interval(0.16, 0.34));
  late final Animation<double> _wordRise = Tween<double>(begin: 16, end: 0)
      .animate(CurvedAnimation(
          parent: _c,
          curve: const Interval(0.16, 0.36, curve: Curves.easeOutCubic)));
  late final Animation<double> _tagFade =
      CurvedAnimation(parent: _c, curve: const Interval(0.26, 0.44));
  late final Animation<double> _barSweep = CurvedAnimation(
      parent: _c, curve: const Interval(0.08, 0.82, curve: Curves.easeInOut));
  late final Animation<double> _fadeOut = Tween<double>(begin: 1, end: 0)
      .animate(CurvedAnimation(
          parent: _c, curve: const Interval(0.84, 1.0, curve: Curves.easeIn)));

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
                builder: (context, _) => Container(
                  color: const Color(0xFF0F0F10),
                  child: Column(
                    children: [
                      const Spacer(flex: 5),
                      Opacity(
                        opacity: _iconFade.value,
                        child: Transform.scale(
                          scale: _iconScale.value,
                          child: Container(
                            width: 116,
                            height: 116,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(28),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF1DE97C)
                                      .withValues(alpha: 0.30 * _glow.value),
                                  blurRadius: 48,
                                  spreadRadius: -4,
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(28),
                              child: Image.asset(
                                'assets/images/app_icon.png',
                                width: 116,
                                height: 116,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Opacity(
                        opacity: _wordFade.value,
                        child: Transform.translate(
                          offset: Offset(0, _wordRise.value),
                          child: const Text(
                            'MewSify',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 34,
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
                            letterSpacing: 3.2,
                          ),
                        ),
                      ),
                      const Spacer(flex: 4),
                      _LoadingBar(t: _barSweep.value),
                      const SizedBox(height: 30),
                      Opacity(
                        opacity: _tagFade.value * 0.9,
                        child: const _Credit(),
                      ),
                      const SizedBox(height: 42),
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

class _LoadingBar extends StatelessWidget {
  final double t;
  const _LoadingBar({required this.t});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 2,
      child: Stack(
        children: [
          Container(color: Colors.white.withValues(alpha: 0.08)),
          Align(
            alignment: Alignment(-1 + 2 * t, 0),
            child: Container(
              width: 44,
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
