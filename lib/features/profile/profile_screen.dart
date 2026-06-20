import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/providers.dart';
import '../../data/models/track.dart';
import '../settings/settings_screen.dart';

/// Spotify "Profile" / Apple Music "You" — top artists, listening stats,
/// quick links to Settings, and a stylish header.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ValueListenableBuilder(
        valueListenable: Hive.box<Track>('history').listenable(),
        builder: (_, __, ___) {
          final library = ref.read(libraryProvider);
          final history = library.history;
          final favorites = library.favorites;

          // Tally most-played artists from history.
          final artistCounts = <String, int>{};
          for (final t in history) {
            if (t.artist.isEmpty) continue;
            artistCounts[t.artist] = (artistCounts[t.artist] ?? 0) + 1;
          }
          final topArtists = artistCounts.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));

          final totalListenedMin = history.fold<int>(
            0,
            (sum, t) => sum + (t.duration.inMinutes),
          );

          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _ProfileHeader(
                  favoritesCount: favorites.length,
                  historyCount: history.length,
                  totalListenedMin: totalListenedMin,
                ),
              ),
              if (topArtists.isNotEmpty) ...[
                const SliverToBoxAdapter(child: _SectionTitle('Top artists')),
                SliverToBoxAdapter(
                  child: _TopArtistsRow(
                    entries: topArtists.take(8).toList(),
                    historyByArtist: _byArtist(history),
                  ),
                ),
              ],
              if (history.isNotEmpty) ...[
                const SliverToBoxAdapter(child: _SectionTitle('Listening overview')),
                SliverToBoxAdapter(
                  child: _StatsRow(
                    total: history.length,
                    favorites: favorites.length,
                    minutes: totalListenedMin,
                    primary: scheme.primary,
                  ),
                ),
              ],
              const SliverToBoxAdapter(child: _SectionTitle('Settings')),
              SliverToBoxAdapter(
                child: ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('App settings'),
                  subtitle: const Text('Theme, equalizer, crossfade and more'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Settings')),
                        body: const SettingsScreen(),
                      ),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          );
        },
      ),
    );
  }

  Map<String, Track> _byArtist(List<Track> history) {
    final byArtist = <String, Track>{};
    for (final t in history) {
      byArtist.putIfAbsent(t.artist, () => t);
    }
    return byArtist;
  }
}

class _ProfileHeader extends StatelessWidget {
  final int favoritesCount;
  final int historyCount;
  final int totalListenedMin;
  const _ProfileHeader({
    required this.favoritesCount,
    required this.historyCount,
    required this.totalListenedMin,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.5),
            scheme.surface,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [scheme.primary, Color.lerp(scheme.primary, Colors.tealAccent, 0.5)!],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(Icons.person_rounded, color: Colors.white, size: 40),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'You',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'MewSify member',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _TopArtistsRow extends StatelessWidget {
  final List<MapEntry<String, int>> entries;
  final Map<String, Track> historyByArtist;
  const _TopArtistsRow({required this.entries, required this.historyByArtist});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 140,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemCount: entries.length,
        itemBuilder: (_, i) {
          final entry = entries[i];
          final track = historyByArtist[entry.key];
          return SizedBox(
            width: 96,
            child: Column(
              children: [
                ClipOval(
                  child: track == null
                      ? Container(
                          width: 80,
                          height: 80,
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.person, size: 40),
                        )
                      : CachedNetworkImage(
                          imageUrl: track.thumbnailUrl,
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            width: 80,
                            height: 80,
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.person, size: 40),
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                Text(
                  entry.key,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${entry.value} play${entry.value == 1 ? "" : "s"}',
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final int total;
  final int favorites;
  final int minutes;
  final Color primary;
  const _StatsRow({
    required this.total,
    required this.favorites,
    required this.minutes,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(child: _StatCard(label: 'Songs played', value: '$total', color: primary)),
          const SizedBox(width: 8),
          Expanded(child: _StatCard(label: 'Favorites', value: '$favorites', color: primary)),
          const SizedBox(width: 8),
          Expanded(child: _StatCard(label: 'Minutes', value: '$minutes', color: primary)),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatCard({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }
}
