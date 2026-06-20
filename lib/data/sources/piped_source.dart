import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/track.dart';

/// Direct InnerTube client for both YouTube and YouTube Music search.
///
/// Two endpoints:
///   - `www.youtube.com/youtubei/v1/search`        → all content
///     (videos, vlogs, podcasts, gaming, music, you name it)
///   - `music.youtube.com/youtubei/v1/search`      → music-only with
///     filters (songs, videos, albums, artists)
///
/// We pick endpoint per [SearchCategory]:
///   all      → www.youtube.com           (default; full breadth)
///   songs    → music.youtube.com (songs filter)
///   videos   → music.youtube.com (videos filter — music videos)
///   artists  → music.youtube.com (artists filter)
class PipedSource {
  static const _ytSearchUrl =
      'https://www.youtube.com/youtubei/v1/search?prettyPrint=false';
  static const _ytMusicSearchUrl =
      'https://music.youtube.com/youtubei/v1/search?prettyPrint=false';

  static const _ytMusicParams = {
    SearchCategory.songs: 'EgWKAQIIAWoQEAMQBBAJEAoQBRAVEBEQEA%3D%3D',
    SearchCategory.videos: 'EgWKAQIQAWoQEAMQBBAJEAoQBRAVEBEQEA%3D%3D',
    SearchCategory.artists: 'EgWKAQIgAWoQEAMQBBAJEAoQBRAVEBEQEA%3D%3D',
  };

  // YouTube Music client
  static const _ytMusicContext = {
    'client': {
      'clientName': 'WEB_REMIX',
      'clientVersion': '1.20240101.01.00',
      'hl': 'en',
      'gl': 'US',
    },
    'user': {'lockedSafetyMode': false},
  };

  // Regular YouTube client (mobile web)
  static const _ytContext = {
    'client': {
      'clientName': 'WEB',
      'clientVersion': '2.20240101.01.00',
      'hl': 'en',
      'gl': 'US',
    },
  };

  static const _ytMusicHeaders = {
    'Content-Type': 'application/json',
    'Origin': 'https://music.youtube.com',
    'Referer': 'https://music.youtube.com/',
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    'X-YouTube-Client-Name': '67',
    'X-YouTube-Client-Version': '1.20240101.01.00',
  };

  static const _ytHeaders = {
    'Content-Type': 'application/json',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    'X-YouTube-Client-Name': '1',
    'X-YouTube-Client-Version': '2.20240101.01.00',
  };

  final http.Client _http = http.Client();

  Future<List<Track>> search(
    String query, {
    int limit = 30,
    SearchCategory category = SearchCategory.all,
  }) async {
    if (category == SearchCategory.all) {
      return _searchYoutube(query, limit: limit);
    }
    return _searchYoutubeMusic(query,
        params: _ytMusicParams[category]!, limit: limit);
  }

  /// Trending feed: regular YouTube search for "music" gives us the
  /// charts vibe + popular content from across the platform.
  Future<List<Track>> trending({int limit = 25}) async {
    return _searchYoutube('top music ${DateTime.now().year}', limit: limit);
  }

  // --- regular YouTube search ------------------------------------------

  Future<List<Track>> _searchYoutube(String query, {required int limit}) async {
    debugPrint('[YT] searching "$query"');
    try {
      final body = json.encode({'context': _ytContext, 'query': query});
      final res = await _http
          .post(Uri.parse(_ytSearchUrl), headers: _ytHeaders, body: body)
          .timeout(const Duration(seconds: 12));
      debugPrint('[YT] HTTP ${res.statusCode} (${res.body.length} bytes)');
      if (res.statusCode != 200) return const [];
      final data = json.decode(res.body) as Map<String, dynamic>;
      final tracks = _parseYoutube(data, limit: limit);
      debugPrint('[YT] parsed ${tracks.length} items');
      return tracks;
    } catch (e) {
      debugPrint('[YT] error: $e');
      return const [];
    }
  }

  List<Track> _parseYoutube(Map<String, dynamic> data, {required int limit}) {
    final tracks = <Track>[];
    void recurse(Object? node) {
      if (tracks.length >= limit) return;
      if (node is Map<String, dynamic>) {
        final v = node['videoRenderer'];
        if (v is Map<String, dynamic>) {
          final track = _parseVideoRenderer(v);
          if (track != null) tracks.add(track);
        }
        for (final value in node.values) {
          recurse(value);
        }
      } else if (node is List) {
        for (final v in node) {
          recurse(v);
        }
      }
    }

    recurse(data);
    return tracks;
  }

