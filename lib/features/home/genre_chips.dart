import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../widgets/track_tile.dart';
import '../../widgets/track_actions_sheet.dart';

/// Curated list of genres / moods. Each one fires a YouTube search
/// pre-filled with a music-friendly query and shows results in a
/// bottom sheet, just like Spotify's Browse cards.
class GenreChips extends ConsumerWidget {
  const GenreChips({super.key});

  static const _genres = <_Genre>[
    _Genre('Pop', '🎤', Color(0xFFE91E63), 'top pop hits 2026'),
    _Genre('Hip-hop', '🎧', Color(0xFF7E57C2), 'hip hop hits 2026'),
    _Genre('Bollywood', '🎬', Color(0xFFFF7043), 'bollywood new songs'),
    _Genre('Lo-fi', '🌙', Color(0xFF26A69A), 'lofi hip hop chill beats'),
    _Genre('Workout', '💪', Color(0xFFEF5350), 'workout gym music'),
    _Genre('Chill', '🌊', Color(0xFF42A5F5), 'chill music playlist'),
    _Genre('Rock', '🎸', Color(0xFFFFA726), 'rock hits classic'),
    _Genre('R&B', '🌹', Color(0xFFAB47BC), 'rnb soul hits'),
    _Genre('Indie', '🎵', Color(0xFF66BB6A), 'indie music best'),
    _Genre('Electronic', '⚡', Color(0xFF26C6DA), 'edm electronic dance'),
    _Genre('Punjabi', '🎉', Color(0xFFD81B60), 'punjabi songs'),
    _Genre('Tamil', '🌟', Color(0xFFF4511E), 'tamil hits new'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _genres.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final g = _genres[i];
          return _GenreCard(genre: g);
        },
      ),
    );
  }
}

class _Genre {
  final String name;
  final String emoji;
  final Color color;
  final String query;
  const _Genre(this.name, this.emoji, this.color, this.query);
}

class _GenreCard extends ConsumerWidget {
  final _Genre genre;
  const _GenreCard({required this.genre});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => _openGenre(context, ref),
      child: Container(
        width: 150,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [genre.color, Color.lerp(genre.color, Colors.black, 0.4)!],
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: Text(
                genre.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomRight,
              child: Transform.rotate(
                angle: 0.4,
                child: Text(
                  genre.emoji,
                  style: const TextStyle(fontSize: 36),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openGenre(BuildContext context, WidgetRef ref) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _GenreSheet(genre: genre),
    );
  }
}

class _GenreSheet extends ConsumerStatefulWidget {
  final _Genre genre;
  const _GenreSheet({required this.genre});

  @override
  ConsumerState<_GenreSheet> createState() => _GenreSheetState();
}

class _GenreSheetState extends ConsumerState<_GenreSheet> {
  late Future<List<dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(youtubeSourceProvider).search(widget.genre.query);
  }

  @override
  Widget build(BuildContext context) {
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [widget.genre.color, Color.lerp(widget.genre.color, Colors.black, 0.5)!],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Text(
                    widget.genre.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<dynamic>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(
                      child: Text('Could not load: ${snap.error}'),
                    );
                  }
                  final tracks = snap.data ?? [];
                  if (tracks.isEmpty) {
                    return const Center(child: Text('No tracks found'));
                  }
                  return ListView.builder(
                    controller: scrollController,
                    itemCount: tracks.length,
                    itemBuilder: (_, i) {
                      final t = tracks[i];
                      return TrackTile(
                        track: t,
                        wide: true,
                        isPlaying: currentTrack?.id == t.id,
                        onTap: () async {
                          await ref.read(audioHandlerProvider).playWithAutoplay(t);
                          await ref.read(libraryProvider).recordPlay(t);
                          if (context.mounted) Navigator.pop(context);
                        },
                        onMore: () => TrackActionsSheet.show(context, t),
                        onLongPress: () => TrackActionsSheet.show(context, t),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
