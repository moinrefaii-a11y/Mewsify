import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

/// Cinematic splash. 4-second total runtime, then fades out.
///
/// Layers (back → front):
///   1. Pure-black backdrop with a soft radial accent that breathes.
///   2. **Flowing waveform field** — three sine curves at different
///      speeds, opacities, and amplitudes. Spotify's "now playing"
///      lyrics page uses the same trick.
///   3. The brand tile, which softly scales from 0.85 to a confident
///      1.18 over the entire animation, ending bigger than it started.
///   4. Wordmark + tagline + bottom credit, all eased in cleanly.
class SplashOverlay extends StatefulWidget {
  final Widget child;
  const SplashOverlay({super.key, required this.child});

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl; // entrance + steady, 4 seconds
  late final AnimationController _exit; // fade-out
  late final AnimationController _wavesCtrl; // continuous wave loop

  bool _done = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    );
    _exit = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _wavesCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterNativeSplash.remove();
    });

    _ctrl.forward().whenComplete(() async {
      if (!mounted) return;
      await _exit.forward();
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _exit.dispose();
    _wavesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (!_done)
          AnimatedBuilder(
            animation: Listenable.merge([_ctrl, _exit, _wavesCtrl]),
            builder: (_, __) {
              final fade = 1.0 - Curves.easeInCubic.transform(_exit.value);
              return IgnorePointer(
                ignoring: fade < 0.05,
                child: Opacity(
                  opacity: fade,
                  child: _SplashScene(
                    t: _ctrl.value,
                    waveT: _wavesCtrl.value,
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _SplashScene extends StatelessWidget {
  /// Main timeline progress 0..1.
  final double t;

  /// Continuous wave-loop value 0..1 — independent of the entrance
  /// timeline so the waves keep flowing even after the entrance ends.
  final double waveT;

  const _SplashScene({required this.t, required this.waveT});

  static const _accent = Color(0xFF1DE97C);
  static const _accentDeep = Color(0xFF0AA0AF);

  double _seg(double from, double to, [Curve curve = Curves.easeOutCubic]) {
    final raw = ((t - from) / (to - from)).clamp(0.0, 1.0);
    return curve.transform(raw);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    final bgFade = _seg(0.0, 0.25);
    // Logo grows continuously from 0.85 → 1.18 over the whole timeline,
    // so it visually "lands bigger" — same effect as Apple's launch.
    final logoScale = 0.85 + 0.33 * _seg(0.05, 1.0, Curves.easeOutQuart);
    final logoFade = _seg(0.05, 0.25);
    final wordY = 16.0 * (1.0 - _seg(0.30, 0.65, Curves.easeOutQuart));
    final wordFade = _seg(0.30, 0.65);
    final tagFade = _seg(0.45, 0.75);
    final creditFade = _seg(0.65, 0.95);

    return Container(
      color: Color.lerp(Colors.black, const Color(0xFF050608), bgFade),
      child: Stack(
        children: [
          // Soft radial accent (breathing center glow)
          Positioned.fill(
            child: CustomPaint(
              painter: _RadialGlow(
                center: Offset(size.width / 2, size.height * 0.42),
                color: _accent.withValues(alpha: 0.18 * bgFade),
              ),
            ),
          ),

          // Flowing waveform background
          Positioned.fill(
            child: CustomPaint(
              painter: _WaveformBackdrop(
                progress: waveT,
                appear: bgFade,
                accent: _accent,
                accentDeep: _accentDeep,
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  const Spacer(flex: 5),

                  // Logo tile (scales, fades, bars draw inside)
                  Opacity(
                    opacity: logoFade,
                    child: Transform.scale(
                      scale: logoScale,
                      child: SizedBox(
                        width: 132,
                        height: 132,
                        child: _LogoTile(progress: t, waveT: waveT),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Wordmark
                  Opacity(
                    opacity: wordFade,
                    child: Transform.translate(
                      offset: Offset(0, wordY),
                      child: const Text(
                        'MewSify',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 34,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.6,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Tagline
                  Opacity(
                    opacity: tagFade,
                    child: const Text(
                      'where the music meets you',
                      style: TextStyle(
                        color: Color(0xFFA3A8AE),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),

                  const Spacer(flex: 7),

                  // Credit — "Created with love by Moin" in white
                  Opacity(
                    opacity: creditFade,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 32),
                      child: Column(
                        children: [
                          const Text(
                            'Created with',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 1.4,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Text('❤️ ', style: TextStyle(fontSize: 18)),
                              Text(
                                'by ',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.4,
                                ),
                              ),
                              Text(
                                'MOIN',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 3.0,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Three sine waves stacked; each scrolls horizontally at a different
/// rate and with a different opacity. Together they paint a soft
/// "flowing music" backdrop.
class _WaveformBackdrop extends CustomPainter {
  final double progress; // 0..1 looping
  final double appear; // 0..1 fade-in for the whole field
  final Color accent;
  final Color accentDeep;

  _WaveformBackdrop({
    required this.progress,
    required this.appear,
    required this.accent,
    required this.accentDeep,
  });

  static const _layers = [
    _WaveLayer(speed: 1.0, ampRatio: 0.10, freq: 1.6, opacity: 0.25, accent: 0),
    _WaveLayer(speed: -0.7, ampRatio: 0.07, freq: 2.4, opacity: 0.20, accent: 1),
    _WaveLayer(speed: 1.4, ampRatio: 0.05, freq: 3.6, opacity: 0.16, accent: 0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (appear < 0.01) return;
    final centerY = size.height * 0.42;

    for (final layer in _layers) {
      final paint = Paint()
        ..color = (layer.accent == 0 ? accent : accentDeep)
            .withValues(alpha: layer.opacity * appear)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.6;

      final amp = size.height * layer.ampRatio;
      final phase = progress * 2 * pi * layer.speed;
      final path = Path();
      final step = 6.0;
      for (var x = -10.0; x < size.width + 10; x += step) {
        final y = centerY +
            sin((x / size.width) * 2 * pi * layer.freq + phase) * amp;
        if (x == -10) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformBackdrop old) =>
      old.progress != progress || old.appear != appear;
}

class _WaveLayer {
  final double speed;
  final double ampRatio;
  final double freq;
  final double opacity;
  final int accent;
  const _WaveLayer({
    required this.speed,
    required this.ampRatio,
    required this.freq,
    required this.opacity,
    required this.accent,
  });
}

/// Soft radial glow centered behind the logo.
class _RadialGlow extends CustomPainter {
  final Offset center;
  final Color color;
  _RadialGlow({required this.center, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0.0)],
      ).createShader(Rect.fromCircle(center: center, radius: 320));
    canvas.drawCircle(center, 320, paint);
  }

  @override
  bool shouldRepaint(_RadialGlow old) => old.color != color || old.center != center;
}

/// The brand tile with continuously-animated EQ bars and a glow.
class _LogoTile extends StatelessWidget {
  final double progress;
  final double waveT;
  const _LogoTile({required this.progress, required this.waveT});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1DE97C), Color(0xFF0AA0AF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1DE97C).withValues(alpha: 0.35),
            blurRadius: 64,
            spreadRadius: -4,
            offset: const Offset(0, 22),
          ),
        ],
      ),
      child: CustomPaint(
        painter: _LiveBarsPainter(progress: progress, waveT: waveT),
      ),
    );
  }
}

/// Bars draw upward in a staggered sweep during entrance, then keep
/// pulsing gently in time with [waveT] so the logo feels "alive".
class _LiveBarsPainter extends CustomPainter {
  final double progress;
  final double waveT;
  _LiveBarsPainter({required this.progress, required this.waveT});

  static const _baseHeights = [0.45, 0.72, 0.92, 0.55, 0.92, 0.72, 0.45];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.95);
    const margin = 22.0;
    const barCount = 7;
    final barWidth = (size.width - margin * 2) / (barCount * 2 - 1);
    final spacing = barWidth;
    final totalWidth = barCount * barWidth + (barCount - 1) * spacing;
    final startX = (size.width - totalWidth) / 2;

    // Reveal sweep occupies progress 0.10 → 0.55.
    const startT = 0.10;
    const endT = 0.55;
    const span = endT - startT;
    final stagger = span / (barCount + 2);

    for (var i = 0; i < barCount; i++) {
      final localStart = startT + stagger * i;
      final localEnd = localStart + 0.30;
      final raw = ((progress - localStart) / (localEnd - localStart)).clamp(0.0, 1.0);
      final reveal = Curves.easeOutCubic.transform(raw);

      // After reveal, gently pulse with waveT.
      final pulse = sin((waveT + i / barCount) * 2 * pi);
      final base = _baseHeights[i];
      final live = base + 0.08 * pulse * base;
      final h = live * size.height * 0.65 * reveal;
      if (h < 0.5) continue;

      final x = startX + i * (barWidth + spacing);
      final y = size.height / 2 + (size.height * 0.32) - h;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, h),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_LiveBarsPainter old) =>
      old.progress != progress || old.waveT != waveT;
}
