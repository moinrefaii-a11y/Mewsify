import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/track.dart';
import 'piped_source.dart';

/// Wraps youtube_explode_dart, which is a Dart port of youtube-dl's
/// InnerTube client. This is the same approach NewPipe and ViMusic use.
///
/// As of late 2025 YouTube increasingly requires a PO token that the
/// "default" web client can't always generate. Different InnerTube
/// clients have different restrictions; the `androidVr` (Quest) client
/// is currently the most reliable for unsigned audio streams. We try
/// a list of clients in order and use the first manifest whose
/// audio-only stream actually responds with a non-error status.
class YouTubeSource {
  YouTubeSource()
      : _yt = YoutubeExplode(),
        _piped = PipedSource();

  final YoutubeExplode _yt;
  final PipedSource _piped;

  static final _clientFallbacks = <YoutubeApiClient>[
    // androidVr / tv typically bypass the PO-token gate the "web" client
    // fails on. If both fail we walk down to the mobile clients.
    YoutubeApiClient.androidVr,
    YoutubeApiClient.tv,
    YoutubeApiClient.android,
    YoutubeApiClient.ios,
    YoutubeApiClient.mediaConnect,
    YoutubeApiClient.safari,
  ];

  /// Short-lived audio URL cache keyed by videoId. YouTube signs their
  /// media URLs with an `expire=` parameter that's typically valid for
  /// ~6 hours, but the surrounding HTTP session tokens age faster than
  /// that, so we cap our cache at 5 minutes and let the resolver run
  /// again after that. Cache hits still save ~500 ms + a network call
  /// on retry loops after a mid-track error.
  final Map<String, _CachedUrl> _audioUrlCache = {};
  final Map<String, _CachedUrl> _videoUrlCache = {};
  static const _cacheTtl = Duration(minutes: 5);

  /// Search for tracks. Routes through our InnerTube client first;
  /// falls back to youtube_explode_dart only if YouTube Music returns
  /// nothing.
  Future<List<Track>> search(
    String query, {
    int limit = 30,
    SearchCategory category = SearchCategory.songs,
  }) async {
    final piped = await _piped.search(query, limit: limit, category: category);
    if (piped.isNotEmpty) return piped;

    // Local fallback (best-effort, may also fail for the same reasons).
    try {
      final results = await _yt.search.searchContent(query);
      final tracks = <Track>[];
      for (final item in results) {
        if (item is SearchVideo) {
          tracks.add(_searchVideoToTrack(item));
          if (tracks.length >= limit) return tracks;
        }
      }
      if (tracks.isNotEmpty) return tracks;
    } catch (e) {
      debugPrint('[YouTubeSource] searchContent fallback failed: $e');
    }

    try {
      final list = await _yt.search.search(query);
      final tracks = <Track>[];
      for (final item in list) {
        tracks.add(_videoToTrack(item));
        if (tracks.length >= limit) return tracks;
      }
      return tracks;
    } catch (e) {
      debugPrint('[YouTubeSource] search fallback failed: $e');
      return const [];
    }
  }

  Track _searchVideoToTrack(SearchVideo v) {
    return Track(
      id: 'yt:${v.id.value}',
      title: v.title,
      artist: v.author,
      thumbnailUrl: 'https://i.ytimg.com/vi/${v.id.value}/hqdefault.jpg',
      duration: _parseDuration(v.duration),
      sourceVideoId: v.id.value,
      addedAt: DateTime.now(),
    );
  }

  /// SearchVideo.duration comes back as either a Duration, an int (seconds),
  /// or a String like "3:45" / "1:02:30" depending on the response shape.
  Duration _parseDuration(Object? raw) {
    if (raw == null) return Duration.zero;
    if (raw is Duration) return raw;
    if (raw is int) return Duration(seconds: raw);
    if (raw is String) {
      final parts = raw.split(':').map(int.tryParse).whereType<int>().toList();
      if (parts.length == 2) return Duration(minutes: parts[0], seconds: parts[1]);
      if (parts.length == 3) return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
    }
    return Duration.zero;
  }

  Future<List<Track>> trending({int limit = 25}) async {
    final piped = await _piped.trending(limit: limit);
    if (piped.isNotEmpty) return piped;
    return search('top hits ${DateTime.now().year}', limit: limit);
  }

