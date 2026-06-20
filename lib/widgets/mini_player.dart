import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../features/player/player_screen.dart';

/// Persistent strip above the bottom nav. Spotify-style gestures:
///  - tap anywhere       → open full Now Playing (slide-from-bottom)
///  - swipe up           → open full Now Playing
///  - swipe left / right → next / previous track
///  - tap play/pause     → toggle playback
///
/// We split the progress bar and play/pause icon into separate
/// ConsumerWidgets so frequent position events don't rebuild the
/// whole row (smoothness win).
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).valueOrNull;
    if (track == null) return const SizedBox.shrink();

    final handler = ref.read(audioHandlerProvider);

    return RepaintBoundary(child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => _openPlayer(context),
        child: GestureDetector(
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) < -250) _openPlayer(context);
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
              const _MiniProgressBar(),
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const _MiniPlayPauseButton(),
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
    ));
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

class _MiniProgressBar extends ConsumerWidget {
  const _MiniProgressBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(progressProvider).valueOrNull;
    final percent = progress == null || progress.duration.inMilliseconds == 0
        ? 0.0
        : (progress.position.inMilliseconds / progress.duration.inMilliseconds)
            .clamp(0.0, 1.0);
    return RepaintBoundary(
      child: LinearProgressIndicator(
        value: percent,
        minHeight: 2,
        backgroundColor: Colors.transparent,
      ),
    );
  }
}

class _MiniPlayPauseButton extends ConsumerStatefulWidget {
  const _MiniPlayPauseButton();

  @override
  ConsumerState<_MiniPlayPauseButton> createState() => _MiniPlayPauseButtonState();
}

class _MiniPlayPauseButtonState extends ConsumerState<_MiniPlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = ref.watch(progressProvider).valueOrNull?.playing ?? false;
    final handler = ref.read(audioHandlerProvider);

    if (playing) {
      _animCtrl.forward();
    } else {
      _animCtrl.reverse();
    }

    return IconButton(
      icon: AnimatedIcon(
        icon: AnimatedIcons.play_pause,
        progress: _animCtrl,
      ),
      onPressed: playing ? handler.pause : handler.play,
    );
  }
}
