import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../core/providers.dart';
import '../../data/models/track.dart';
import '../../data/sources/piped_source.dart';
import '../../data/sources/youtube_source.dart';
import '../../widgets/track_actions_sheet.dart';
import '../../widgets/track_tile.dart';
import '../artist/artist_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  /// Cache of results keyed by category so switching tabs is instant
  /// once we've fetched at least once.
  final Map<SearchCategory, List<Track>> _resultsByCategory = {};

  // --- Voice search state ----------------------------------------------
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _voiceReady = false;
  bool _listening = false;

  late final TabController _tabs = TabController(length: 4, vsync: this)
    ..addListener(_onTabChanged);

  /// Tab order matches Spotify / YouTube: All first, then specific filters.
  static const _tabCategories = [
    SearchCategory.all,
    SearchCategory.songs,
    SearchCategory.videos,
    SearchCategory.artists,
  ];

  static const _suggestions = [
    'Top hits 2026',
    'Lo-fi beats',
    'Bollywood new',
    'Acoustic covers',
    'Workout playlist',
    'Hindi songs',
    'Tamil hits',
    'Punjabi music',
  ];

  Box<String> get _recentSearches =>
      Hive.box<String>('recent_searches');

  List<String> _recentList() {
    final raw = _recentSearches.values.toList();
    return raw.reversed.take(10).toList();
  }

  Future<void> _saveRecent(String q) async {
    final query = q.trim();
    if (query.isEmpty) return;
    final box = _recentSearches;
    // De-dupe: remove any existing match before pushing the new one to
    // the end so "most recently used" is always at the top.
    final keysToDelete = box.toMap().entries
        .where((e) => e.value.toLowerCase() == query.toLowerCase())
        .map((e) => e.key)
        .toList();
    for (final k in keysToDelete) {
      await box.delete(k);
    }
    await box.add(query);
    // Cap at 25 entries.
    while (box.length > 25) {
      await box.deleteAt(0);
    }
  }

  Future<void> _clearRecents() async {
    await _recentSearches.clear();
    setState(() {});
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    final category = _tabCategories[_tabs.index];
    if (_resultsByCategory[category] == null) {
      _runSearch(query);
    } else {
      setState(() {});
    }
  }

  void _onChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      _resultsByCategory.clear();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _runSearch(value));
  }

  Future<void> _runSearch(String query) async {
    final parsed = YouTubeSource.parseUrl(query);
    if (parsed != null) {
      await _import(parsed.$1, parsed.$2);
      return;
    }

    final category = _tabCategories[_tabs.index];
    ref.read(searchLoadingProvider.notifier).state = true;
    try {
      final results = await ref
          .read(youtubeSourceProvider)
          .search(query, category: category);
      _resultsByCategory[category] = results;
      if (results.isNotEmpty) await _saveRecent(query);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: $e')),
        );
      }
    } finally {
      ref.read(searchLoadingProvider.notifier).state = false;
    }
  }

  Future<void> _import(String kind, String id) async {
    ref.read(searchLoadingProvider.notifier).state = true;
    try {
      final yt = ref.read(youtubeSourceProvider);
      if (kind == 'playlist') {
        final tracks = await yt.playlistTracks(id);
        if (tracks.isEmpty) throw 'Playlist is empty or unavailable';
        await ref.read(audioHandlerProvider).setQueue(tracks);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Loaded ${tracks.length} tracks from playlist')),
          );
        }
        _resultsByCategory[SearchCategory.songs] = tracks;
        if (mounted) setState(() {});
      } else {
        final track = await yt.getTrack(id);
        await ref.read(audioHandlerProvider).playWithAutoplay(track);
        await ref.read(libraryProvider).recordPlay(track);
        _resultsByCategory[SearchCategory.songs] = [track];
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    } finally {
      ref.read(searchLoadingProvider.notifier).state = false;
    }
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    if (!_voiceReady) {
      _voiceReady = await _speech.initialize(
        onError: (e) {
          debugPrint('[Voice] init error: ${e.errorMsg}');
          if (mounted) setState(() => _listening = false);
        },
        onStatus: (status) {
          if (status == 'notListening' || status == 'done') {
            if (mounted) setState(() => _listening = false);
          }
        },
      );
      if (!_voiceReady) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission needed for voice search')),
          );
        }
        return;
      }
    }
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (result) {
        _controller.text = result.recognizedWords;
        _onChanged(result.recognizedWords);
        if (result.finalResult) {
          _runSearch(result.recognizedWords);
        }
      },
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 2),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.trim().isEmpty) return;
    _controller.text = text;
    _onChanged(text);
    await _runSearch(text);
  }

  void _runSuggestion(String s) {
    _controller.text = s;
    _focusNode.unfocus();
    _onChanged(s);
    _runSearch(s);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loading = ref.watch(searchLoadingProvider);
    final hasQuery = _controller.text.trim().isNotEmpty;

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: _onChanged,
              onSubmitted: _runSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search or paste a YouTube link',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _listening ? 'Stop listening' : 'Voice search',
                      icon: Icon(
                        _listening ? Icons.mic : Icons.mic_none_outlined,
                        color: _listening
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      onPressed: _toggleListening,
                    ),
                    IconButton(
                      tooltip: 'Paste link',
                      icon: const Icon(Icons.content_paste_outlined),
                      onPressed: _pasteFromClipboard,
                    ),
                    if (hasQuery)
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _controller.clear();
                          _onChanged('');
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (hasQuery)
            TabBar(
              controller: _tabs,
              isScrollable: true,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700),
              tabAlignment: TabAlignment.start,
              tabs: const [
                Tab(text: 'All'),
                Tab(text: 'Songs'),
                Tab(text: 'Videos'),
                Tab(text: 'Artists'),
              ],
            ),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: hasQuery
                ? TabBarView(
                    controller: _tabs,
                    children: _tabCategories.map(_resultsList).toList(),
                  )
                : _suggestionsList(),
          ),
        ],
      ),
    );
  }

  Widget _resultsList(SearchCategory cat) {
    final results = _resultsByCategory[cat] ?? const [];
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;
    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            cat == SearchCategory.all
              ? 'No results'
              : 'No ${cat.name} found',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }

    if (cat == SearchCategory.artists) {
      return _ArtistsGrid(artists: results);
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: results.length,
      itemBuilder: (_, i) {
        final t = results[i];
        // Channel result — tap opens the artist page instead of playing.
        if (t.id.startsWith('ytch:')) {
          return _ChannelTile(
            channel: t,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ArtistScreen(
                artistName: t.title,
                seedThumbnail: t.thumbnailUrl,
                channelId: t.sourceVideoId, // encoded channel id
              ),
            )),
          );
        }
        return TrackTile(
          track: t,
          wide: true,
          isPlaying: currentTrack?.id == t.id,
          onTap: () {
            ref.read(audioHandlerProvider).playWithAutoplay(t);
            ref.read(libraryProvider).recordPlay(t);
          },
          onMore: () => TrackActionsSheet.show(context, t),
          onLongPress: () => TrackActionsSheet.show(context, t),
        );
      },
    );
  }

  Widget _suggestionsList() {
    return ValueListenableBuilder(
      valueListenable: _recentSearches.listenable(),
      builder: (_, __, ___) {
        final recents = _recentList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            if (recents.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8, top: 8),
                child: Row(
                  children: [
                    Text(
                      'RECENT SEARCHES',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _clearRecents,
                      child: const Text('Clear all'),
                    ),
                  ],
                ),
              ),
              for (final q in recents)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.history),
                  title: Text(q),
                  trailing: IconButton(
                    icon: const Icon(Icons.north_west, size: 18),
                    onPressed: () {
                      _controller.text = q;
                      _onChanged(q);
                    },
                  ),
                  onTap: () => _runSuggestion(q),
                ),
              const SizedBox(height: 16),
            ],
            Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 8),
              child: Text(
                'SUGGESTED',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _suggestions.map((s) {
                return ActionChip(
                  label: Text(s),
                  onPressed: () => _runSuggestion(s),
                );
              }).toList(),
            ),
          ],
        );
      },
    );
  }
}

