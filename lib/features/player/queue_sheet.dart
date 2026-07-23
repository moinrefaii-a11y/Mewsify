import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../widgets/eq_indicator.dart';
import '../../widgets/track_artwork.dart';

/// Spotify-style queue sheet:
///   • "Now playing" section pinned at the top (not draggable)
///   • "Next in queue" section below, drag-to-reorder + swipe/remove
/// Tapping any row jumps to that track.
class QueueSheet extends ConsumerStatefulWidget {
  const QueueSheet({super.key});

  @override
  ConsumerState<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<QueueSheet> {
  @override
  Widget build(BuildContext context) {
    final handler = ref.read(audioHandlerProvider);
    final tracks = handler.currentQueue;
    final current = handler.currentIndex;
    final scheme = Theme.of(context).colorScheme;

    final upNext = <int>[];
    for (var i = current + 1; i < tracks.length; i++) {
      upNext.add(i);
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Queue',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              ),
            ),
            Expanded(
              child: CustomScrollView(
                controller: scrollController,
                slivers: [
                  // --- Now playing ---
                  if (current >= 0 && current < tracks.length) ...[
                    const _SectionLabel('Now playing'),
                    SliverToBoxAdapter(
                      child: _QueueRow(
                        title: tracks[current].title,
                        artist: tracks[current].artist,
                        thumb: tracks[current].thumbnailUrl,
                        highlight: true,
                        trailing: EqIndicator(size: 22, color: scheme.primary),
                        onTap: () {},
                      ),
                    ),
                  ],
                  // --- Next in queue (reorderable) ---
                  if (upNext.isNotEmpty) ...[
                    const _SectionLabel('Next in queue'),
                    SliverReorderableList(
                      itemCount: upNext.length,
                      onReorder: (oldI, newI) async {
                        // Map local indices back to absolute queue indices.
                        final from = upNext[oldI];
                        var toLocal = newI;
                        if (newI > oldI) toLocal -= 1;
                        final to = upNext[toLocal];
                        await handler.moveQueueItem(from, to);
                        setState(() {});
                      },
                      itemBuilder: (context, i) {
                        final qi = upNext[i];
                        final t = tracks[qi];
                        return _QueueRow(
                          key: ValueKey('q_${t.id}_$qi'),
                          title: t.title,
                          artist: t.artist,
                          thumb: t.thumbnailUrl,
                          reorderIndex: i,
                          onTap: () {
                            handler.skipToQueueItem(qi);
                            Navigator.of(context).pop();
                          },
                          onRemove: () async {
                            await handler.removeQueueItemAt(qi);
                            setState(() {});
                          },
                        );
                      },
                    ),
                  ],
                  if (upNext.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                            'Nothing up next yet',
                            style: TextStyle(
                              color:
                                  scheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final String title;
  final String artist;
  final String thumb;
  final bool highlight;
  final Widget? trailing;
  final int? reorderIndex;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _QueueRow({
    super.key,
    required this.title,
    required this.artist,
    required this.thumb,
    required this.onTap,
    this.highlight = false,
    this.trailing,
    this.reorderIndex,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            TrackArtwork(
              url: thumb,
              width: 48,
              height: 48,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: highlight ? scheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
            if (onRemove != null)
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onRemove,
              ),
            if (reorderIndex != null)
              ReorderableDragStartListener(
                index: reorderIndex!,
                child: Icon(
                  Icons.drag_handle_rounded,
                  color: scheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
