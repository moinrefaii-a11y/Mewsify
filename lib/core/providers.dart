import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../data/models/track.dart';
import '../data/repositories/library_repository.dart';
import '../data/sources/youtube_source.dart';
import '../main.dart' show audioHandler;
import '../services/audio_handler.dart';
import '../services/overlay_service.dart';

/// Singleton-style providers that hand out the long-lived services.
final youtubeSourceProvider = Provider<YouTubeSource>((ref) {
  final source = YouTubeSource();
  ref.onDispose(source.dispose);
  return source;
});

final libraryProvider = Provider<LibraryRepository>((ref) => LibraryRepository());

final audioHandlerProvider = Provider<MelodyAudioHandler>((ref) => audioHandler);

final overlayServiceProvider = Provider<OverlayService>(
  (ref) => OverlayService(ref.watch(audioHandlerProvider)),
);

// --- UI state ----------------------------------------------------------

/// Currently displayed search results.
final searchResultsProvider = StateProvider<List<Track>>((ref) => []);

/// Whether a search request is in flight.
final searchLoadingProvider = StateProvider<bool>((ref) => false);

/// Trending tracks shown on the home tab.
final trendingProvider = FutureProvider<List<Track>>((ref) async {
  final yt = ref.watch(youtubeSourceProvider);
  return yt.trending(limit: 25);
});

/// Personalized "Made for you" feed — pulls related videos from the
/// user's most recently played track, mirroring Spotify's "Daily Mix"
/// idea on a much simpler signal.
final madeForYouProvider = FutureProvider<List<Track>>((ref) async {
  final library = ref.watch(libraryProvider);
  final history = library.history;
  if (history.isEmpty) return const [];
  final yt = ref.watch(youtubeSourceProvider);
  return yt.related(history.first.sourceVideoId, limit: 20);
});

/// Family of category-specific feeds. Each row on the home screen
/// (Bollywood, Hindi, Telugu, Podcasts, etc.) is a different instance
/// of this provider keyed by the search query.
final categoryFeedProvider =
    FutureProvider.family<List<Track>, String>((ref, query) async {
  final yt = ref.watch(youtubeSourceProvider);
  return yt.search(query, limit: 18);
});

/// Live progress for the player UI.
final progressProvider = StreamProvider<ProgressData>((ref) {
  return ref.watch(audioHandlerProvider).progressStream;
});

// --- Theme settings ---------------------------------------------------

/// User-selected ThemeMode (system / light / dark). Persisted in Hive.
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>(
  (ref) => ThemeModeNotifier(),
);

/// User-selected accent color seed. Persisted in Hive.
final themeSeedProvider = StateNotifierProvider<ThemeSeedNotifier, int>(
  (ref) => ThemeSeedNotifier(),
);

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(_load());

  static ThemeMode _load() {
    final box = Hive.box('settings');
    final raw = box.get('themeMode', defaultValue: 'dark') as String;
    return ThemeMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => ThemeMode.dark,
    );
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await Hive.box('settings').put('themeMode', mode.name);
  }
}

class ThemeSeedNotifier extends StateNotifier<int> {
  ThemeSeedNotifier()
      : super(
          Hive.box('settings').get('themeSeed', defaultValue: 0xFF1DB954) as int,
        );

  Future<void> set(int colorValue) async {
    state = colorValue;
    await Hive.box('settings').put('themeSeed', colorValue);
  }
}

/// Stream of player errors (network 403, source not found, etc.).
final playerErrorProvider = StreamProvider<String?>((ref) {
  return ref.watch(audioHandlerProvider).errorEvents.stream;
});

/// Whether the Now Playing screen renders the actual YouTube video
/// (true) or just the album art (false). Defaults to "photo" mode.
final videoModeProvider = StateProvider<bool>((ref) => false);

/// Reactive shuffle mode for the player UI.
final shuffleModeProvider = StreamProvider<bool>((ref) {
  return ref.watch(audioHandlerProvider).shuffleMode.stream;
});

/// Reactive repeat mode (off/all/one) for the player UI.
final repeatModeProvider = StreamProvider<PlaybackRepeat>((ref) {
  return ref.watch(audioHandlerProvider).repeatMode.stream;
});

/// Active sleep timer remaining duration. Null when disabled.
final sleepTimerProvider = StreamProvider<Duration?>((ref) {
  return ref.watch(audioHandlerProvider).sleepTimer.stream;
});

/// The currently playing track (or null when nothing is playing).
final currentTrackProvider = StreamProvider<Track?>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return handler.mediaItem.map((item) {
    if (item == null) return null;
    return Track(
      id: item.id,
      title: item.title,
      artist: item.artist ?? 'Unknown',
      album: item.album,
      thumbnailUrl: item.artUri?.toString() ?? '',
      duration: item.duration ?? Duration.zero,
      sourceVideoId: item.extras?['videoId'] as String? ?? '',
      addedAt: DateTime.now(),
    );
  });
});
