import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/providers.dart';
import '../../services/audio_handler.dart';

/// Native, ad-free video mode — the Demus / YMusic approach.
///
/// We resolve YouTube's **video-only** adaptive stream (no ads are
/// baked into the media itself — ads are injected by YouTube's player,
/// not the stream) and play it muted in a `video_player` widget.
/// The audio keeps coming from just_audio via [MelodyAudioHandler],
/// which stays the source of truth for position, pause / play, and
/// track transitions. A small ~250 ms correction loop pulls the video
/// back into lockstep whenever it drifts.
///
/// This gives us:
///   * True HD (up to 1080p) instead of the muxed-360p cap.
///   * Zero YouTube ads — the video stream itself has none.
///   * Perfect audio↔video sync, since audio is the master timeline.
///   * Instant "video off" — just drop the widget, audio never
///     even flinched.
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

  /// Kept for API compatibility with the toggle handler. Now that the
  /// audio player is the master timeline there's no separate video
  /// position to capture — return null and let the caller keep the
  /// audio's live position.
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
      // Pass a normal User-Agent so googlevideo CDN doesn't reject us.
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
      await controller.setVolume(0.0); // audio comes from just_audio
      if (!mounted) {
        controller.dispose();
        return;
      }
      _controller = controller;
      // Kick video off from the audio's current position, then start it.
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

  /// Runs in the background while the widget is alive. Every 250 ms:
  ///   * mirrors the audio's playing/paused state onto the video
  ///   * corrects video position if it's drifted more than 250 ms
  ///     from the audio's current position
  void _startSyncLoop() {
    _syncTimer?.cancel();
    final handler = ref.read(audioHandlerProvider);
    _progressSub = handler.progressStream.listen((_) {});
    _syncTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return;
      final audio = handler.rawPlayer;
      // Mirror play/pause.
      if (audio.playing && !controller.value.isPlaying) {
        try {
          await controller.play();
        } catch (_) {}
      } else if (!audio.playing && controller.value.isPlaying) {
        try {
          await controller.pause();
        } catch (_) {}
      }
      // Drift correction: video position vs. audio position.
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
    widget.onPositionChange?.call(Duration.zero); // no-op for API compat
    final container = ProviderScope.containerOf(context, listen: false);
    container.read(videoPlayingProvider.notifier).state = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          color: Colors.black,
          child: _content(),
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
    if (_initializing || _controller == null || !_controller!.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
    }
    final controller = _controller!;
    // Use the real video aspect ratio inside the 16:9 container so
    // shorts / portrait videos letterbox instead of getting stretched.
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }
}
