import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/providers.dart';
import '../../data/models/playlist.dart';
import '../../widgets/track_actions_sheet.dart';
import '../../widgets/track_artwork.dart';

/// Detail view for a single user-created playlist. Reorderable list,
/// remove-track swipe, "play all" + "shuffle" actions in the header.
class PlaylistScreen extends ConsumerStatefulWidget {
  final String playlistId;
  const PlaylistScreen({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Hive.box<Playlist>('playlists').listenable(keys: [widget.playlistId]),
      builder: (_, __, ___) {
        final library = ref.read(libraryProvider);
        final playlist = library.getPlaylist(widget.playlistId);
        if (playlist == null) {
          return const Scaffold(body: Center(child: Text('Playlist not found')));
        }
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 240,
                pinned: true,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _editPlaylist(playlist),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deletePlaylist(playlist),
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  title: Text(
                    playlist.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 16, end: 16),
                  background: _PlaylistHeader(playlist: playlist),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${playlist.tracks.length} ${playlist.tracks.length == 1 ? "track" : "tracks"}',
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: 0.65),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.shuffle_rounded),
                        onPressed: playlist.tracks.isEmpty
                            ? null
                            : () {
                                final shuffled = [...playlist.tracks]..shuffle();
                                ref.read(audioHandlerProvider).setQueue(shuffled);
                              },
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Play'),
                        onPressed: playlist.tracks.isEmpty
                            ? null
                            : () => ref.read(audioHandlerProvider).setQueue(playlist.tracks),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (playlist.tracks.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(
                      child: Text(
                        'This playlist is empty.\nAdd songs by long-pressing any track and choosing "Add to playlist".',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                )
              else
                SliverReorderableList(
                  itemCount: playlist.tracks.length,
                  onReorder: (oldIdx, newIdx) {
                    library.reorderPlaylistTracks(playlist.id, oldIdx, newIdx);
                  },
                  itemBuilder: (context, i) {
                    final t = playlist.tracks[i];
                    return Dismissible(
                      key: ValueKey('${playlist.id}-${t.id}-$i'),
                      background: Container(
                        color: scheme.error.withValues(alpha: 0.6),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) =>
                          library.removeTrackFromPlaylist(playlist.id, t.id),
                      child: ListTile(
                        leading: TrackArtwork(
                          url: t.thumbnailUrl,
                          width: 48,
                          height: 48,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        title: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_handle),
                        ),
                        onTap: () {
                          ref
                              .read(audioHandlerProvider)
                              .setQueue(playlist.tracks, startIndex: i);
                          ref.read(libraryProvider).recordPlay(t);
                        },
                        onLongPress: () => TrackActionsSheet.show(context, t),
                      ),
                    );
                  },
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
        );
      },
    );
  }

  Future<void> _editPlaylist(Playlist playlist) async {
    final controller = TextEditingController(text: playlist.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.trim().isNotEmpty) {
      await ref.read(libraryProvider).renamePlaylist(playlist.id, newName);
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${playlist.name}"?'),
        content: const Text('The playlist will be removed but the tracks stay in your library.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(libraryProvider).deletePlaylist(playlist.id);
      if (mounted) Navigator.pop(context);
    }
  }
}

class _PlaylistHeader extends StatelessWidget {
  final Playlist playlist;
  const _PlaylistHeader({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primary.withValues(alpha: 0.6),
                scheme.surface,
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 64, bottom: 64),
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: playlist.coverUrl == null
                  ? Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [scheme.primary, Color.lerp(scheme.primary, Colors.tealAccent, 0.5)!],
                        ),
                      ),
                      child: const Icon(Icons.queue_music_rounded,
                          color: Colors.white, size: 56),
                    )
                  : TrackArtwork(
                      url: playlist.coverUrl!,
                      width: 120,
                      height: 120,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
