import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

/// Pushes the underlying VideoPlayerController into a landscape,
/// chrome-hidden full-screen scaffold. Same controller is reused so
/// playback isn't restarted — the user just sees a wider canvas.
class FullscreenVideo extends StatefulWidget {
  final VideoPlayerController controller;
  const FullscreenVideo({super.key, required this.controller});

  @override
  State<FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<FullscreenVideo> {
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            ),
            if (_showControls)
              Positioned(
                top: 16,
                left: 16,
                child: SafeArea(
                  child: IconButton(
                    icon: const Icon(Icons.fullscreen_exit, color: Colors.white, size: 28),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
            if (_showControls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  top: false,
                  child: _BottomControls(controller: c),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BottomControls extends StatefulWidget {
  final VideoPlayerController controller;
  const _BottomControls({required this.controller});

  @override
  State<_BottomControls> createState() => _BottomControlsState();
}

class _BottomControlsState extends State<_BottomControls> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_tick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_tick);
    super.dispose();
  }

  void _tick() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final v = widget.controller.value;
    final pos = v.position;
    final dur = v.duration;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(_fmt(pos), style: const TextStyle(color: Colors.white, fontSize: 12)),
              Expanded(
                child: Slider(
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  value: dur.inMilliseconds == 0
                      ? 0
                      : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0),
                  onChanged: (v) => widget.controller
                      .seekTo(Duration(milliseconds: (v * dur.inMilliseconds).round())),
                ),
              ),
              Text(_fmt(dur), style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
          IconButton(
            iconSize: 56,
            icon: Icon(
              v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
              color: Colors.white,
            ),
            onPressed: () =>
                v.isPlaying ? widget.controller.pause() : widget.controller.play(),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
