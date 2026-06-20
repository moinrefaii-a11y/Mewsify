import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../widgets/track_tile.dart';

/// "Up next" queue sheet. Reorder + remove are shown via an icon column;
/// tapping a row jumps to that track immediately.
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

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Up next',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: tracks.isEmpty
                  ? const Center(child: Text('Queue is empty'))
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: tracks.length,
                      itemBuilder: (_, i) {
                        final t = tracks[i];
                        final isCurrent = i == current;
                        return TrackTile(
                          track: t,
                          onTap: () => handler.skipToQueueItem(i),
                          trailing: isCurrent
                              ? Icon(Icons.equalizer,
                                  color: Theme.of(context).colorScheme.primary)
                              : IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () async {
                                    await handler.removeQueueItemAt(i);
                                    setState(() {});
                                  },
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
}
