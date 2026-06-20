import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/providers.dart';
import '../../data/models/track.dart';
import '../../widgets/eq_indicator.dart';
import '../../widgets/track_actions_sheet.dart';
import '../../widgets/track_artwork.dart';
import '../../widgets/track_tile.dart';
import 'genre_chips.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  /// All curated home feeds. Each one fires a YouTube search behind a
  /// FutureProvider.family and renders as a horizontal carousel. The
  /// list builds lazily — `SliverList.builder` only spins up a
  /// _CategoryFeed (and its network fetch) when the user scrolls it
  /// into view. No 10-parallel-search storm at app start.
  static const _feeds = <_Feed>[
    _Feed('Bollywood hits', 'bollywood new songs 2026'),
    _Feed('Hindi top tracks', 'hindi songs 2026'),
    _Feed('Telugu trending', 'telugu hit songs 2026'),
    _Feed('Tamil hits', 'tamil hit songs 2026'),
    _Feed('Punjabi vibes', 'punjabi hit songs 2026'),
    _Feed('Top podcasts', 'best podcasts 2026'),
    _Feed('Vlogs of the week', 'top vlogs 2026'),
    _Feed('Workout playlist', 'workout music 2026'),
    _Feed('Lo-fi & chill', 'lofi chill beats'),
    _Feed('Comedy clips', 'best stand up comedy'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trending = ref.watch(trendingProvider);
    final madeForYou = ref.watch(madeForYouProvider);
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(trendingProvider);
          ref.invalidate(madeForYouProvider);
          for (final f in _feeds) {
            ref.invalidate(categoryFeedProvider(f.query));
          }
        },
        child: CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(child: _Greeting()),

            // Quick-access grid (Spotify "Recently played" home grid)
            SliverToBoxAdapter(
              child: ValueListenableBuilder(
                valueListenable: Hive.box<Track>('history').listenable(),
                builder: (_, __, ___) {
                  final history = ref.read(libraryProvider).history.take(8).toList();
                  if (history.isEmpty) return const SizedBox.shrink();
                  return _QuickAccessGrid(
                    tracks: history,
                    currentTrackId: currentTrack?.id,
                    ref: ref,
                  );
                },
              ),
            ),

            // Browse / mood tiles
            const SliverToBoxAdapter(child: _SectionHeader('Browse all')),
            const SliverToBoxAdapter(child: GenreChips()),

            // Made for you
            SliverToBoxAdapter(
              child: ValueListenableBuilder(
                valueListenable: Hive.box<Track>('history').listenable(),
                builder: (_, __, ___) {
                  final history = ref.read(libraryProvider).history;
                  if (history.isEmpty) return const SizedBox.shrink();
                  return madeForYou.when(
                    loading: () => const SizedBox.shrink(),
                    error: (_, __) => const SizedBox.shrink(),
                    data: (tracks) {
                      if (tracks.isEmpty) return const SizedBox.shrink();
                      return _Carousel(
                        title: 'Made for you',
                        subtitle: 'Based on what you played recently',
                        tracks: tracks,
                        currentTrackId: currentTrack?.id,
                        ref: ref,
                        size: _CarouselSize.large,
                      );
                    },
                  );
                },
              ),
            ),

            // Favorites
            SliverToBoxAdapter(
              child: ValueListenableBuilder(
                valueListenable: Hive.box<Track>('favorites').listenable(),
                builder: (_, __, ___) {
                  final favs = ref.read(libraryProvider).favorites.take(12).toList();
                  if (favs.isEmpty) return const SizedBox.shrink();
                  return _Carousel(
                    title: 'Your favorites',
                    tracks: favs,
                    currentTrackId: currentTrack?.id,
                    ref: ref,
                  );
                },
              ),
            ),

            // Curated language / category rows (Bollywood, Telugu, Tamil, Podcasts...)
            // SliverList.builder only constructs visible children, so
            // the network calls happen as the user scrolls — no
            // 10-search burst at app launch.
            SliverList.builder(
              itemCount: _feeds.length,
              itemBuilder: (_, i) => _CategoryFeed(
                feed: _feeds[i],
                currentTrackId: currentTrack?.id,
              ),
            ),

            // Trending
            const SliverToBoxAdapter(child: _SectionHeader('Trending now')),
            trending.when(
              loading: () => const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 60),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
              error: (e, _) => SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Could not load trending: $e',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ),
              data: (tracks) {
                if (tracks.isEmpty) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Trending feed is empty right now. Pull to refresh.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  );
                }
                return SliverList.builder(
                  itemCount: tracks.length,
                  itemBuilder: (_, i) {
                    final t = tracks[i];
                    return TrackTile(
                      track: t,
                      isPlaying: currentTrack?.id == t.id,
                      onTap: () {
                        ref.read(audioHandlerProvider).playWithAutoplay(t);
                        ref.read(libraryProvider).recordPlay(t);
                      },
                      onLongPress: () => TrackActionsSheet.show(context, t),
                      onMore: () => TrackActionsSheet.show(context, t),
                    );
                  },
                );
              },
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }
}

