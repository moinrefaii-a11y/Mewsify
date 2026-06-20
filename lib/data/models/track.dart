import 'package:audio_service/audio_service.dart';
import 'package:hive/hive.dart';

part 'track.g.dart';

/// A track is the universal unit of playback. Streamed live from YouTube
/// at play time using the InnerTube extractor.
@HiveType(typeId: 0)
class Track {
  @HiveField(0)
  final String id; // Source-prefixed id, e.g. "yt:dQw4w9WgXcQ"
  @HiveField(1)
  final String title;
  @HiveField(2)
  final String artist;
  @HiveField(3)
  final String? album;
  @HiveField(4)
  final String thumbnailUrl;
  @HiveField(5)
  final Duration duration;
  @HiveField(6)
  final String sourceVideoId;
  @HiveField(7)
  final DateTime addedAt;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    required this.duration,
    required this.sourceVideoId,
    this.album,
    required this.addedAt,
  });

  Track copyWith({DateTime? addedAt}) => Track(
        id: id,
        title: title,
        artist: artist,
        album: album,
        thumbnailUrl: thumbnailUrl,
        duration: duration,
        sourceVideoId: sourceVideoId,
        addedAt: addedAt ?? this.addedAt,
      );

  /// audio_service representation, surfaced on lock screen and notifications.
  MediaItem toMediaItem() => MediaItem(
        id: id,
        title: title,
        artist: artist,
        album: album,
        artUri: Uri.parse(thumbnailUrl),
        duration: duration,
        extras: {'videoId': sourceVideoId},
      );

  @override
  bool operator ==(Object other) => other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