  /// Resolve a fresh audio-only URL. Tries each InnerTube client in
  /// turn until one returns a workable audio stream. Result cached for
  /// 5 minutes so retry loops after a transient failure don't spam the
  /// resolver with duplicate network calls.
  Future<String> resolveAudioUrl(String videoId) async {
    final cached = _audioUrlCache[videoId];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.url;
    }
    final result = await _resolveStreams(videoId);
    final audio = result.audioOnly.withHighestBitrate();
    final url = audio.url.toString();
    _audioUrlCache[videoId] =
        _CachedUrl(url: url, expiresAt: DateTime.now().add(_cacheTtl));
    return url;
  }

  /// Resolve a fresh **video-only** stream URL (ad-free — YouTube's
  /// ads are injected by the player, not baked into the media). Used
  /// for the Now Playing "video mode" so we can render actual HD
  /// video alongside the audio-only stream in just_audio.
  ///
  /// Prefers MP4 (H.264) over WebM (VP9) because iOS AVPlayer only
  /// handles H.264 reliably. Picks the highest-quality stream at or
  /// below [preferredHeight] px so we don't blow through mobile data.
  Future<String> resolveVideoOnlyUrl(
    String videoId, {
    int preferredHeight = 720,
  }) async {
    final cacheKey = '$videoId:$preferredHeight';
    final cached = _videoUrlCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.url;
    }
    final manifest = await _resolveStreams(videoId);
    final videoOnly = manifest.videoOnly.toList();
    if (videoOnly.isEmpty) {
      // Fall back to muxed if the client only returned muxed streams.
      final muxed = manifest.muxed
          .where((s) => s.container.name.toLowerCase() == 'mp4')
          .toList()
        ..sort((a, b) =>
            _heightForQuality(b.videoQuality) -
            _heightForQuality(a.videoQuality));
      if (muxed.isEmpty) {
        throw Exception('No video streams available for $videoId');
      }
      return muxed.first.url.toString();
    }

    // Prefer MP4 first; only fall back to non-MP4 when MP4 is missing.
    final mp4 = videoOnly
        .where((s) => s.container.name.toLowerCase() == 'mp4')
        .toList();
    final pool = mp4.isNotEmpty ? mp4 : videoOnly;

    // Sort tallest → shortest so we can walk down to the preferred height.
    pool.sort((a, b) =>
        _heightForQuality(b.videoQuality) -
        _heightForQuality(a.videoQuality));

    // Pick the tallest stream ≤ preferredHeight; if none exist, use the
    // shortest available (which will always be ≤ preferredHeight).
    final picked = pool.firstWhere(
      (s) => _heightForQuality(s.videoQuality) <= preferredHeight,
      orElse: () => pool.last,
    );
    debugPrint('[YouTubeSource] video-only ${picked.videoQuality.name} '
        '(${picked.container.name}) for $videoId');
    final url = picked.url.toString();
    _videoUrlCache[cacheKey] =
        _CachedUrl(url: url, expiresAt: DateTime.now().add(_cacheTtl));
    return url;
  }

  /// Pre-warm the audio URL cache without waiting for the caller.
  /// Used by the Browse tab: when the user opens a /watch page we
  /// kick off resolution immediately, so if they hit background /
  /// hoist a second later, the URL is already ready.
  void prewarmAudioUrl(String videoId) {
    if (_audioUrlCache[videoId] != null &&
        DateTime.now().isBefore(_audioUrlCache[videoId]!.expiresAt)) {
      return;
    }
    unawaited(resolveAudioUrl(videoId).catchError((_) => ''));
  }

  /// Read a cached audio URL without kicking off a resolution.
  /// Returns null if there is no fresh cache entry.
  String? cachedAudioUrl(String videoId) {
    final c = _audioUrlCache[videoId];
    if (c == null) return null;
    if (DateTime.now().isAfter(c.expiresAt)) return null;
    return c.url;
  }

  /// Resolve video streams for the player. Returns one or more
  /// quality options the user can switch between.
  ///
  /// `video_player` only handles "muxed" streams (audio + video in one
  /// container). For tracks that lack muxed streams (most YouTube Music
  /// catalog) we surface a single "Audio only" entry so the player
  /// still loads and the toggle doesn't dead-end.
  Future<List<VideoStreamOption>> resolveVideoStreams(String videoId) async {
    final manifest = await _resolveStreams(videoId);
    final options = manifest.muxed.map((s) {
      return VideoStreamOption(
        label: '${s.videoQuality.name} (${s.container.name})',
        url: s.url.toString(),
        height: _heightForQuality(s.videoQuality),
        bitrate: s.bitrate.bitsPerSecond,
        audioOnly: false,
      );
    }).toList()
      ..sort((a, b) => b.height.compareTo(a.height));

    if (options.isEmpty && manifest.audioOnly.isNotEmpty) {
      // Fall back to the best audio-only stream so the video toggle
      // still has something to play (will render as a black canvas).
      final audio = manifest.audioOnly.withHighestBitrate();
      options.add(VideoStreamOption(
        label: 'Audio only',
        url: audio.url.toString(),
        height: 0,
        bitrate: audio.bitrate.bitsPerSecond,
        audioOnly: true,
      ));
    }
    return options;
  }

  Future<StreamManifest> _resolveStreams(String videoId) async {
    Object? lastError;
    for (final client in _clientFallbacks) {
      try {
        final manifest = await _yt.videos.streamsClient
            .getManifest(videoId, ytClients: [client])
            .timeout(const Duration(seconds: 8));
        if (manifest.audioOnly.isEmpty && manifest.muxed.isEmpty) continue;
        debugPrint('[YouTubeSource] manifest via $client');
        return manifest;
      } catch (e) {
        debugPrint('[YouTubeSource] client $client failed: $e');
        lastError = e;
        continue;
      }
    }
    throw Exception(
      'No InnerTube client could resolve streams for $videoId. Last error: $lastError',
    );
  }

  int _heightForQuality(VideoQuality q) {
    switch (q) {
      case VideoQuality.low144:
        return 144;
      case VideoQuality.low240:
        return 240;
      case VideoQuality.medium360:
        return 360;
      case VideoQuality.medium480:
        return 480;
      case VideoQuality.high720:
        return 720;
      case VideoQuality.high1080:
        return 1080;
      case VideoQuality.high1440:
        return 1440;
      case VideoQuality.high2160:
        return 2160;
      case VideoQuality.high2880:
        return 2880;
      case VideoQuality.high3072:
        return 3072;
      case VideoQuality.high4320:
        return 4320;
      // ignore: no_default_cases
      default:
        return 0;
    }
  }

  Future<Track> getTrack(String videoId) async {
    final video = await _yt.videos.get(videoId);
    return _videoToTrack(video);
  }

  Future<List<Track>> playlistTracks(String playlistId) async {
    final videos = await _yt.playlists.getVideos(playlistId).toList();
    return videos.map(_videoToTrack).toList();
  }

  Future<List<Track>> related(String videoId, {int limit = 20}) async {
    final video = await _yt.videos.get(videoId);
    final related = await _yt.videos.getRelatedVideos(video);
    if (related == null) return [];
    return related.take(limit).map(_videoToTrack).toList();
  }

  /// Real YouTube channel uploads — matches what you see on the
  /// channel's "Videos" tab. Uses our own InnerTube browse call
  /// because youtube_explode_dart 3.1.0's channels.getUploads returns
  /// zero entries and getUploadsFromPage returns entries with empty
  /// titles (YouTube changed the response shape; the library hasn't
  /// caught up). If InnerTube also fails we fall back to a keyword
  /// search on the channel name so the page is never empty.
  Future<List<Track>> channelUploads(
    String channelId, {
    int limit = 30,
  }) async {
    final direct = await _piped.channelUploads(channelId, limit: limit);
    if (direct.isNotEmpty) return direct;
    debugPrint('[YouTubeSource] channelUploads direct empty, falling back');
    try {
      final channel = await _yt.channels.get(channelId);
      return search(channel.title, limit: limit);
    } catch (_) {
      return const [];
    }
  }

  /// Fetches the top-level channel metadata (name, subscriber count,
  /// large avatar). Null on any failure so the caller can degrade
  /// gracefully.
  Future<ChannelMeta?> channelInfo(String channelId) async {
    try {
      final c = await _yt.channels.get(channelId);
      String avatar = c.logoUrl;
      // Rewrite the "=s##..." size suffix (if present) for a big fetch.
      avatar = avatar.replaceFirstMapped(
        RegExp(r'=s\d+'),
        (_) => '=s720',
      );
      return ChannelMeta(
        id: c.id.value,
        title: c.title,
        avatarUrl: avatar,
        subscribers: c.subscribersCount ?? 0,
      );
    } catch (e) {
      debugPrint('[YouTubeSource] channelInfo failed: $e');
      return null;
    }
  }

  Track _videoToChannelTrack(Video v) {
    return Track(
      id: 'yt:${v.id.value}',
      title: v.title,
      artist: v.author,
      // Reused as a subtitle line so channel results feel like YouTube
      // (upload date + view count).
      album: _formatUploadSubtitle(v),
      thumbnailUrl: 'https://i.ytimg.com/vi/${v.id.value}/hq720.jpg',
      duration: v.duration ?? Duration.zero,
      sourceVideoId: v.id.value,
      addedAt: DateTime.now(),
    );
  }

  String _formatUploadSubtitle(Video v) {
    final parts = <String>[];
    if (v.uploadDate != null) {
      parts.add(_ago(v.uploadDate!));
    } else if (v.publishDate != null) {
      parts.add(_ago(v.publishDate!));
    }
    parts.add('${_compact(v.engagement.viewCount)} views');
    return parts.join(' · ');
  }

  /// "3 days ago", "2 months ago", "1 year ago"
  String _ago(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inDays > 365) {
      final y = diff.inDays ~/ 365;
      return '$y year${y == 1 ? '' : 's'} ago';
    }
    if (diff.inDays > 30) {
      final m = diff.inDays ~/ 30;
      return '$m month${m == 1 ? '' : 's'} ago';
    }
    if (diff.inDays > 0) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
    if (diff.inHours > 0) return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes} min ago';
    return 'just now';
  }

  /// "1.2M", "3.4K", "999"
  String _compact(int n) {
    if (n >= 1000000000) return '${(n / 1000000000).toStringAsFixed(1)}B';
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  Track _videoToTrack(Video v) {
    final thumb = v.thumbnails.highResUrl;
    return Track(
      id: 'yt:${v.id.value}',
      title: v.title,
      artist: v.author,
      thumbnailUrl: thumb,
      duration: v.duration ?? Duration.zero,
      sourceVideoId: v.id.value,
      addedAt: DateTime.now(),
    );
  }

  /// Extracts a YouTube playlist or video id from any common URL form.
  static (String, String)? parseUrl(String input) {
    Uri? uri;
    try {
      uri = Uri.parse(input.trim());
    } catch (_) {
      return null;
    }
    if (uri.host.isEmpty) return null;

    if (uri.host.contains('youtube.com') || uri.host.contains('youtu.be')) {
      final list = uri.queryParameters['list'];
      if (list != null && list.isNotEmpty) return ('playlist', list);
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return ('video', v);
      if (uri.host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
        return ('video', uri.pathSegments.first);
      }
      final shortsIdx = uri.pathSegments.indexOf('shorts');
      if (shortsIdx != -1 && shortsIdx + 1 < uri.pathSegments.length) {
        return ('video', uri.pathSegments[shortsIdx + 1]);
      }
    }
    return null;
  }

  void dispose() {
    _yt.close();
    _piped.dispose();
  }
}

