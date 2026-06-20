import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/providers.dart';
import '../../data/sources/youtube_source.dart';
import 'fullscreen_video.dart';

/// Renders the video stream of the currently playing track, kept in
/// sync with the audio player so the visuals match the timeline.
///
/// Tradeoff: when video mode is active, just_audio is paused and
/// `video_player` becomes the source of truth (it has its own audio).
/// When the user turns video mode off, we resume just_audio at the
/// scrubbed position. This is a deliberate "two players, one timeline"
/// pattern — avoids muxing DASH on the device.
class VideoView extends ConsumerStatefulWidget {
  final String videoId;
  const VideoView({super.key, required this.videoId});

  @override
  ConsumerState<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends ConsumerState<VideoView> {
  VideoPlayerController? _controller;
  List<VideoStreamOption> _qualities = const [];
  VideoStreamOption? _current;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VideoView old) {
    super.didUpdateWidget(old);
    if (old.videoId != widget.videoId) {
      _disposeController();
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final yt = ref.read(youtubeSourceProvider);
      final qualities = await yt.resolveVideoStreams(widget.videoId);
      if (qualities.isEmpty) {
        throw 'No muxed video streams available for this track';
      }
      // Default to mid quality (480p-ish) for fast startup; user can
      // bump to higher quality from the picker.
      final initial = qualities.firstWhere(
        (q) => q.height >= 480 && q.height <= 720,
        orElse: () => qualities.first,
      );
      await _switchTo(initial, qualities);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _switchTo(
      VideoStreamOption option, List<VideoStreamOption> all) async {
    // Pause audio while video plays — they'd otherwise double up.
    await ref.read(audioHandlerProvider).pause();

    final old = _controller;
    final position = old?.value.position ?? Duration.zero;

    final next = VideoPlayerController.networkUrl(
      Uri.parse(option.url),
      videoPlayerOptions: VideoPlayerOptions(
        // iOS PiP: when supported, the system shows a floating
        // mini-window with the video as the user backgrounds the app.
        allowBackgroundPlayback: Platform.isIOS,
      ),
    );
    await next.initialize();
    await next.seekTo(position);
    await next.play();

    // Mirror playing state into a Riverpod provider so the player's
    // transport row reflects the video's actual state (not the
    // audio handler's, which is paused while video plays).
    next.addListener(_publishVideoPlaying);

    setState(() {
      _controller = next;
      _qualities = all;
      _current = option;
      _loading = false;
    });

    // Publish to Riverpod for the transport row to read.
    ref.read(videoControllerProvider.notifier).state = next;
    ref.read(videoPlayingProvider.notifier).state = true;

    if (old != null) {
      old.removeListener(_publishVideoPlaying);
      await old.dispose();
    }
  }

  void _publishVideoPlaying() {
    final c = _controller;
    if (c == null) return;
    ref.read(videoPlayingProvider.notifier).state = c.value.isPlaying;
  }

  void _disposeController() {
    _controller?.removeListener(_publishVideoPlaying);
    _controller?.dispose();
    _controller = null;
    // Clear the Riverpod state so the transport row stops trying to
    // drive a disposed controller.
    if (ref.read(videoControllerProvider) != null) {
      ref.read(videoControllerProvider.notifier).state = null;
      ref.read(videoPlayingProvider.notifier).state = false;
    }
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ),
        ),
      );
    }
    final c = _controller!;
    return AspectRatio(
      aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () {
              c.value.isPlaying ? c.pause() : c.play();
              setState(() {});
            },
            child: VideoPlayer(c),
          ),
          // Fullscreen button (bottom-right)
          Positioned(
            bottom: 8,
            right: 8,
            child: IconButton(
              tooltip: 'Fullscreen',
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.fullscreen, color: Colors.white, size: 18),
              ),
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => FullscreenVideo(controller: c),
                ));
              },
            ),
          ),

          // Quality picker overlay top-right
          Positioned(
            top: 8,
            right: 8,
            child: PopupMenuButton<VideoStreamOption>(
              tooltip: 'Quality',
              icon: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.high_quality_rounded, color: Colors.white, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      _current?.qualityLabel ?? 'auto',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              onSelected: (opt) => _switchTo(opt, _qualities),
              itemBuilder: (_) => _qualities
                  .map((q) => PopupMenuItem(
                        value: q,
                        child: Row(
                          children: [
                            if (_current == q)
                              const Icon(Icons.check, size: 18)
                            else
                              const SizedBox(width: 18),
                            const SizedBox(width: 8),
                            Text(q.qualityLabel),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}
