// Hand-written Hive adapter so the project compiles without running
// build_runner. Re-generate with `flutter pub run build_runner build`
// if you change the Track model.

part of 'track.dart';

class TrackAdapter extends TypeAdapter<Track> {
  @override
  final int typeId = 0;

  @override
  Track read(BinaryReader reader) {
    final fields = <int, dynamic>{
      for (var i = 0, n = reader.readByte(); i < n; i++)
        reader.readByte(): reader.read(),
    };
    return Track(
      id: fields[0] as String,
      title: fields[1] as String,
      artist: fields[2] as String,
      album: fields[3] as String?,
      thumbnailUrl: fields[4] as String,
      duration: Duration(milliseconds: fields[5] as int),
      sourceVideoId: fields[6] as String,
      addedAt: DateTime.fromMillisecondsSinceEpoch(fields[7] as int),
    );
  }

  @override
  void write(BinaryWriter writer, Track obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.artist)
      ..writeByte(3)
      ..write(obj.album)
      ..writeByte(4)
      ..write(obj.thumbnailUrl)
      ..writeByte(5)
      ..write(obj.duration.inMilliseconds)
      ..writeByte(6)
      ..write(obj.sourceVideoId)
      ..writeByte(7)
      ..write(obj.addedAt.millisecondsSinceEpoch);
  }
}