/// TTL-bounded cache entry for a resolved YouTube media URL.
class _CachedUrl {
  final String url;
  final DateTime expiresAt;
  const _CachedUrl({required this.url, required this.expiresAt});
}

/// Basic channel-level metadata for the artist header on a channel page.
class ChannelMeta {
  final String id;
  final String title;
  final String avatarUrl;
  final int subscribers;
  const ChannelMeta({
    required this.id,
    required this.title,
    required this.avatarUrl,
    required this.subscribers,
  });
}

/// One playable video quality option (e.g. "720p mp4 — 1.2 Mbps").
class VideoStreamOption {
  final String label;
  final String url;
  final int height; // in px
  final int bitrate; // bits/sec
  final bool audioOnly;
  const VideoStreamOption({
    required this.label,
    required this.url,
    required this.height,
    required this.bitrate,
    this.audioOnly = false,
  });

  String get qualityLabel {
    if (audioOnly) return 'Audio';
    if (height >= 2160) return '2160p';
    if (height >= 1440) return '1440p';
    if (height >= 1080) return '1080p';
    if (height >= 720) return '720p';
    if (height >= 480) return '480p';
    if (height >= 360) return '360p';
    if (height >= 240) return '240p';
    if (height > 0) return '144p';
    return 'auto';
  }
}