class _Feed {
  final String title;
  final String query;
  const _Feed(this.title, this.query);
}

/// One curated horizontal row, lazy-loaded the first time the user
/// scrolls it into view.
class _CategoryFeed extends ConsumerWidget {
  final _Feed feed;
  final String? currentTrackId;
  const _CategoryFeed({required this.feed, required this.currentTrackId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(categoryFeedProvider(feed.query));
    return async.when(
      loading: () => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(feed.title),
          const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ],
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (tracks) {
        if (tracks.isEmpty) return const SizedBox.shrink();
        return _Carousel(
          title: feed.title,
          tracks: tracks,
          currentTrackId: currentTrackId,
          ref: ref,
        );
      },
    );
  }
}

class _Greeting extends ConsumerWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 18
            ? 'Good afternoon'
            : 'Good evening';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Row(
        children: [
          // Branded mini logo + name on the left
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [scheme.primary, Color.lerp(scheme.primary, Colors.tealAccent, 0.5)!],
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  greeting,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                Text(
                  'MewSify',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.notifications_none_rounded, color: scheme.onSurface),
            onPressed: () {},
          ),
          IconButton(
            icon: Icon(Icons.history_rounded, color: scheme.onSurface),
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}

class _QuickAccessGrid extends StatelessWidget {
  final List<Track> tracks;
  final String? currentTrackId;
  final WidgetRef ref;
  const _QuickAccessGrid({
    required this.tracks,
    required this.currentTrackId,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    final items = tracks.take(8).toList();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2.6,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final t = items[i];
          final isCurrent = currentTrackId == t.id;
          return Material(
            color: Color.alphaBlend(
              scheme.primary.withValues(alpha: isCurrent ? 0.18 : 0.0),
              scheme.surfaceContainerHigh,
            ),
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                ref.read(audioHandlerProvider).playWithAutoplay(t);
                ref.read(libraryProvider).recordPlay(t);
              },
              onLongPress: () => TrackActionsSheet.show(context, t),
              child: Row(
                children: [
                  TrackArtwork(
                    url: t.thumbnailUrl,
                    width: 56,
                    height: 56,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(8),
                      bottomLeft: Radius.circular(8),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        t.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isCurrent ? scheme.primary : null,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  const _SectionHeader(this.title, {this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _CarouselSize { regular, large }

class _Carousel extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Track> tracks;
  final String? currentTrackId;
  final WidgetRef ref;
  final _CarouselSize size;
  const _Carousel({
    required this.title,
    this.subtitle,
    required this.tracks,
    required this.currentTrackId,
    required this.ref,
    this.size = _CarouselSize.regular,
  });

  @override
  Widget build(BuildContext context) {
    final cardSize = size == _CarouselSize.large ? 160.0 : 140.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title, subtitle: subtitle),
        SizedBox(
          height: cardSize + 60,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemCount: tracks.length,
            itemBuilder: (_, i) {
              final t = tracks[i];
              final isCurrent = currentTrackId == t.id;
              return _CarouselCard(
                track: t,
                isCurrent: isCurrent,
                ref: ref,
                size: cardSize,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CarouselCard extends StatelessWidget {
  final Track track;
  final bool isCurrent;
  final WidgetRef ref;
  final double size;
  const _CarouselCard({
    required this.track,
    required this.isCurrent,
    required this.ref,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        ref.read(audioHandlerProvider).playWithAutoplay(track);
        ref.read(libraryProvider).recordPlay(track);
      },
      onLongPress: () => TrackActionsSheet.show(context, track),
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                children: [
                  TrackArtwork(
                    url: track.thumbnailUrl,
                    width: size,
                    height: size,
                  ),
                  if (isCurrent)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.45),
                        child: Center(
                          child: EqIndicator(size: 28, color: scheme.primary),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: isCurrent ? scheme.primary : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
