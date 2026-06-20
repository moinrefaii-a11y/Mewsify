import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../features/player/player_screen.dart';

/// Persistent strip above the bottom nav. Spotify-style gestures:
///  - tap anywhere     → open full Now Playing
///  - swipe up         → open full Now Playing (with slide-from-bottom anim)
///  - swipe left / right → next / previous track
///  - tap play/pause   → toggle playback
///  - tap skip         → next track
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackAsync = ref.watch(currentTrackProvider);
    final progressAsync = ref.watch(progressProvider);

    final track = trackAsync.valueOrNull;
    if (track == null) return const SizedBox.shrink();

    final progress = progressAsync.valueOrNull;
    final percent = progress == null || progress.duration.inMilliseconds == 0
        ? 0.0
        : (progress.position.inMilliseconds / progress.duration.inMilliseconds)
            .clamp(0.0, 1.0);
    final playing = progress?.playing ?? false;
    final handler = ref.read(audioHandlerProvider);

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => _openPlayer(context),
        child: GestureDetector(
          onVerticalDragEnd: (details) {
            // Swipe up with enough velocity opens the full player.
            if ((details.primaryVelocity ?? 0) < -250) {
              _openPlayer(context);
            }
          },
          onHorizontalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (v < -250) {
              handler.skipToNext();
            } else if (v > 250) {
              handler.skipToPrevious();
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: percent,
                minHeight: 2,
                backgroundColor: Colors.transparent,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Hero(
                      tag: 'now-playing-art',
                      child: Material(
                        type: MaterialType.transparency,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CachedNetworkImage(
                            imageUrl: track.thumbnailUrl,
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => const Icon(Icons.music_note),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: playing ? handler.pause : handler.play,
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: handler.skipToNext,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openPlayer(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        fullscreenDialog: true,
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => const PlayerScreen(),
        transitionsBuilder: (_, animation, __, child) {
          // Slide from the bottom with a slight scale-up — feels like
          // Spotify's mini-bar expanding into the full player.
          final offset = Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
          return SlideTransition(position: offset, child: child);
        },
      ),
    );
  }
}
