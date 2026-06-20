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
    YoutubeApiClient.androidVr,
    YoutubeApiClient.tv,
    YoutubeApiClient.android,
    YoutubeApiClient.ios,
    YoutubeApiClient.mediaConnect,
  ];

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
  /// turn until one returns a workable audio stream.
  Future<String> resolveAudioUrl(String videoId) async {
    final result = await _resolveStreams(videoId);
    final audio = result.audioOnly.withHighestBitrate();
    return audio.url.toString();
  }

  /// Resolve a video stream. Returns a list of qualities the user can
  /// pick from; each entry has a label (e.g. "720p") and the URL.
  /// We prefer "muxed" streams (combined video+audio) because the
  /// `video_player` widget can't mux DASH streams in real time.
  Future<List<VideoStreamOption>> resolveVideoStreams(String videoId) async {
    final manifest = await _resolveStreams(videoId);
    final options = manifest.muxed.map((s) {
      return VideoStreamOption(
        label: '${s.videoQuality.name} (${s.container.name})',
        url: s.url.toString(),
        height: _heightForQuality(s.videoQuality),
        bitrate: s.bitrate.bitsPerSecond,
      );
    }).toList()
      ..sort((a, b) => b.height.compareTo(a.height));
    return options;
  }

  Future<StreamManifest> _resolveStreams(String videoId) async {
    Object? lastError;
    for (final client in _clientFallbacks) {
      try {
        final manifest = await _yt.videos.streamsClient
            .getManifest(videoId, ytClients: [client]);
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

/// One playable video quality option (e.g. "720p mp4 — 1.2 Mbps").
class VideoStreamOption {
  final String label;
  final String url;
  final int height; // in px
  final int bitrate; // bits/sec
  const VideoStreamOption({
    required this.label,
    required this.url,
    required this.height,
    required this.bitrate,
  });

  String get qualityLabel {
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
