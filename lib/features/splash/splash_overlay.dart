import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

/// Lean splash. The native splash already showed during cold start;
/// this overlay only adds the brand wordmark + your credit and a
/// short fade-out so we don't keep a heavy animated layer alive
/// once the app is interactive.
///
/// We deliberately avoid continuous CustomPaint animations here —
/// they're cheap on real phones but visibly stutter on emulators.
/// 1.6s total, then fades.
class SplashOverlay extends StatefulWidget {
  final Widget child;
  const SplashOverlay({super.key, required this.child});

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  late final Animation<double> _logoScale = Tween<double>(begin: 0.92, end: 1.0)
      .animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.5, curve: Curves.easeOutCubic)));
  late final Animation<double> _logoFade =
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.35));
  late final Animation<double> _wordFade =
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.30, 0.65));
  late final Animation<double> _creditFade =
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.55, 0.85));
  late final Animation<double> _exitFade = Tween<double>(begin: 1.0, end: 0.0)
      .animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.85, 1.0, curve: Curves.easeOut)));

  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterNativeSplash.remove();
    });
    _ctrl.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            return IgnorePointer(
              ignoring: _exitFade.value < 0.05,
              child: Opacity(
                opacity: _exitFade.value,
                child: const _SplashScene(),
              ),
            );
          },
        ),
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            if (_exitFade.value < 0.05) return const SizedBox.shrink();
            return IgnorePointer(
              child: Opacity(
                opacity: _exitFade.value,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Spacer(flex: 5),
                      // Logo: single transform per frame, no painter loop
                      FadeTransition(
                        opacity: _logoFade,
                        child: ScaleTransition(
                          scale: _logoScale,
                          child: const _StaticLogo(),
                        ),
                      ),
                      const SizedBox(height: 28),
                      FadeTransition(
                        opacity: _wordFade,
                        child: const Text(
                          'MewSify',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      FadeTransition(
                        opacity: _wordFade,
                        child: const Text(
                          'where the music meets you',
                          style: TextStyle(
                            color: Color(0xFF9DA2A8),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      const Spacer(flex: 7),
                      FadeTransition(
                        opacity: _creditFade,
                        child: const _Credit(),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Static dark backdrop. No painter, just two-stop gradient.
class _SplashScene extends StatelessWidget {
  const _SplashScene();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          radius: 1.0,
          colors: [Color(0xFF14181A), Color(0xFF050608)],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

/// Static logo tile — single gradient + a single SVG-style arrangement.
/// Cheap to render: no animation, no painter tick.
class _StaticLogo extends StatelessWidget {
  const _StaticLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 116,
      height: 116,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1DE97C), Color(0xFF0AA0AF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x551DE97C),
            blurRadius: 32,
            spreadRadius: -4,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Center(
        child: CustomPaint(
          size: const Size(72, 72),
          painter: _StaticBarsPainter(),
        ),
      ),
    );
  }
}

/// Single-pass painter — no animation tick, only paints once per build.
class _StaticBarsPainter extends CustomPainter {
  static const _heights = [0.45, 0.72, 0.95, 0.55, 0.95, 0.72, 0.45];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    const barCount = 7;
    final barWidth = size.width / (barCount * 2 - 1);
    final spacing = barWidth;
    for (var i = 0; i < barCount; i++) {
      final h = _heights[i] * size.height;
      final x = i * (barWidth + spacing);
      final y = (size.height - h) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, h),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

class _Credit extends StatelessWidget {
  const _Credit();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        Text(
          'Created with',
          style: TextStyle(
            color: Colors.white60,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.4,
          ),
        ),
        SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('❤️ ', style: TextStyle(fontSize: 16)),
            Text(
              'by ',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              'MOIN',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w900,
                letterSpacing: 2.5,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
