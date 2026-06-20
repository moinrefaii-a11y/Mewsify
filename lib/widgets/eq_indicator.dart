import 'dart:math';

import 'package:flutter/material.dart';

/// Animated 3-bar "now playing" indicator. Each bar oscillates with a
/// slightly different phase so the row feels like a real audio meter
/// rather than three synced bars going up and down together.
///
/// Drop-in replacement for the previous `Icon(Icons.equalizer)`
/// that we used as the "currently playing" marker on tiles, carousels,
/// and queue rows.
class EqIndicator extends StatefulWidget {
  final double size;
  final Color color;
  final bool playing;

  const EqIndicator({
    super.key,
    this.size = 24,
    required this.color,
    this.playing = true,
  });

  @override
  State<EqIndicator> createState() => _EqIndicatorState();
}

class _EqIndicatorState extends State<EqIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant EqIndicator old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.playing && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => CustomPaint(
            painter: _BarsPainter(
              progress: widget.playing ? _ctrl.value : 0.4,
              color: widget.color,
            ),
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final double progress;
  final Color color;

  _BarsPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const barCount = 3;
    final barWidth = size.width / (barCount * 2 - 1);
    final spacing = barWidth;
    final phases = [0.0, 0.33, 0.66];

    for (var i = 0; i < barCount; i++) {
      final t = (progress + phases[i]) % 1.0;
      // Triangle wave: 0..0.5 goes up, 0.5..1 goes down.
      final h = 0.25 + 0.65 * (t < 0.5 ? t * 2 : (1 - t) * 2);
      // Add a subtle sin wobble so it never fully stops at the edges.
      final wobble = (sin(t * pi * 2) * 0.08).abs();
      final actualH = (h + wobble).clamp(0.18, 1.0) * size.height;
      final left = i * (barWidth + spacing);
      final top = size.height - actualH;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, actualH),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.progress != progress || old.color != color;
}
