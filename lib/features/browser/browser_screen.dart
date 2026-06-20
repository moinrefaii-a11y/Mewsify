import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Embedded m.youtube.com browser, the same approach Demus and Video Lite
/// use on iOS. The user browses YouTube as if in a normal mobile browser;
/// when they tap a video URL, we intercept the navigation, extract the
/// video id, and queue it up in the native audio player.
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

  Future<bool> _maybeIntercept(WebUri uri) async {
    final videoId = _extractVideoId(uri);
    if (videoId == null) return false;
    final yt = ref.read(youtubeSourceProvider);
    final track = await yt.getTrack(videoId);
    await ref.read(audioHandlerProvider).setQueue([track], startIndex: 0);
    await ref.read(libraryProvider).recordPlay(track);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Playing: ${track.title}')),
      );
    }
    return true;
  }

  String? _extractVideoId(Uri uri) {
    if (uri.host.contains('youtube.com')) {
      // /watch?v=ID
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
      // /shorts/ID
      final segs = uri.pathSegments;
      final shortsIdx = segs.indexOf('shorts');
      if (shortsIdx != -1 && shortsIdx + 1 < segs.length) return segs[shortsIdx + 1];
    } else if (uri.host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.first;
    }
    return null;
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
                useShouldOverrideUrlLoading: true,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStart: (_, __) => setState(() => _loading = true),
              onLoadStop: (_, __) async {
                _canGoBack = await _controller?.canGoBack() ?? false;
                if (mounted) setState(() => _loading = false);
              },
              shouldOverrideUrlLoading: (controller, action) async {
                final uri = action.request.url;
                if (uri == null) return NavigationActionPolicy.ALLOW;
                final intercepted = await _maybeIntercept(uri);
                return intercepted
                    ? NavigationActionPolicy.CANCEL
                    : NavigationActionPolicy.ALLOW;
              },
            ),
          ),
        ],
      ),
    );
  }
}
