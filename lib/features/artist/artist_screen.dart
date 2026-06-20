import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/track.dart';
import '../../services/palette_service.dart';
import '../../widgets/track_actions_sheet.dart';
import '../../widgets/track_tile.dart';

/// Spotify-style artist page.
///
/// Search YouTube Music for the artist, render a hero header (large
/// circular avatar + name), then a "Popular" list of their songs and
/// a "Play all" / "Shuffle" call-to-action.
class ArtistScreen extends ConsumerStatefulWidget {
  final String artistName;
  final String? seedThumbnail;

  const ArtistScreen({
    super.key,
    required this.artistName,
    this.seedThumbnail,
  });

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  late Future<List<Track>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(youtubeSourceProvider).search(widget.artistName, limit: 40);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<List<Track>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final tracks = snap.data ?? [];
          // Filter to tracks where the artist matches (case-insensitive
          // contains so "The Weeknd" matches "Weeknd" search).
          final lowered = widget.artistName.toLowerCase();
          final theirTracks = tracks
              .where((t) => t.artist.toLowerCase().contains(lowered) ||
                  lowered.contains(t.artist.toLowerCase()))
              .toList();

          // Use the first matching track's artwork as the hero avatar
          // so it actually shows the artist (not random music album art).
          final heroUrl = theirTracks.isNotEmpty
              ? theirTracks.first.thumbnailUrl
              : (widget.seedThumbnail ?? '');

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 320,
                pinned: true,
                backgroundColor: Theme.of(context).colorScheme.surface,
                flexibleSpace: _ArtistHero(
                  name: widget.artistName,
                  imageUrl: heroUrl,
                  trackCount: theirTracks.length,
                ),
              ),
              SliverToBoxAdapter(
                child: _ActionRow(
                  onPlayAll: () {
                    if (theirTracks.isEmpty) return;
                    ref.read(audioHandlerProvider).setQueue(theirTracks);
                    ref.read(libraryProvider).recordPlay(theirTracks.first);
                  },
                  onShuffle: () {
                    if (theirTracks.isEmpty) return;
                    final shuffled = [...theirTracks]..shuffle();
                    ref.read(audioHandlerProvider).setQueue(shuffled);
                    ref.read(libraryProvider).recordPlay(shuffled.first);
                  },
                ),
              ),
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    'Popular',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              if (theirTracks.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Center(
                      child: Text(
                        'No tracks found for ${widget.artistName}.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                )
              else ...[
                SliverList.builder(
                  itemCount: theirTracks.length,
                  itemBuilder: (_, i) {
                    final t = theirTracks[i];
                    return TrackTile(
                      track: t,
                      wide: true,
                      onTap: () {
                        ref.read(audioHandlerProvider).playWithAutoplay(t);
                        ref.read(libraryProvider).recordPlay(t);
                      },
                      onLongPress: () => TrackActionsSheet.show(context, t),
                      onMore: () => TrackActionsSheet.show(context, t),
                    );
                  },
                ),
                _SimilarArtistsSection(seedTrack: theirTracks.first),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          );
        },
      ),
    );
  }
}

class _ArtistHero extends StatelessWidget {
  final String name;
  final String imageUrl;
  final int trackCount;

  const _ArtistHero({
    required this.name,
    required this.imageUrl,
    required this.trackCount,
  });

  @override
  Widget build(BuildContext context) {
    return FlexibleSpaceBar(
      title: Text(
        name,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
      titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 16, end: 16),
      centerTitle: false,
      background: FutureBuilder<MelodyPalette>(
        future: imageUrl.isEmpty
            ? Future.value(const MelodyPalette(
                primary: Color(0xFF1DB954),
                secondary: Color(0xFF0F0F10),
                text: Colors.white,
              ))
            : PaletteService.instance.getPalette(imageUrl),
        builder: (context, snap) {
          final palette = snap.data;
          return Stack(
            fit: StackFit.expand,
            children: [
              // Tinted gradient backdrop derived from the artwork.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      palette?.primary ?? const Color(0xFF1DB954),
                      Theme.of(context).colorScheme.surface,
                    ],
                  ),
                ),
              ),
              // Centered artist avatar
              Padding(
                padding: const EdgeInsets.only(top: 60, bottom: 60),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 8)),
                      ],
                    ),
                    child: ClipOval(
                      child: imageUrl.isEmpty
                          ? Container(
                              width: 160,
                              height: 160,
                              color: Colors.black26,
                              child: const Icon(Icons.person, size: 64, color: Colors.white70),
                            )
                          : CachedNetworkImage(
                              imageUrl: imageUrl,
                              width: 160,
                              height: 160,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => Container(
                                width: 160,
                                height: 160,
                                color: Colors.black26,
                                child: const Icon(Icons.person, size: 64),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;
  const _ActionRow({required this.onPlayAll, required this.onShuffle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Row(
        children: [
          IconButton(
            iconSize: 28,
            icon: const Icon(Icons.shuffle_rounded),
            onPressed: onShuffle,
            color: scheme.onSurface.withValues(alpha: 0.8),
          ),
          const Spacer(),
          FloatingActionButton(
            heroTag: 'artistPlayAll',
            backgroundColor: scheme.primary,
            onPressed: onPlayAll,
            child: const Icon(Icons.play_arrow_rounded, size: 32),
          ),
        ],
      ),
    );
  }
}


/// "Fans also like" section. Walks the related videos for the seed
/// track, dedupes by artist name, and renders a horizontal grid of
/// circular avatars that open into another ArtistScreen on tap.
class _SimilarArtistsSection extends ConsumerWidget {
  final Track seedTrack;
  const _SimilarArtistsSection({required this.seedTrack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SliverToBoxAdapter(
      child: FutureBuilder<List<Track>>(
        future: ref.read(youtubeSourceProvider).related(seedTrack.sourceVideoId, limit: 30),
        builder: (context, snap) {
          if (!snap.hasData) return const SizedBox.shrink();
          final tracks = snap.data!;
          // Dedupe by artist (lowercase) and skip the current artist.
          final seen = <String>{seedTrack.artist.toLowerCase()};
          final similar = <Track>[];
          for (final t in tracks) {
            final key = t.artist.toLowerCase();
            if (key.isEmpty || key == 'unknown') continue;
            if (seen.add(key)) similar.add(t);
          }
          if (similar.isEmpty) return const SizedBox.shrink();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Text(
                  'Fans also like',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              SizedBox(
                height: 160,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  separatorBuilder: (_, __) => const SizedBox(width: 16),
                  itemCount: similar.length.clamp(0, 12),
                  itemBuilder: (_, i) {
                    final t = similar[i];
                    return GestureDetector(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ArtistScreen(
                          artistName: t.artist,
                          seedThumbnail: t.thumbnailUrl,
                        ),
                      )),
                      child: SizedBox(
                        width: 100,
                        child: Column(
                          children: [
                            ClipOval(
                              child: Image.network(
                                t.thumbnailUrl,
                                width: 90,
                                height: 90,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 90,
                                  height: 90,
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  child: const Icon(Icons.person, size: 40),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              t.artist,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
