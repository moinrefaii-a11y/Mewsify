import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers.dart';
import '../../data/models/track.dart';
import '../../services/audio_handler.dart';
import '../../services/palette_service.dart';
import '../../services/pip_service.dart';
import '../../widgets/track_artwork.dart';
import 'queue_sheet.dart';
import 'sleep_timer_sheet.dart';
import 'video_view.dart';

/// Last-known YouTube video position when video mode was active.
/// Read by the toggle handler to seek the audio player on handoff.
final _lastVideoPositionProvider = StateProvider<Duration>((_) => Duration.zero);

/// Full-screen Now Playing UI: large artwork, title, scrubber, transport,
/// and an extras row for sleep timer / queue.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackAsync = ref.watch(currentTrackProvider);
    final progressAsync = ref.watch(progressProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: trackAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (track) {
          if (track == null) return const Center(child: Text('Nothing playing'));
          return Stack(
            fit: StackFit.expand,
            children: [
              // Heavily-blurred album art behind everything for that
              // YMusic / Apple Music / Spotify Now Playing vibe.
              _BlurredBackdrop(url: track.thumbnailUrl),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  child: Column(
                    children: [
                      _Header(
                        onMore: () => _showTrackMenu(context, ref, track),
                        videoMode: ref.watch(videoModeProvider),
                        onToggleVideo: () async {
                          final handler = ref.read(audioHandlerProvider);
                          final newMode = !ref.read(videoModeProvider);
                          if (newMode) {
                            // Entering video mode — pause audio cleanly.
                            await handler.pause();
                          } else {
                            // Leaving video mode. The VideoView's
                            // dispose() reports the last YouTube
                            // position back through onPositionChange,
                            // which we use to seek the audio handler.
                            // The lastVideoPosition state is set
                            // from there.
                            final pos = ref.read(_lastVideoPositionProvider);
                            if (pos > Duration.zero) {
                              await handler.seek(pos);
                            }
                            await handler.play();
                          }
                          ref.read(videoModeProvider.notifier).state = newMode;
                          PipService.instance.setVideoMode(newMode);
                        },
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: Center(
                          child: ref.watch(videoModeProvider)
                              ? VideoView(
                                  key: ValueKey(track.sourceVideoId),
                                  videoId: track.sourceVideoId,
                                  startAt: progressAsync.valueOrNull?.position ??
                                      Duration.zero,
                                  onPositionChange: (p) {
                                    ref.read(_lastVideoPositionProvider.notifier).state = p;
                                  },
                                )
                              : AspectRatio(
                                  aspectRatio: 1,
                                  child: _Artwork(url: track.thumbnailUrl),
                                ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _TitleBlock(track: track),
                      const SizedBox(height: 16),
                      _Scrubber(
                        progress: progressAsync.valueOrNull,
                        onSeek: (p) => ref.read(audioHandlerProvider).seek(p),
                      ),
                      const SizedBox(height: 8),
                      _Transport(
                        playing: progressAsync.valueOrNull?.playing ?? false,
                        handler: ref.read(audioHandlerProvider),
                      ),
                      const SizedBox(height: 8),
                      const _ExtrasRow(),
                      const SizedBox(height: 8),
                      const _UpNextPeek(),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showTrackMenu(BuildContext context, WidgetRef ref, Track track) {
    final library = ref.read(libraryProvider);
    final isFav = library.isFavorite(track.id);

    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(isFav ? Icons.favorite : Icons.favorite_border),
              title: Text(isFav ? 'Remove from favorites' : 'Add to favorites'),
              onTap: () async {
                await library.toggleFavorite(track);
                if (context.mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Add to queue'),
              onTap: () async {
                await ref.read(audioHandlerProvider).addQueueItem(track.toMediaItem());
                if (context.mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_play),
              title: const Text('Play next'),
              onTap: () async {
                await ref.read(audioHandlerProvider).playNext(track);
                if (context.mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.radio),
              title: const Text('Start radio from this track'),
              subtitle: const Text('Endless queue of related songs'),
              onTap: () async {
                await ref.read(audioHandlerProvider).startRadio(track);
                if (context.mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Share'),
              onTap: () async {
                Navigator.pop(context);
                final url = 'https://youtu.be/${track.sourceVideoId}';
                final body =
                    '🎵 Listen to "${track.title}" by ${track.artist}\n\nOn MewSify  •  $url';
                await SharePlus.instance.share(
                  ShareParams(
                    text: body,
                    subject: '${track.title} — ${track.artist}',
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Spotify-style gradient backdrop. The dominant color is extracted
/// from the album art and used as the top of a gradient that fades to
/// near-black at the bottom, giving the player a colorful but readable
/// surface that recolors with every track.
class _BlurredBackdrop extends StatelessWidget {
  final String url;
  const _BlurredBackdrop({required this.url});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MelodyPalette>(
      future: PaletteService.instance.getPalette(url),
      builder: (context, snap) {
        final palette = snap.data;
        final base = Theme.of(context).colorScheme.surface;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.5, 1.0],
              colors: [
                palette?.primary ?? base,
                Color.lerp(palette?.secondary ?? base, base, 0.4) ?? base,
                base,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onMore;
  final bool videoMode;
  final VoidCallback onToggleVideo;
  const _Header({
    required this.onMore,
    required this.videoMode,
    required this.onToggleVideo,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.expand_more),
          onPressed: () => Navigator.pop(context),
        ),
        const Spacer(),
        const Text(
          'NOW PLAYING',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4),
        ),
        const Spacer(),
        // Video / photo mode toggle, like YMusic
        IconButton(
          tooltip: videoMode ? 'Switch to audio mode' : 'Switch to video mode',
          icon: Icon(
            videoMode ? Icons.audiotrack_rounded : Icons.smart_display_outlined,
            color: videoMode ? scheme.primary : null,
          ),
          onPressed: onToggleVideo,
        ),
        IconButton(icon: const Icon(Icons.more_horiz), onPressed: onMore),
      ],
    );
  }
}

/// Now Playing artwork with horizontal swipe-to-skip support and a
/// Hero tag for the smooth transition from the mini player.
class _Artwork extends ConsumerWidget {
  final String url;
  const _Artwork({required this.url});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(audioHandlerProvider);
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v < -250) {
          handler.skipToNext();
        } else if (v > 250) {
          handler.skipToPrevious();
        }
      },
      child: Hero(
        tag: 'now-playing-art',
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: TrackArtwork(
              url: url,
              highRes: true,
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleBlock extends ConsumerWidget {
  final Track track;
  const _TitleBlock({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    return ValueListenableBuilder(
      valueListenable: Hive.box<Track>('favorites').listenable(),
      builder: (context, _, __) {
        final isFav = library.isFavorite(track.id);
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              iconSize: 28,
              icon: Icon(
                isFav ? Icons.favorite : Icons.favorite_border,
                color: isFav ? Theme.of(context).colorScheme.primary : null,
              ),
              onPressed: () => library.toggleFavorite(track),
            ),
          ],
        );
      },
    );
  }
}

class _Scrubber extends ConsumerStatefulWidget {
  final ProgressData? progress;
  final ValueChanged<Duration> onSeek;
  const _Scrubber({required this.progress, required this.onSeek});

  @override
  ConsumerState<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends ConsumerState<_Scrubber> {
  /// Local position used while the user is actively dragging — the
  /// real player won't have caught up yet, so without this the thumb
  /// would snap back during the drag.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    // In video mode the YouTube embed handles its own scrubber and
    // quality picker, so we hide ours to avoid confusion.
    final videoMode = ref.watch(videoModeProvider);
    if (videoMode) return const SizedBox(height: 24);

    final pos = widget.progress?.position ?? Duration.zero;
    final dur = widget.progress?.duration ?? Duration.zero;
    return _build(pos: pos, dur: dur, onSeek: widget.onSeek);
  }

  Widget _build({
    required Duration pos,
    required Duration dur,
    required ValueChanged<Duration> onSeek,
  }) {
    final actualValue = dur.inMilliseconds == 0
        ? 0.0
        : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    final value = _dragValue ?? actualValue;
    final displayPos = _dragValue == null
        ? pos
        : Duration(milliseconds: (_dragValue! * dur.inMilliseconds).round());

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: value,
            onChanged: (v) => setState(() => _dragValue = v),
            onChangeEnd: (v) {
              final target = Duration(milliseconds: (v * dur.inMilliseconds).round());
              onSeek(target);
              // Hold the drag value briefly so the thumb doesn't snap
              // back before the player reports the new position.
              Future.delayed(const Duration(milliseconds: 250), () {
                if (mounted) setState(() => _dragValue = null);
              });
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmt(displayPos), style: const TextStyle(fontSize: 12)),
              Text(_fmt(dur), style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _Transport extends ConsumerStatefulWidget {
  final bool playing;
  final MelodyAudioHandler handler;
  const _Transport({required this.playing, required this.handler});

  @override
  ConsumerState<_Transport> createState() => _TransportState();
}

class _TransportState extends ConsumerState<_Transport>
    with SingleTickerProviderStateMixin {
  late final AnimationController _playAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: widget.playing ? 1.0 : 0.0,
  );

  @override
  void didUpdateWidget(covariant _Transport old) {
    super.didUpdateWidget(old);
    if (widget.playing != old.playing) {
      widget.playing ? _playAnim.forward() : _playAnim.reverse();
    }
  }

  @override
  void dispose() {
    _playAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shuffle = ref.watch(shuffleModeProvider).valueOrNull ?? false;
    final repeat = ref.watch(repeatModeProvider).valueOrNull ?? PlaybackRepeat.off;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          iconSize: 24,
          color: shuffle ? scheme.primary : null,
          icon: const Icon(Icons.shuffle),
          onPressed: widget.handler.toggleShuffle,
        ),
        IconButton(
          iconSize: 36,
          icon: const Icon(Icons.skip_previous),
          onPressed: widget.handler.skipToPrevious,
        ),
        Container(
          decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
          padding: const EdgeInsets.all(10),
          child: IconButton(
            iconSize: 38,
            color: scheme.onPrimary,
            icon: AnimatedIcon(
              icon: AnimatedIcons.play_pause,
              progress: _playAnim,
            ),
            onPressed: () {
              widget.playing ? widget.handler.pause() : widget.handler.play();
            },
          ),
        ),
        IconButton(
          iconSize: 36,
          icon: const Icon(Icons.skip_next),
          onPressed: widget.handler.skipToNext,
        ),
        IconButton(
          iconSize: 24,
          color: repeat == PlaybackRepeat.off ? null : scheme.primary,
          icon: Icon(_repeatIcon(repeat)),
          onPressed: widget.handler.cycleRepeat,
        ),
      ],
    );
  }

  IconData _repeatIcon(PlaybackRepeat m) {
    switch (m) {
      case PlaybackRepeat.off:
      case PlaybackRepeat.all:
        return Icons.repeat;
      case PlaybackRepeat.one:
        return Icons.repeat_one;
    }
  }
}

class _ExtrasRow extends ConsumerWidget {
  const _ExtrasRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final timer = ref.watch(sleepTimerProvider).valueOrNull;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _ExtraButton(
          icon: Icons.timer_outlined,
          label: timer != null ? 'On' : 'Sleep',
          active: timer != null,
          onTap: () => showModalBottomSheet(
            context: context,
            builder: (_) => const SleepTimerSheet(),
          ),
        ),

        _ExtraButton(
          icon: Icons.queue_music_outlined,
          label: 'Queue',
          onTap: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: scheme.surface,
            builder: (_) => const QueueSheet(),
          ),
        ),
      ],
    );
  }
}

class _ExtraButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ExtraButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? Theme.of(context).colorScheme.primary : null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}


/// "Up next" preview row at the bottom of the Now Playing screen.
/// Shows the next 3 tracks in the queue with the artwork + title;
/// tapping a card jumps to that track, tapping the header opens the
/// full queue sheet.
class _UpNextPeek extends ConsumerWidget {
  const _UpNextPeek();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.watch(audioHandlerProvider);
    final queue = handler.currentQueue;
    final current = handler.currentIndex;
    if (queue.isEmpty || current + 1 >= queue.length) {
      return const SizedBox.shrink();
    }
    final upNext = queue.skip(current + 1).take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Theme.of(context).colorScheme.surface,
            builder: (_) => const QueueSheet(),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                const Text(
                  'UP NEXT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '· ${queue.length - current - 1}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const Spacer(),
                Icon(
                  Icons.expand_less,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: 56,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: upNext.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final track = upNext[i];
              return GestureDetector(
                onTap: () => handler.skipToQueueItem(current + 1 + i),
                child: Container(
                  width: 220,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CachedNetworkImage(
                          imageUrl: track.thumbnailUrl,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            width: 44,
                            height: 44,
                            color: Colors.black26,
                            child: const Icon(Icons.music_note, size: 20),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                              ),
                            ),
                          ],
                        ),
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
  }
}
