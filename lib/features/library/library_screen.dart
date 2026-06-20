import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/providers.dart';
import '../../data/models/playlist.dart';
import '../../data/models/track.dart';
import '../../widgets/track_actions_sheet.dart';
import '../../widgets/track_artwork.dart';
import '../../widgets/track_tile.dart';
import 'playlist_screen.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Library',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text('Smart shuffle'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: () async {
                    await ref.read(audioHandlerProvider).smartShuffle();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Started a smart shuffle mix')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: 'Favorites'),
              Tab(text: 'Playlists'),
              Tab(text: 'History'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                ValueListenableBuilder(
                  valueListenable: Hive.box<Track>('favorites').listenable(),
                  builder: (_, __, ___) => _trackList(
                    library.favorites,
                    emptyMessage: 'Tap the heart on a track to favorite it.',
                  ),
                ),
                _PlaylistsTab(library: library),
                ValueListenableBuilder(
                  valueListenable: Hive.box<Track>('history').listenable(),
                  builder: (_, __, ___) => _trackList(
                    library.history,
                    emptyMessage: 'Songs you play will show up here.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _trackList(List<Track> tracks, {required String emptyMessage}) {
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (_, i) {
        final t = tracks[i];
        return TrackTile(
          track: t,
          onTap: () {
            ref.read(audioHandlerProvider).playWithAutoplay(t);
            ref.read(libraryProvider).recordPlay(t);
          },
          onLongPress: () => TrackActionsSheet.show(context, t),
          onMore: () => TrackActionsSheet.show(context, t),
        );
      },
    );
  }
}

class _PlaylistsTab extends ConsumerWidget {
  final dynamic library;
  const _PlaylistsTab({required this.library});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder(
      valueListenable: Hive.box<Playlist>('playlists').listenable(),
      builder: (_, __, ___) {
        final playlists = library.playlists as List<Playlist>;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.add_rounded),
                label: const Text('New playlist'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed: () => _createPlaylist(context, ref),
              ),
            ),
            Expanded(
              child: playlists.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No playlists yet. Create one and start adding songs by long-pressing any track.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: playlists.length,
                      itemBuilder: (_, i) {
                        final p = playlists[i];
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: p.coverUrl != null
                                ? TrackArtwork(
                                    url: p.coverUrl!,
                                    width: 56,
                                    height: 56,
                                  )
                                : Container(
                                    width: 56,
                                    height: 56,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    child: const Icon(Icons.queue_music_rounded),
                                  ),
                          ),
                          title: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${p.tracks.length} ${p.tracks.length == 1 ? "track" : "tracks"}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PlaylistScreen(playlistId: p.id),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await ref.read(libraryProvider).createPlaylist(name);
    }
  }
}
