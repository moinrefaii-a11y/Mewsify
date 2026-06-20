import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:share_plus/share_plus.dart';

import '../core/providers.dart';
import '../data/models/track.dart';
import '../features/artist/artist_screen.dart';

/// Spotify-style long-press action sheet. Shows the track header at
/// the top, then a vertical list of common actions: Play, Play next,
/// Add to queue, Start radio, Toggle favorite, Share.
class TrackActionsSheet extends ConsumerWidget {
  final Track track;
  const TrackActionsSheet({super.key, required this.track});

  static Future<void> show(BuildContext context, Track track) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => TrackActionsSheet(track: track),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(audioHandlerProvider);
    final library = ref.read(libraryProvider);
    final isFav = library.isFavorite(track.id);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: track.thumbnailUrl,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      width: 56,
                      height: 56,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.music_note),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.play_arrow_rounded),
            title: const Text('Play now'),
            onTap: () async {
              Navigator.pop(context);
              await handler.playWithAutoplay(track);
              await library.recordPlay(track);
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_play_rounded),
            title: const Text('Play next'),
            onTap: () async {
              Navigator.pop(context);
              await handler.playNext(track);
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music_rounded),
            title: const Text('Add to queue'),
            onTap: () async {
              Navigator.pop(context);
              await handler.addQueueItem(track.toMediaItem());
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add_rounded),
            title: const Text('Add to playlist'),
            onTap: () async {
              Navigator.pop(context);
              await _showPickPlaylist(context, ref, track);
            },
          ),
          ListTile(
            leading: const Icon(Icons.radio_rounded),
            title: const Text('Start radio'),
            subtitle: const Text('Endless queue of related tracks'),
            onTap: () async {
              Navigator.pop(context);
              await handler.startRadio(track);
            },
          ),
          ListTile(
            leading: Icon(
              isFav ? Icons.favorite : Icons.favorite_border,
              color: isFav ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Text(isFav ? 'Remove from favorites' : 'Add to favorites'),
            onTap: () async {
              await library.toggleFavorite(track);
              if (context.mounted) Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.person_outline_rounded),
            title: Text('View ${track.artist}'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ArtistScreen(
                  artistName: track.artist,
                  seedThumbnail: track.thumbnailUrl,
                ),
              ));
            },
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('Share'),
            onTap: () async {
              Navigator.pop(context);
              await _shareTrack(track);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}


/// Build a Spotify-style share message and pass it to the OS share sheet.
/// We include the YouTube URL as the canonical link — it works for
/// everyone (opens in YouTube / browser if the recipient doesn't have
/// MewSify, and the MewSify intent filter intercepts it if they do).
Future<void> _shareTrack(Track track) async {
  final url = 'https://youtu.be/${track.sourceVideoId}';
  final body = '🎵 Listen to "${track.title}" by ${track.artist}\n\n'
      'On MewSify  •  $url';
  await SharePlus.instance.share(
    ShareParams(text: body, subject: '${track.title} — ${track.artist}'),
  );
}


/// Bottom sheet that lists existing playlists + a "New playlist" entry
/// at the top. Tapping a playlist drops the track into it.
Future<void> _showPickPlaylist(
    BuildContext context, WidgetRef ref, Track track) async {
  final library = ref.read(libraryProvider);
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Add to playlist',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('New playlist'),
              onTap: () async {
                Navigator.pop(sheetContext);
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
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, controller.text),
                          child: const Text('Create')),
                    ],
                  ),
                );
                if (name != null && name.trim().isNotEmpty) {
                  final pl = await library.createPlaylist(name);
                  await library.addTrackToPlaylist(pl.id, track);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Added to "${pl.name}"')),
                    );
                  }
                }
              },
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final p in library.playlists)
                      ListTile(
                        leading: const Icon(Icons.queue_music_rounded),
                        title: Text(p.name),
                        subtitle: Text(
                          '${p.tracks.length} ${p.tracks.length == 1 ? "track" : "tracks"}',
                        ),
                        onTap: () async {
                          Navigator.pop(sheetContext);
                          await library.addTrackToPlaylist(p.id, track);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Added to "${p.name}"')),
                            );
                          }
                        },
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    },
  );
}
