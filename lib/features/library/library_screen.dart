import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/providers.dart';
import '../../data/models/track.dart';
import '../../widgets/track_actions_sheet.dart';
import '../../widgets/track_tile.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

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
                  child: Text('Library',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
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
              Tab(text: 'History'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                ValueListenableBuilder(
                  valueListenable: Hive.box<Track>('favorites').listenable(),
                  builder: (_, __, ___) => _list(
                    library.favorites,
                    emptyMessage: 'Tap the heart on a track to favorite it.',
                  ),
                ),
                ValueListenableBuilder(
                  valueListenable: Hive.box<Track>('history').listenable(),
                  builder: (_, __, ___) => _list(
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

  Widget _list(List<Track> tracks, {required String emptyMessage}) {
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
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
