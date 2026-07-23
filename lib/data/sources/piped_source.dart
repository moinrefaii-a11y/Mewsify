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

  /// Channel uploads via InnerTube `browse` endpoint with the "Videos"
  /// tab param. Bypasses youtube_explode_dart's channels.getUploads /
  /// getUploadsFromPage — the former returns zero entries, the latter
  /// returns entries with empty titles (YouTube changed the response
  /// shape and the library didn't catch up). Hitting InnerTube
  /// ourselves and parsing `videoRenderer` items via the same recipe
  /// as regular search gives us fully-populated tracks in one call.
  Future<List<Track>> channelUploads(
    String channelId, {
    int limit = 30,
  }) async {
    debugPrint('[YT] channelUploads($channelId)');
    try {
      // "EgZ2aWRlb3PyBgQKAjoA" is the base64-encoded param that selects
      // the "Videos" tab of a channel's browse response.
      final body = json.encode({
        'context': _ytContext,
        'browseId': channelId,
        'params': 'EgZ2aWRlb3PyBgQKAjoA',
      });
      final res = await _http
          .post(
            Uri.parse(
                'https://www.youtube.com/youtubei/v1/browse?prettyPrint=false'),
            headers: _ytHeaders,
            body: body,
          )
          .timeout(const Duration(seconds: 12));
      debugPrint('[YT] channelUploads HTTP ${res.statusCode}');
      if (res.statusCode != 200) return const [];
      final data = json.decode(res.body) as Map<String, dynamic>;
      final channelTitle = _extractChannelTitle(data) ?? '';
      var tracks = _parseYoutube(data, limit: limit);
      // Backfill artist from the channelMetadataRenderer title.
      if (channelTitle.isNotEmpty) {
        tracks = tracks
            .map((t) => t.artist.isEmpty
                ? Track(
                    id: t.id,
                    title: t.title,
                    artist: channelTitle,
                    album: t.album,
                    thumbnailUrl: t.thumbnailUrl,
                    duration: t.duration,
                    sourceVideoId: t.sourceVideoId,
                    addedAt: t.addedAt,
                  )
                : t)
            .toList();
      }
      debugPrint('[YT] channelUploads parsed ${tracks.length} videos');
      return tracks;
    } catch (e) {
      debugPrint('[YT] channelUploads error: $e');
      return const [];
    }
  }

  String? _extractChannelTitle(Map<String, dynamic> data) {
    String? found;
    void walk(Object? node) {
      if (found != null) return;
      if (node is Map<String, dynamic>) {
        final meta = node['channelMetadataRenderer'];
        if (meta is Map<String, dynamic>) {
          final t = meta['title']?.toString();
          if (t != null && t.isNotEmpty) {
            found = t;
            return;
          }
        }
        for (final v in node.values) {
          walk(v);
          if (found != null) return;
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
          if (found != null) return;
        }
      }
    }

    walk(data);
    return found;
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
        final ch = node['channelRenderer'];
        if (ch is Map<String, dynamic>) {
          final channel = _parseChannelRenderer(ch);
          if (channel != null) tracks.add(channel);
        }
        // YouTube rolled out `lockupViewModel` as the new wrapper for
        // channel-page video tiles (and increasingly for search too).
        // Same recurse walk needs to recognise it or channel pages
        // come back empty.
        final lv = node['lockupViewModel'];
        if (lv is Map<String, dynamic>) {
          final track = _parseLockupViewModel(lv);
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

  /// Parser for YouTube's new `lockupViewModel` shape (rolled out in
  /// 2024–2025 as a replacement for `videoRenderer` on channel Videos
  /// tab responses). Structure:
  ///   contentId          → videoId
  ///   contentType        → must be "LOCKUP_CONTENT_TYPE_VIDEO"
  ///   metadata.lockupMetadataViewModel.title.content       → title
  ///   metadata...metadataRows[0].metadataParts[*].text     → views + "3 weeks ago"
  ///   contentImage.thumbnailViewModel.image.sources[last]  → best thumb
  ///   contentImage...overlays[*].thumbnailBadgeViewModel.text → "24:04"
  Track? _parseLockupViewModel(Map<String, dynamic> lv) {
    try {
      if (lv['contentType'] != 'LOCKUP_CONTENT_TYPE_VIDEO') return null;
      final videoId = lv['contentId']?.toString();
      if (videoId == null || videoId.isEmpty) return null;

      final md = lv['metadata'] as Map<String, dynamic>?;
      final metaVm = md?['lockupMetadataViewModel'] as Map<String, dynamic>?;
      if (metaVm == null) return null;

      final title =
          (metaVm['title'] as Map<String, dynamic>?)?['content']?.toString() ??
              '';
      if (title.isEmpty) return null;

      // Duration lives in the thumbnail badge overlay ("24:04" etc.).
      Duration duration = Duration.zero;
      final tv = ((lv['contentImage'] as Map?)?['thumbnailViewModel']) as Map?;
      final overlays = tv?['overlays'] as List?;
      if (overlays != null) {
        for (final o in overlays) {
          if (o is! Map) continue;
          final bottom = o['thumbnailBottomOverlayViewModel'] as Map?;
          final badges = bottom?['badges'] as List?;
          if (badges == null) continue;
          for (final b in badges) {
            if (b is! Map) continue;
            final badge = b['thumbnailBadgeViewModel'] as Map?;
            final text = badge?['text']?.toString();
            if (text != null && text.contains(':')) {
              duration = _parseDurationString(text);
              break;
            }
          }
          if (duration != Duration.zero) break;
        }
      }

      // View count + upload date subtitle → stashed on `album`.
      String subtitle = '';
      final rows = ((metaVm['metadata'] as Map?)
          ?['contentMetadataViewModel']?['metadataRows']) as List?;
      if (rows != null && rows.isNotEmpty) {
        final parts =
            (rows.first as Map?)?['metadataParts'] as List? ?? const [];
        final texts = parts
            .whereType<Map>()
            .map((p) => (p['text'] as Map?)?['content']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
        if (texts.isNotEmpty) subtitle = texts.join(' · ');
      }

      // Big thumbnail — take the last source (highest resolution).
      String thumb = 'https://i.ytimg.com/vi/$videoId/hq720.jpg';
      final sources = ((tv?['image'] as Map?)?['sources']) as List?;
      if (sources != null && sources.isNotEmpty) {
        thumb = (sources.last as Map)['url']?.toString() ?? thumb;
      }

      return Track(
        id: 'yt:$videoId',
        title: title,
        artist: '', // channel context sets this at the ArtistScreen level
        album: subtitle.isEmpty ? null : subtitle,
        thumbnailUrl: thumb,
        duration: duration,
        sourceVideoId: videoId,
        addedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  /// A YouTube channel result is encoded as a Track with an "ytch:"
  /// id prefix so the search UI can distinguish it from a playable
  /// video and route the tap to the artist page.
  Track? _parseChannelRenderer(Map<String, dynamic> ch) {
    try {
      final channelId = ch['channelId']?.toString();
      if (channelId == null || channelId.isEmpty) return null;
      final title = (ch['title']?['simpleText'])?.toString() ??
          (((ch['title']?['runs']) as List?)?.first?['text'])?.toString() ??
          '';
      if (title.isEmpty) return null;

      // Thumbnails come back as a list of {url, width, height} at
      // increasing sizes — take the last (biggest).
      String thumb = '';
      final thumbs =
          ((ch['thumbnail'] as Map?)?['thumbnails']) as List?;
      if (thumbs != null && thumbs.isNotEmpty) {
        final raw = (thumbs.last as Map)['url']?.toString() ?? '';
        // Rewrite the "=s##-c-k..." size suffix to force a big fetch.
        thumb = raw.replaceFirstMapped(
          RegExp(r'=s\d+'),
          (_) => '=s720',
        );
        if (thumb.startsWith('//')) thumb = 'https:$thumb';
      }

      final subCountText =
          (ch['videoCountText']?['simpleText'])?.toString() ??
              (ch['subscriberCountText']?['simpleText'])?.toString() ??
              '';

      return Track(
        id: 'ytch:$channelId',
        title: title,
        artist: subCountText.isNotEmpty ? subCountText : 'Channel',
        thumbnailUrl: thumb,
        duration: Duration.zero,
        sourceVideoId: channelId, // reused slot for channel id
        addedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
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
      Duration duration = Duration.zero;
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
          // YT Music packs duration as the LAST text run of flexColumns[1]
          // in "M:SS" or "H:MM:SS" format (e.g. "5:22"). Walk the runs
          // in reverse and pick the first one matching that shape.
          final durRegex = RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$');
          for (final t in candidates.reversed) {
            if (durRegex.hasMatch(t.trim())) {
              duration = _parseDurationString(t.trim());
              break;
            }
          }
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
        duration: duration,
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
