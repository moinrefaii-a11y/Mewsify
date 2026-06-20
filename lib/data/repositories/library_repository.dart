import 'package:hive/hive.dart';

import '../models/playlist.dart';
import '../models/track.dart';

/// Persists user library data: favorites, play history, playlists.
class LibraryRepository {
  Box<Track> get _favorites => Hive.box<Track>('favorites');
  Box<Track> get _history => Hive.box<Track>('history');
  Box<Playlist> get _playlists => Hive.box<Playlist>('playlists');

  // --- Favorites --------------------------------------------------------

  List<Track> get favorites =>
      _favorites.values.toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  bool isFavorite(String id) => _favorites.containsKey(id);

  Future<void> toggleFavorite(Track track) async {
    if (_favorites.containsKey(track.id)) {
      await _favorites.delete(track.id);
    } else {
      await _favorites.put(track.id, track.copyWith(addedAt: DateTime.now()));
    }
  }

  // --- History ----------------------------------------------------------

  List<Track> get history =>
      _history.values.toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  Future<void> recordPlay(Track track) async {
    await _history.put(track.id, track.copyWith(addedAt: DateTime.now()));
    // Cap history at 200 entries.
    if (_history.length > 200) {
      final oldest = _history.values.toList()
        ..sort((a, b) => a.addedAt.compareTo(b.addedAt));
      await _history.delete(oldest.first.id);
    }
  }

  Future<void> clearHistory() => _history.clear();

  // --- Playlists --------------------------------------------------------

  List<Playlist> get playlists => _playlists.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  Playlist? getPlaylist(String id) => _playlists.get(id);

  Future<Playlist> createPlaylist(String name) async {
    final id = 'pl-${DateTime.now().millisecondsSinceEpoch}';
    final pl = Playlist(
      id: id,
      name: name.trim().isEmpty ? 'New playlist' : name.trim(),
      tracks: [],
      createdAt: DateTime.now(),
    );
    await _playlists.put(id, pl);
    return pl;
  }

  Future<void> renamePlaylist(String id, String name) async {
    final pl = _playlists.get(id);
    if (pl == null) return;
    pl.name = name.trim().isEmpty ? pl.name : name.trim();
    await pl.save();
  }

  Future<void> deletePlaylist(String id) => _playlists.delete(id);

  Future<void> addTrackToPlaylist(String id, Track track) async {
    final pl = _playlists.get(id);
    if (pl == null) return;
    if (pl.tracks.any((t) => t.id == track.id)) return; // dedupe
    pl.tracks = [...pl.tracks, track];
    await pl.save();
  }

  Future<void> removeTrackFromPlaylist(String id, String trackId) async {
    final pl = _playlists.get(id);
    if (pl == null) return;
    pl.tracks = pl.tracks.where((t) => t.id != trackId).toList();
    await pl.save();
  }

  Future<void> reorderPlaylistTracks(String id, int oldIndex, int newIndex) async {
    final pl = _playlists.get(id);
    if (pl == null) return;
    final tracks = [...pl.tracks];
    if (newIndex > oldIndex) newIndex -= 1;
    final t = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, t);
    pl.tracks = tracks;
    await pl.save();
  }
}
