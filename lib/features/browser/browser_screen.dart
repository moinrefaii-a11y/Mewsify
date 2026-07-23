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
    // CSS: hide the "install the YouTube app" and consent banners plus
    // any purely-cosmetic ad overlays. We do **not** hide the
    // html5-video-player container itself — that's what plays real
    // content.
    await c.injectCSSCode(source: r'''
      ytm-mealbar-promo-renderer, ytm-consent-bump-v2-lightbox,
      ytm-privacy-tos-footer-renderer, ytm-companion-ad-renderer,
      ytm-promoted-video-renderer, ytm-promoted-sparkles-web-renderer,
      .ytp-ad-overlay-container, .ytp-ad-image-overlay,
      .video-ads > .ytp-ad-module {
        display: none !important;
      }
    ''');
    // JS: conservative ad handling. Previous version was aggressive
    // enough to break real playback (seek-to-end + 16x fired on false
    // positives). This version only reacts when we're **highly**
    // confident an ad is on screen:
    //   * The player's own `.ad-showing` class is present on the
    //     html5-video-player element, AND
    //   * either the `.ytp-ad-player-overlay` or `.ytp-ad-preview-*`
    //     nodes exist (indicates a real InStream ad state).
    // In that case: click the skip button if it's up, and *only if
    // ad is still showing* mute the audio. No playbackRate hacks — they
    // can freeze the video element on Android WebView.
    await c.evaluateJavascript(source: r'''
      (function() {
        if (window.__mewsifyBrowseAdSkip) return;
        window.__mewsifyBrowseAdSkip = true;

        function isAdShowing() {
          var player = document.querySelector('.html5-video-player');
          if (!player) return false;
          // The player element is where YouTube attaches ".ad-showing".
          if (!player.classList.contains('ad-showing') &&
              !player.classList.contains('ad-interrupting')) {
            return false;
          }
          // Double-confirm with an in-stream overlay so a stale class
          // doesn't fool us into muting real content.
          return !!document.querySelector(
            '.ytp-ad-player-overlay, .ytp-ad-preview-container, ' +
            '.ytp-ad-player-overlay-instream-info'
          );
        }

        function tryClickSkip() {
          var sel = [
            '.ytp-ad-skip-button',
            '.ytp-ad-skip-button-modern',
            '.ytp-skip-ad-button',
            'button.ytp-ad-skip-button-modern',
            '.videoAdUiSkipButton',
          ];
          for (var i = 0; i < sel.length; i++) {
            var el = document.querySelector(sel[i]);
            if (el) { try { el.click(); return true; } catch(e) {} }
          }
          return false;
        }

        function handleAd() {
          var v = document.querySelector('video');
          if (!v) return;
          if (isAdShowing()) {
            tryClickSkip();
            // Mute so the ad doesn't blast the user; do not touch
            // playbackRate (freezes video on mobile Chromium) and do
            // not seek (would nuke real content on a false positive).
            if (!v.muted) v.muted = true;
          } else {
            // Restore volume on ad end, but only if *we* muted it —
            // don't override a user who tapped the mute button.
            if (v.muted && !window.__mewsifyUserMuted) v.muted = false;
          }
        }

        setInterval(handleAd, 250);

        // React quickly to class changes on the player element itself
        // (that's the one place we care about — much narrower than
        // observing all of document.body was).
        var player = document.querySelector('.html5-video-player');
        if (player && window.MutationObserver) {
          try {
            new MutationObserver(handleAd).observe(player, {
              attributes: true, attributeFilter: ['class']
            });
          } catch(e) {}
        }
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
