import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Embedded m.youtube.com browser — full YouTube inside the app.
///
/// Design goals:
///   - Behave like the real mobile YouTube website.
///   - Videos play in place (no unwanted jump to the native player).
///   - Ads are auto-skipped: the skip button is clicked the instant it
///     appears; unskippable ads are muted and fast-forwarded at 4×.
///   - A "Play in MewSify" FAB lets the user hoist whatever video is
///     currently on screen into the app's native audio queue.
class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  InAppWebViewController? _controller;
  static final _initialUrl = WebUri('https://m.youtube.com');

  bool _canGoBack = false;
  bool _loading = true;
  WebUri? _currentUri;

  String? _extractVideoId(Uri uri) {
    if (uri.host.contains('youtube.com')) {
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
      final segs = uri.pathSegments;
      final shortsIdx = segs.indexOf('shorts');
      if (shortsIdx != -1 && shortsIdx + 1 < segs.length) return segs[shortsIdx + 1];
    } else if (uri.host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.first;
    }
    return null;
  }

  Future<void> _playCurrentInApp() async {
    final uri = _currentUri;
    if (uri == null) return;
    final id = _extractVideoId(uri);
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Open a video first, then tap here')),
      );
      return;
    }
    try {
      final yt = ref.read(youtubeSourceProvider);
      final track = await yt.getTrack(id);
      await ref.read(audioHandlerProvider).playWithAutoplay(track);
      await ref.read(libraryProvider).recordPlay(track);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playing "${track.title}" in MewSify')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not play: $e')),
        );
      }
    }
  }

  Future<void> _applyAdSkipAndCleanup(InAppWebViewController c) async {
    // Small CSS: hide the "install the YouTube app" banners.
    await c.injectCSSCode(source: r'''
      ytm-mealbar-promo-renderer, ytm-consent-bump-v2-lightbox,
      ytm-privacy-tos-footer-renderer { display: none !important; }
    ''');
    // JS: auto-skip ads + mute/fast-forward unskippable ones.
    await c.evaluateJavascript(source: r'''
      (function() {
        if (window.__mewsifyBrowseTimer) return;
        window.__mewsifyBrowseTimer = setInterval(function() {
          try {
            var skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
            if (skip) skip.click();
            var v = document.querySelector('video');
            if (!v) return;
            var adOverlay = document.querySelector('.ytp-ad-player-overlay, .ytp-ad-player-overlay-instream-info, .ad-showing');
            if (adOverlay || document.querySelector('.ad-container-single-media-element')) {
              v.muted = true;
              try { v.playbackRate = 4; } catch(e) {}
            } else if (v.playbackRate !== 1) {
              v.muted = false;
              try { v.playbackRate = 1; } catch(e) {}
            }
          } catch(e) {}
        }, 200);
      })();
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _canGoBack ? () => _controller?.goBack() : null,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _controller?.reload(),
                ),
                const Spacer(),
                const Text('Browse YouTube', style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  tooltip: 'Play current video in MewSify',
                  icon: const Icon(Icons.library_music_outlined),
                  onPressed: _playCurrentInApp,
                ),
                IconButton(
                  icon: const Icon(Icons.home),
                  onPressed: () => _controller?.loadUrl(urlRequest: URLRequest(url: _initialUrl)),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: _initialUrl),
              initialSettings: InAppWebViewSettings(
                userAgent:
                    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
                javaScriptEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                useShouldOverrideUrlLoading: false,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStart: (_, uri) {
                _currentUri = uri;
                if (mounted) setState(() => _loading = true);
              },
              onLoadStop: (controller, uri) async {
                _currentUri = uri;
                _canGoBack = await controller.canGoBack();
                await _applyAdSkipAndCleanup(controller);
                if (mounted) setState(() => _loading = false);
              },
              onUpdateVisitedHistory: (_, uri, __) {
                _currentUri = uri;
              },
            ),
          ),
        ],
      ),
    );
  }
}
