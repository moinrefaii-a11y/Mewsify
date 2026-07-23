import 'dart:math' as math;

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

  /// Spotify-style expand.
  ///
  /// We use a container-transform route: the artwork is heroed, and a
  /// custom transition scales + translates the entire full player up
  /// from the bottom while the mini-player's row fades out. Draggable
  /// close is handled inside PlayerScreen via its Navigator.pop on the
  /// down-chevron and — for a real Spotify feel — a vertical drag.
  void _openPlayer(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, __, ___) => const _DraggablePlayer(),
        transitionsBuilder: (_, animation, __, child) {
          // Combined slide-up + subtle scale for the natural "grow"
          // motion; opacity ramps in at the tail so the mini isn't
          // fighting the full player for pixels mid-transition.
          final slide = Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(
              parent: animation, curve: Curves.easeOutCubic));
          final scale = Tween<double>(begin: 0.94, end: 1.0).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
          return SlideTransition(
            position: slide,
            child: ScaleTransition(
              scale: scale,
              alignment: Alignment.bottomCenter,
              child: FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.1, 1.0),
                ),
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Wraps [PlayerScreen] in a `GestureDetector` that closes the route
/// when the user drags the view down more than a small threshold —
/// mirroring the Spotify / Apple Music vertical dismiss gesture.
class _DraggablePlayer extends StatefulWidget {
  const _DraggablePlayer();

  @override
  State<_DraggablePlayer> createState() => _DraggablePlayerState();
}

class _DraggablePlayerState extends State<_DraggablePlayer>
    with SingleTickerProviderStateMixin {
  double _dragOffset = 0.0;
  bool _draggingHeader = false;

  static const _dismissThreshold = 90.0;

  @override
  Widget build(BuildContext context) {
    // Translate the whole player during the drag so it visually
    // follows the user's finger; when they let go we either dismiss
    // (if past threshold) or spring back.
    return GestureDetector(
      // Only listen for vertical drags that started at the very top
      // (first 120 px) — otherwise scrolling within the player would
      // accidentally trigger dismiss.
      onVerticalDragStart: (details) {
        if (details.localPosition.dy < 120) {
          _draggingHeader = true;
        }
      },
      onVerticalDragUpdate: (details) {
        if (!_draggingHeader) return;
        setState(() {
          _dragOffset = math.max(0, _dragOffset + details.delta.dy);
        });
      },
      onVerticalDragEnd: (_) {
        if (!_draggingHeader) return;
        _draggingHeader = false;
        if (_dragOffset > _dismissThreshold) {
          Navigator.of(context).pop();
        } else {
          setState(() => _dragOffset = 0);
        }
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: _dragOffset == 0 ? 220 : 0),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, _dragOffset, 0),
        child: const PlayerScreen(),
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
