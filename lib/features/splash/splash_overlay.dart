import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

/// Premium splash overlay inspired by Spotify's clean approach.
///
/// Sequence (1.6s total):
///   0–500ms   Logo scales + fades in
///   300–650ms "MewSify" wordmark fades in
///   550–850ms Credit line fades in
///   850–1400ms Hold
///   1400–1600ms Entire overlay fades out
///
/// No continuous CustomPaint loops — only standard Flutter transitions.
class SplashOverlay extends StatefulWidget {
  final Widget child;
  const SplashOverlay({super.key, required this.child});

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  // Logo: scale from 0.85 → 1.0 and fade in over 0–500ms
  late final Animation<double> _logoScale = Tween<double>(
    begin: 0.85,
    end: 1.0,
  ).animate(CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.3125, curve: Curves.easeOutCubic),
  ));

  late final Animation<double> _logoOpacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.3125, curve: Curves.easeOut),
  );

  // Wordmark: fade in over 300–650ms
  late final Animation<double> _wordmarkOpacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.1875, 0.40625, curve: Curves.easeOut),
  );

  // Credit: fade in over 550–850ms
  late final Animation<double> _creditOpacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.34375, 0.53125, curve: Curves.easeOut),
  );

  // Whole overlay fades out over 1400–1600ms
  late final Animation<double> _overlayOpacity = Tween<double>(
    begin: 1.0,
    end: 0.0,
  ).animate(CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.875, 1.0, curve: Curves.easeOut),
  ));

  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterNativeSplash.remove();
    });
    _controller.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;

    return Stack(
      children: [
        widget.child,
        FadeTransition(
          opacity: _overlayOpacity,
          child: IgnorePointer(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.2,
                  colors: [Color(0xFF1A1E22), Color(0xFF060809)],
                ),
              ),
              child: Column(
                children: [
                  const Spacer(flex: 4),
                  // Logo
                  FadeTransition(
                    opacity: _logoOpacity,
                    child: ScaleTransition(
                      scale: _logoScale,
                      child: const _StaticLogo(),
                    ),
                  ),
                  const SizedBox(height: 28),
                  // Wordmark
                  FadeTransition(
                    opacity: _wordmarkOpacity,
                    child: const Text(
                      'MewSify',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const Spacer(flex: 5),
                  // Credit
                  FadeTransition(
                    opacity: _creditOpacity,
                    child: const _Credit(),
                  ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Static logo — green-to-teal gradient container with white bars
/// painted once by a CustomPainter that never repaints.
class _StaticLogo extends StatelessWidget {
  const _StaticLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 112,
      height: 112,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1DE97C), Color(0xFF0AA0AF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x401DE97C),
            blurRadius: 40,
            spreadRadius: -2,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Center(
        child: CustomPaint(
          size: const Size(64, 64),
          painter: const _BarsPainter(),
        ),
      ),
    );
  }
}

/// Paints 7 white rounded bars at fixed heights. Never repaints.
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
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// "Created with heart by MOIN" credit widget.
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
