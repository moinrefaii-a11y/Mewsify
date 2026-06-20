import 'package:hive/hive.dart';

import '../models/track.dart';

/// Persists user library data: favorites and play history.
class LibraryRepository {
  Box<Track> get _favorites => Hive.box<Track>('favorites');
  Box<Track> get _history => Hive.box<Track>('history');

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
}