/// Artist results render as a grid of round-thumbnail cards. If the
/// server returned real channel results (id prefix "ytch:") we render
/// those directly; otherwise we fall back to deduplicating the track
/// results by author name so the tab is never empty.
class _ArtistsGrid extends StatelessWidget {
  final List<Track> artists;
  const _ArtistsGrid({required this.artists});

  @override
  Widget build(BuildContext context) {
    final channels = artists.where((t) => t.id.startsWith('ytch:')).toList();
    final uniqueArtists = <Track>[];
    if (channels.isNotEmpty) {
      uniqueArtists.addAll(channels);
    } else {
      // Fall back to deduping the mixed-track results by author.
      final seen = <String>{};
      for (final t in artists) {
        if (seen.add(t.artist.toLowerCase())) uniqueArtists.add(t);
      }
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: uniqueArtists.length,
      itemBuilder: (context, i) {
        final t = uniqueArtists[i];
        // For channel entries the display name is the channel title;
        // for fallback dedup entries it's the track artist field.
        final isChannel = t.id.startsWith('ytch:');
        final displayName = isChannel ? t.title : t.artist;
        return GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArtistScreen(
              artistName: displayName,
              seedThumbnail: t.thumbnailUrl,
              channelId: isChannel ? t.sourceVideoId : null,
            ),
          )),
          child: Column(
            children: [
              ClipOval(
                child: Image.network(
                  t.thumbnailUrl,
                  width: 90,
                  height: 90,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 90,
                    height: 90,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.person, size: 40),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                displayName,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Row tile for a channel result inside the "All" search tab.
class _ChannelTile extends StatelessWidget {
  final Track channel;
  final VoidCallback onTap;
  const _ChannelTile({required this.channel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: ClipOval(
        child: Image.network(
          channel.thumbnailUrl,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 44,
            height: 44,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.person, size: 24),
          ),
        ),
      ),
      title: Text(
        channel.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        'Channel · ${channel.artist}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: const Icon(Icons.arrow_forward_ios, size: 14),
    );
  }
}
