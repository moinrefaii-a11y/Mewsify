import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/providers.dart';
import '../../services/audio_handler.dart';

/// Native, ad-free video mode — the Demus / YMusic approach.
///
/// We resolve YouTube's **video-only** adaptive stream (no ads baked
/// into the media itself) and play it muted in a `video_player`
/// widget. The audio keeps coming from just_audio, which stays the
/// source of truth for position, pause/play, and track transitions.
/// A ~250 ms correction loop pulls the video back into lockstep
/// whenever it drifts.
///
/// Adds:
///   • A fullscreen button that opens the video in landscape
///     (immersive, system UI hidden).
///   • Buffering state handling so the sync loop stops fighting the
///     player while it's fetching more of the stream.
class VideoView extends ConsumerStatefulWidget {
  final String videoId;

  /// Kept for API compatibility with the caller in player_screen; we
  /// ignore it now because the audio is the position source of truth.
  final Duration startAt;
  final ValueChanged<Duration>? onPositionChange;

  const VideoView({
    super.key,
    required this.videoId,
    this.startAt = Duration.zero,
    this.onPositionChange,
  });

  /// Kept for API compatibility with the toggle handler. Audio is
  /// the master timeline now, so there's no separate video position
  /// to capture — return null.
  static Future<Duration?> captureCurrentPosition() async => null;

  @override
  ConsumerState<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends ConsumerState<VideoView> {
  VideoPlayerController? _controller;
  bool _initializing = true;
  String? _error;

  Timer? _syncTimer;
  StreamSubscription<ProgressData>? _progressSub;

  @override
  void initState() {
    super.initState();
    _load();
    Future.microtask(() {
      if (mounted) ref.read(videoPlayingProvider.notifier).state = true;
    });
  }

  @override
  void didUpdateWidget(covariant VideoView old) {
    super.didUpdateWidget(old);
    if (old.videoId != widget.videoId) {
      _teardown();
      setState(() {
        _initializing = true;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final source = ref.read(youtubeSourceProvider);
      final url = await source.resolveVideoOnlyUrl(widget.videoId);
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        },
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await controller.initialize();
      await controller.setVolume(0.0);
      if (!mounted) {
        controller.dispose();
        return;
      }
      _controller = controller;
      final handler = ref.read(audioHandlerProvider);
      final audioPos = handler.rawPlayer.position;
      if (audioPos > Duration.zero) {
        await controller.seekTo(audioPos);
      }
      if (handler.rawPlayer.playing) {
        await controller.play();
      }
      setState(() => _initializing = false);
      _startSyncLoop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Runs while the widget is alive. Every 250 ms:
  ///   * mirrors audio play/pause on the video
  ///   * corrects video position when it's drifted > 300 ms, unless the
  ///     video is currently buffering (in which case we let it catch up)
  void _startSyncLoop() {
    _syncTimer?.cancel();
    final handler = ref.read(audioHandlerProvider);
    _progressSub = handler.progressStream.listen((_) {});
    _syncTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return;
      // Buffering means the video's already trying to catch up — leave
      // it alone or we'll queue up seek calls faster than the network
      // can service them.
      if (controller.value.isBuffering) return;
      final audio = handler.rawPlayer;
      if (audio.playing && !controller.value.isPlaying) {
        try {
          await controller.play();
        } catch (_) {}
      } else if (!audio.playing && controller.value.isPlaying) {
        try {
          await controller.pause();
        } catch (_) {}
      }
      final videoMs = controller.value.position.inMilliseconds;
      final audioMs = audio.position.inMilliseconds;
      final drift = (videoMs - audioMs).abs();
      if (drift > 300) {
        try {
          await controller.seekTo(audio.position);
        } catch (_) {}
        if (kDebugMode) debugPrint('[VideoSync] corrected drift ${drift}ms');
      }
    });
  }

  void _teardown() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _progressSub?.cancel();
    _progressSub = null;
    _controller?.dispose();
    _controller = null;
  }

  @override
  void dispose() {
    _teardown();
    widget.onPositionChange?.call(Duration.zero);
    final container = ProviderScope.containerOf(context, listen: false);
    container.read(videoPlayingProvider.notifier).state = false;
    super.dispose();
  }

  void _openFullscreen() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => _FullscreenVideo(
          controller: controller,
          audioHandler: ref.read(audioHandlerProvider),
        ),
        opaque: true,
        transitionDuration: const Duration(milliseconds: 220),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _content(),
              // Fullscreen button (top-right)
              Positioned(
                top: 6,
                right: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: IconButton(
                    tooltip: 'Fullscreen',
                    iconSize: 20,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.fullscreen, color: Colors.white),
                    onPressed: _openFullscreen,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Video unavailable\n$_error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      );
    }
    if (_initializing ||
        _controller == null ||
        !_controller!.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
    }
    final controller = _controller!;
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }
}