  Track? _parseVideoRenderer(Map<String, dynamic> v) {
    try {
      final videoId = v['videoId']?.toString();
      if (videoId == null || videoId.isEmpty) return null;

      final titleRuns = (v['title']?['runs']) as List?;
      final title = titleRuns != null && titleRuns.isNotEmpty
          ? (titleRuns.first['text']?.toString() ?? '')
          : (v['title']?['simpleText']?.toString() ?? '');

      final ownerRuns = (v['ownerText']?['runs'] ??
          v['longBylineText']?['runs']) as List?;
      final artist = ownerRuns != null && ownerRuns.isNotEmpty
          ? (ownerRuns.first['text']?.toString() ?? 'Unknown')
          : 'Unknown';

      // Use hq720.jpg — server-rendered 1280x720, exists for every
      // YouTube video. The InnerTube response only includes 320x180
      // thumbnails for search results which look blurry at full width.
      final thumb = 'https://i.ytimg.com/vi/$videoId/hq720.jpg';

      // Duration: "3:45" or "1:02:30"
      final durStr = v['lengthText']?['simpleText']?.toString() ?? '';
      final duration = _parseDurationString(durStr);

      return Track(
        id: 'yt:$videoId',
        title: title,
        artist: artist,
        thumbnailUrl: thumb,
        duration: duration,
        sourceVideoId: videoId,
        addedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  Duration _parseDurationString(String s) {
    if (s.isEmpty) return Duration.zero;
    final parts = s.split(':').map(int.tryParse).whereType<int>().toList();
    if (parts.length == 2) return Duration(minutes: parts[0], seconds: parts[1]);
    if (parts.length == 3) {
      return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
    }
    return Duration.zero;
  }

  // --- YouTube Music search --------------------------------------------

  Future<List<Track>> _searchYoutubeMusic(
    String query, {
    required String params,
    required int limit,
  }) async {
    debugPrint('[YT-Music] searching "$query"');
    try {
      final body = json.encode({
        'context': _ytMusicContext,
        'query': query,
        'params': params,
      });
      final res = await _http
          .post(Uri.parse(_ytMusicSearchUrl),
              headers: _ytMusicHeaders, body: body)
          .timeout(const Duration(seconds: 12));
      debugPrint('[YT-Music] HTTP ${res.statusCode}');
      if (res.statusCode != 200) return const [];
      final data = json.decode(res.body) as Map<String, dynamic>;
      return _parseYtMusic(data, limit: limit);
    } catch (e) {
      debugPrint('[YT-Music] error: $e');
      return const [];
    }
  }

  List<Track> _parseYtMusic(Map<String, dynamic> data, {required int limit}) {
    final tracks = <Track>[];
    void recurse(Object? node) {
      if (tracks.length >= limit) return;
      if (node is Map<String, dynamic>) {
        final item = node['musicResponsiveListItemRenderer'];
        if (item is Map<String, dynamic>) {
          final track = _parseMusicListItem(item);
          if (track != null) tracks.add(track);
        }
        for (final v in node.values) {
          recurse(v);
        }
      } else if (node is List) {
        for (final v in node) {
          recurse(v);
        }
      }
    }

    recurse(data);
    return tracks;
  }

  Track? _parseMusicListItem(Map<String, dynamic> item) {
    try {
      final flexColumns = item['flexColumns'] as List?;
      if (flexColumns == null || flexColumns.isEmpty) return null;

      final firstCol = flexColumns.first as Map<String, dynamic>;
      final firstText = firstCol['musicResponsiveListItemFlexColumnRenderer']
          ?['text'] as Map<String, dynamic>?;
      final firstRuns = firstText?['runs'] as List?;
      if (firstRuns == null || firstRuns.isEmpty) return null;

      final titleRun = firstRuns.first as Map<String, dynamic>;
      final title = titleRun['text']?.toString() ?? '';
      final videoId = ((((titleRun['navigationEndpoint']
                  as Map?)?['watchEndpoint']) as Map?)?['videoId']) as String?;
      if (videoId == null || videoId.isEmpty) return null;

      String artist = 'Unknown';
      if (flexColumns.length > 1) {
        final secondText = (flexColumns[1] as Map<String, dynamic>)
                ['musicResponsiveListItemFlexColumnRenderer']
            ?['text'] as Map<String, dynamic>?;
        final secondRuns = secondText?['runs'] as List?;
        if (secondRuns != null && secondRuns.isNotEmpty) {
          final candidates = secondRuns
              .whereType<Map<String, dynamic>>()
              .map((r) => r['text']?.toString() ?? '')
              .where((t) => t.trim().isNotEmpty && t.trim() != '•')
              .toList();
          if (candidates.isNotEmpty) artist = candidates.first;
        }
      }

      String thumb = 'https://i.ytimg.com/vi/$videoId/hq720.jpg';
      final thumbnails = (((item['thumbnail'] as Map?)?['musicThumbnailRenderer']
                  as Map?)?['thumbnail'] as Map?)?['thumbnails'] as List?;
      if (thumbnails != null && thumbnails.isNotEmpty) {
        final last = thumbnails.last as Map<String, dynamic>;
        final raw = last['url']?.toString() ?? thumb;
        // YouTube Music album art comes from lh3.googleusercontent.com
        // with a size suffix like "=w120-h120-l90-rj". Rewrite to a
        // much larger size so the player artwork looks crisp.
        thumb = raw.replaceFirstMapped(
          RegExp(r'=w\d+-h\d+'),
          (_) => '=w1080-h1080',
        );
      }

      return Track(
        id: 'yt:$videoId',
        title: title,
        artist: artist,
        thumbnailUrl: thumb,
        duration: Duration.zero,
        sourceVideoId: videoId,
        addedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  void dispose() => _http.close();
}

/// YouTube search categories. `all` is regular YouTube search (videos,
/// vlogs, podcasts, music, anything) — the default. The others map to
/// specific YouTube Music tabs.
enum SearchCategory { all, songs, videos, artists }
