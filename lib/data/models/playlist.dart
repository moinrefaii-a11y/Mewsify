import 'package:hive/hive.dart';

import 'track.dart';

part 'playlist.g.dart';

/// A user-created playlist. Tracks are stored in the order the user
/// arranged them — the playlists box itself is keyed by [id].
@HiveType(typeId: 1)
class Playlist extends HiveObject {
  @HiveField(0)
  final String id;
  @HiveField(1)
  String name;
  @HiveField(2)
  List<Track> tracks;
  @HiveField(3)
  final DateTime createdAt;

  Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    required this.createdAt,
  });

  /// First track's thumbnail makes a good cover image; we let the UI
  /// decide what to show when the playlist is empty.
  String? get coverUrl => tracks.isNotEmpty ? tracks.first.thumbnailUrl : null;
}