/// Immersive, landscape-locked fullscreen view for the currently
/// loaded video. Reuses the same `VideoPlayerController` so we don't
/// re-download the stream. Tapping anywhere shows / hides controls.
class _FullscreenVideo extends StatefulWidget {
  final VideoPlayerController controller;
  final MelodyAudioHandler audioHandler;

  const _FullscreenVideo({
    required this.controller,
    required this.audioHandler,
  });

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _resetHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _resetHideTimer();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: widget.controller.value.aspectRatio,
                child: VideoPlayer(widget.controller),
              ),
            ),
            if (_showControls)
              _FullscreenControls(
                audioHandler: widget.audioHandler,
                onClose: () => Navigator.of(context).pop(),
              ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenControls extends StatelessWidget {
  final MelodyAudioHandler audioHandler;
  final VoidCallback onClose;

  const _FullscreenControls({
    required this.audioHandler,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.6),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: 0.7),
          ],
          stops: const [0.0, 0.2, 0.7, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: onClose,
                ),
              ],
            ),
            const Spacer(),
            _FullscreenTransport(handler: audioHandler),
            const SizedBox(height: 12),
            _FullscreenScrubber(handler: audioHandler),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _FullscreenTransport extends StatelessWidget {
  final MelodyAudioHandler handler;
  const _FullscreenTransport({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: handler.playingStream,
      initialData: handler.rawPlayer.playing,
      builder: (context, snap) {
        final playing = snap.data ?? false;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: 42,
              icon: const Icon(Icons.skip_previous, color: Colors.white),
              onPressed: handler.skipToPrevious,
            ),
            const SizedBox(width: 24),
            Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                iconSize: 48,
                color: Colors.black,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                onPressed: () =>
                    playing ? handler.pause() : handler.play(),
              ),
            ),
            const SizedBox(width: 24),
            IconButton(
              iconSize: 42,
              icon: const Icon(Icons.skip_next, color: Colors.white),
              onPressed: handler.skipToNext,
            ),
          ],
        );
      },
    );
  }
}

class _FullscreenScrubber extends StatefulWidget {
  final MelodyAudioHandler handler;
  const _FullscreenScrubber({required this.handler});

  @override
  State<_FullscreenScrubber> createState() => _FullscreenScrubberState();
}

class _FullscreenScrubberState extends State<_FullscreenScrubber> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ProgressData>(
      stream: widget.handler.progressStream,
      builder: (context, snap) {
        final p = snap.data;
        final pos = p?.position ?? Duration.zero;
        final dur = p?.duration ?? Duration.zero;
        final actual = dur.inMilliseconds == 0
            ? 0.0
            : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
        final value = _dragValue ?? actual;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Text(_fmt(pos),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: value,
                    onChanged: (v) => setState(() => _dragValue = v),
                    onChangeEnd: (v) {
                      widget.handler.seek(Duration(
                        milliseconds: (v * dur.inMilliseconds).round(),
                      ));
                      Future.delayed(const Duration(milliseconds: 250), () {
                        if (mounted) setState(() => _dragValue = null);
                      });
                    },
                  ),
                ),
              ),
              Text(_fmt(dur),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12)),
            ],
          ),
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
