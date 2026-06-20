import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../data/sources/youtube_source.dart';
import 'audio_handler.dart';

/// Receives links sent to the app by the OS (Android intent filter for
/// youtube.com / youtu.be / mewsify://) and routes them to playback.
///
/// Handles two cases:
///   1. Cold start — app launched by tapping a link. We grab
///      `getInitialAppLink()` and play that track once the audio
///      handler is ready.
///   2. Warm — app was already running and the user tapped a link.
///      We listen on `uriLinkStream` and play immediately.
class DeepLinkService {
  DeepLinkService(this._audio, this._yt);

  final MelodyAudioHandler _audio;
  final YouTubeSource _yt;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription? _sub;

  Future<void> start() async {
    // Handle a cold-start link, then subscribe for hot-start ones.
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        await _handle(initial);
      }
    } catch (e) {
      debugPrint('[DeepLink] initial: $e');
    }

    _sub?.cancel();
    _sub = _appLinks.uriLinkStream.listen((uri) async {
      try {
        await _handle(uri);
      } catch (e) {
        debugPrint('[DeepLink] $uri: $e');
      }
    });
  }

  Future<void> _handle(Uri uri) async {
    debugPrint('[DeepLink] received $uri');
    final videoId = _extractVideoId(uri);
    if (videoId == null) return;
    final track = await _yt.getTrack(videoId);
    await _audio.playWithAutoplay(track);
  }

  /// Pulls a YouTube video id out of any of:
  ///   - youtu.be/{id}
  ///   - youtube.com/watch?v={id}
  ///   - youtube.com/shorts/{id}
  ///   - mewsify://track/{id}
  String? _extractVideoId(Uri uri) {
    if (uri.scheme == 'mewsify') {
      // mewsify://track/{id} or mewsify://video/{id}
      final segs = uri.pathSegments;
      if (segs.isNotEmpty) return segs.last;
      if (uri.host.isNotEmpty) return uri.host;
    }
    if (uri.host.contains('youtube.com')) {
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
      final shortsIdx = uri.pathSegments.indexOf('shorts');
      if (shortsIdx != -1 && shortsIdx + 1 < uri.pathSegments.length) {
        return uri.pathSegments[shortsIdx + 1];
      }
    }
    if (uri.host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.first;
    }
    return null;
  }

  void dispose() => _sub?.cancel();
}
