import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Video mode = embedded YouTube player.
///
/// Why this approach instead of `video_player`:
///   - YouTube's own embed handles every quality up to 4K; the
///     `video_player` package can only mux 360p / 480p / 720p streams.
///   - The embed exposes YouTube's native quality picker, captions,
///     and full controls.
///   - No DASH muxing, no two-player sync issues, no codec headaches.
///
/// The embed is started at the audio handler's current position so the
/// switch from audio → video feels instant. While the WebView plays,
/// the audio handler is paused. Switching back to audio mode resumes
/// from the video's current position so the playback timeline never
/// jumps backwards.
class VideoView extends ConsumerStatefulWidget {
  final String videoId;
  final Duration startAt;
  final ValueChanged<Duration>? onPositionChange;

  const VideoView({
    super.key,
    required this.videoId,
    this.startAt = Duration.zero,
    this.onPositionChange,
  });

  @override
  ConsumerState<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends ConsumerState<VideoView> {
  InAppWebViewController? _controller;
  Duration _lastPosition = Duration.zero;

  @override
  void initState() {
    super.initState();
    // Mark video mode active so the player UI reads from this state.
    Future.microtask(() {
      if (mounted) {
        ref.read(videoPlayingProvider.notifier).state = true;
      }
    });
  }

  @override
  void didUpdateWidget(covariant VideoView old) {
    super.didUpdateWidget(old);
    if (old.videoId != widget.videoId) {
      _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(_buildUrl())));
    }
  }

  String _buildUrl() {
    // Embed parameters keep the player chrome minimal and skip the
    // "watch on YouTube" splash.
    final start = widget.startAt.inSeconds;
    return 'https://www.youtube.com/embed/${widget.videoId}'
        '?autoplay=1&playsinline=1&fs=1&modestbranding=1'
        '&rel=0&iv_load_policy=3&start=$start';
  }

  @override
  void dispose() {
    // Surface the last known position so the parent can sync the audio
    // handler to wherever the video was when the user left video mode.
    widget.onPositionChange?.call(_lastPosition);
    final notifier = ref.read(videoPlayingProvider.notifier);
    notifier.state = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(_buildUrl())),
          initialSettings: InAppWebViewSettings(
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            iframeAllowFullscreen: true,
            transparentBackground: true,
            useShouldOverrideUrlLoading: true,
          ),
          onWebViewCreated: (controller) {
            _controller = controller;
            controller.addJavaScriptHandler(
              handlerName: 'onTime',
              callback: (args) {
                if (args.isNotEmpty && args.first is num) {
                  _lastPosition = Duration(milliseconds: ((args.first as num) * 1000).round());
                }
                return null;
              },
            );
          },
          onLoadStop: (controller, _) async {
            // Inject a tiny script that polls the YouTube iframe API
            // and pings Dart with the current playback time. We use
            // this to sync audio-mode handoff and the scrubber UI.
            await controller.evaluateJavascript(source: '''
              (function() {
                if (window.__mewsifyTimer) return;
                window.__mewsifyTimer = setInterval(function() {
                  var v = document.querySelector('video');
                  if (v) {
                    window.flutter_inappwebview.callHandler('onTime', v.currentTime || 0);
                  }
                }, 500);
              })();
            ''');
          },
        ),
      ),
    );
  }
}
