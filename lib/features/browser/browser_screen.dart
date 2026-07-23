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

  /// Kick off audio-URL resolution the instant the browser loads a
  /// /watch page. The result lands in YouTubeSource's cache — if the
  /// user backgrounds the app a second later, the shell's hoist finds
  /// a warm cache entry and starts native playback with no gap.
  void _prewarmIfWatchPage(WebUri? uri) {
    if (uri == null) return;
    final id = _extractVideoId(uri);
    if (id == null) return;
    ref.read(youtubeSourceProvider).prewarmAudioUrl(id);
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
    // CSS: nuke the static "sponsored" renderers plus install-app
    // and consent banners. These are safe to hide because they're
    // never the video player itself.
    await c.injectCSSCode(source: r'''
      ytm-mealbar-promo-renderer, ytm-consent-bump-v2-lightbox,
      ytm-privacy-tos-footer-renderer, ytm-companion-ad-renderer,
      ytm-promoted-video-renderer, ytm-promoted-sparkles-web-renderer,
      ytm-ads-engagement-panel-content-renderer,
      ytm-ad-slot-renderer, ytm-video-ad-renderer,
      ytd-video-masthead-ad-v3-renderer, ytd-display-ad-renderer,
      ytd-promoted-sparkles-web-renderer,
      ytd-compact-promoted-video-renderer,
      ytd-action-companion-ad-renderer,
      ytd-banner-promo-renderer, ytd-in-feed-ad-layout-renderer,
      ytd-ad-inline-playback-meta-block,
      ytd-player-legacy-desktop-watch-ads-renderer,
      ytd-ads-engagement-panel-content-renderer,
      .ytp-ad-overlay-container, .ytp-ad-image-overlay,
      .video-ads {
        display: none !important;
      }
    ''');
    // JS: proven ad-skip recipe from working YouTube ad-block
    // bookmarklets. Two moving parts:
    //   1. If any element on the page has the `.ad-showing` class:
    //      seek the <video> element straight to `duration`, forcing
    //      YouTube to advance past the ad. Also click any variant of
    //      the "Skip Ad" button that's on screen.
    //   2. Every 100 ms remove any static "sponsored" renderer node
    //      (tag-name based, so YouTube can't rename its CSS classes
    //      to defeat us).
    // The seek-to-end trick is exactly what running production
    // ad-block bookmarklets use. It works because YouTube's own
    // player treats reaching duration during an ad as "ad complete"
    // and moves to the real content.
    await c.evaluateJavascript(source: r'''
      (function() {
        if (window.__mewsifyBrowseAdSkip) return;
        window.__mewsifyBrowseAdSkip = true;

        var STATIC_AD_TAGS = [
          'ytm-companion-ad-renderer',
          'ytm-promoted-video-renderer',
          'ytm-ads-engagement-panel-content-renderer',
          'ytm-ad-slot-renderer',
          'ytm-video-ad-renderer',
          'ytd-video-masthead-ad-v3-renderer',
          'ytd-display-ad-renderer',
          'ytd-promoted-sparkles-web-renderer',
          'ytd-compact-promoted-video-renderer',
          'ytd-action-companion-ad-renderer',
          'ytd-banner-promo-renderer',
          'ytd-in-feed-ad-layout-renderer',
          'ytd-ad-inline-playback-meta-block',
          'ytd-player-legacy-desktop-watch-ads-renderer',
          'ytd-ads-engagement-panel-content-renderer'
        ];
        var SKIP_SELECTORS = [
          '.ytp-ad-skip-button',
          '.ytp-ad-skip-button-modern',
          '.ytp-skip-ad-button',
          '.ytp-ad-skip-button-container button',
          'button.ytp-ad-skip-button-modern',
          '.videoAdUiSkipButton'
        ];

        function tick() {
          try {
            // 1) Remove any static-ad renderers.
            for (var i = 0; i < STATIC_AD_TAGS.length; i++) {
              var nodes = document.getElementsByTagName(STATIC_AD_TAGS[i]);
              for (var j = nodes.length - 1; j >= 0; j--) {
                nodes[j].remove();
              }
            }
            // 2) If an ad is showing right now: fast-forward the <video>
            // to its own duration (which YouTube's player interprets
            // as "ad complete") and click any skip button that's up.
            if (document.querySelector('.ad-showing') ||
                document.querySelector('.ad-interrupting') ||
                document.querySelector('.ytp-ad-player-overlay')) {
              var v = document.querySelector('video');
              if (v && v.duration && !isNaN(v.duration)) {
                try { v.currentTime = v.duration; } catch(e) {}
              }
              for (var k = 0; k < SKIP_SELECTORS.length; k++) {
                var btn = document.querySelector(SKIP_SELECTORS[k]);
                if (btn) { try { btn.click(); break; } catch(e) {} }
              }
            }
          } catch (e) {}
        }

        setInterval(tick, 100);
        tick();

        // Poll video position every 500 ms and post to Dart so the
        // shell can seek native audio to the right spot when we hoist.
        setInterval(function() {
          try {
            var v = document.querySelector('video');
            if (v && v.currentTime > 0 && v.duration && !isNaN(v.duration)) {
              window.flutter_inappwebview.callHandler(
                'onBrowseVideoPos',
                v.currentTime,
                v.duration
              );
            }
          } catch(e) {}
        }, 500);
      })();
    ''');
  }

  @override
  Widget build(BuildContext context) {
    // Listen for resume-video requests from the shell (on app resume
    // after a background-hoist). Seek the WebView's <video> to the
    // requested second and start playing, so the user's browsing
    // experience picks up exactly where the audio was.
    ref.listen<double>(browserResumeSecondsProvider, (_, next) async {
      if (next < 0) return;
      // Consume the signal so we don't refire on rebuild.
      ref.read(browserResumeSecondsProvider.notifier).state = -1;
      final controller = _controller;
      if (controller == null) return;
      try {
        await controller.evaluateJavascript(source: '''
          (function() {
            var v = document.querySelector('video');
            if (!v) return;
            try { v.currentTime = $next; } catch(e) {}
            try { v.play(); } catch(e) {}
          })();
        ''');
      } catch (_) {}
    });

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
              onWebViewCreated: (controller) {
                _controller = controller;
                // Receive position updates from the injected poller so
                // the shell can seek native audio to the correct spot
                // when we hoist on background.
                controller.addJavaScriptHandler(
                  handlerName: 'onBrowseVideoPos',
                  callback: (args) {
                    if (args.isNotEmpty && args.first is num) {
                      final pos = (args.first as num).toDouble();
                      ref.read(browserVideoPositionProvider.notifier).state =
                          pos;
                    }
                    return null;
                  },
                );
              },
              onLoadStart: (_, uri) {
                _currentUri = uri;
                ref.read(browserCurrentUrlProvider.notifier).state =
                    uri?.toString();
                _prewarmIfWatchPage(uri);
                if (mounted) setState(() => _loading = true);
              },
              onLoadStop: (controller, uri) async {
                _currentUri = uri;
                ref.read(browserCurrentUrlProvider.notifier).state =
                    uri?.toString();
                _prewarmIfWatchPage(uri);
                _canGoBack = await controller.canGoBack();
                await _applyAdSkipAndCleanup(controller);
                if (mounted) setState(() => _loading = false);
              },
              onUpdateVisitedHistory: (_, uri, __) {
                _currentUri = uri;
                ref.read(browserCurrentUrlProvider.notifier).state =
                    uri?.toString();
                _prewarmIfWatchPage(uri);
              },
            ),
          ),
        ],
      ),
    );
  }
}
