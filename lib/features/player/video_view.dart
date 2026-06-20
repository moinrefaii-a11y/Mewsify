import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Video mode — loads the actual YouTube mobile watch page in a WebView.
///
/// This is the same approach YMusic uses: load m.youtube.com/watch?v=ID
/// and let YouTube's own player handle quality, buffering, and controls.
/// No embed endpoint (avoids 303 redirects and consent cookie issues).
///
/// The WebView injects a small JS poller to report the current playback
/// position back to Dart so that switching back to audio mode can resume
/// at the same timestamp.
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _lastPosition = widget.startAt;
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
      _lastPosition = Duration.zero;
      setState(() => _loading = true);
      _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(_watchUrl())));
    }
  }

  String _watchUrl() {
    final start = widget.startAt.inSeconds;
    return 'https://m.youtube.com/watch?v=${widget.videoId}&t=${start}s';
  }

  /// Grab the current video position synchronously before dispose.
  Future<void> _syncPosition() async {
    if (_controller == null) return;
    try {
      final result = await _controller!.evaluateJavascript(source: '''
        (function() {
          var v = document.querySelector('video');
          return v ? v.currentTime : 0;
        })();
      ''');
      if (result != null && result is num && result > 0) {
        _lastPosition = Duration(milliseconds: (result * 1000).round());
      }
    } catch (_) {}
  }

  @override
  void dispose() {
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
        child: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_watchUrl())),
              initialSettings: InAppWebViewSettings(
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                iframeAllowFullscreen: true,
                transparentBackground: true,
                userAgent: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/120.0.0.0 Mobile Safari/537.36',
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                controller.addJavaScriptHandler(
                  handlerName: 'onTime',
                  callback: (args) {
                    if (args.isNotEmpty && args.first is num) {
                      _lastPosition = Duration(
                        milliseconds: ((args.first as num) * 1000).round(),
                      );
                    }
                    return null;
                  },
                );
              },
              onLoadStop: (controller, _) async {
                if (mounted) setState(() => _loading = false);
                await controller.evaluateJavascript(source: '''
                  (function() {
                    if (window.__mewsifyTimer) return;
                    window.__mewsifyTimer = setInterval(function() {
                      var v = document.querySelector('video');
                      if (v && v.currentTime > 0) {
                        window.flutter_inappwebview.callHandler('onTime', v.currentTime);
                      }
                    }, 500);
                  })();
                ''');
              },
            ),
            if (_loading)
              const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }
}
