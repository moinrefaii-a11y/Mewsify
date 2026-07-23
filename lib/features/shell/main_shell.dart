import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../profile/profile_screen.dart';
import '../search/search_screen.dart';
import '../../core/providers.dart';
import '../../widgets/mini_player.dart';

import '../browser/browser_screen.dart';
import '../update/update_sheet.dart';

/// Top-level scaffold: tabs + persistent mini player above the
/// navigation bar. Tapping the mini player opens the full Now Playing
/// screen (handled inside MiniPlayer).
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver {
  int _index = 0;
  // Which tab index is the Browse tab? Depends on the platform because
  // web builds don't include Browse.
  static const int _browseTabIndex = 2;

  // Track which tabs have been visited to defer building until first visit.
  final Set<int> _visited = {0};

  bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Backgrounding while a YouTube watch page is loaded in the Browse
  /// tab kills the WebView's audio (that's a Chromium constraint we
  /// can't override). To make the "browser video keeps playing in
  /// background" behaviour work anyway, we hoist the currently visible
  /// video into MewSify's own native audio pipeline the moment the app
  /// goes inactive.
  /// Track the last videoId we hoisted so we don't re-fire on every
  /// tiny lifecycle transition (Android emits inactive→paused→inactive
  /// repeatedly on some devices).
  String? _lastHoistedId;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) return;
    // Fire on `inactive` — a hair earlier than `paused` — so audio
    // never gaps as the WebView loses its surface. On Android `inactive`
    // fires ~150 ms before `paused`.
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused) {
      // Coming back to the foreground: allow future hoists again.
      if (state == AppLifecycleState.resumed) _lastHoistedId = null;
      return;
    }
    if (_index != _browseTabIndex) return;
    final urlStr = ref.read(browserCurrentUrlProvider);
    if (urlStr == null || urlStr.isEmpty) return;
    Uri uri;
    try {
      uri = Uri.parse(urlStr);
    } catch (_) {
      return;
    }
    final id = _extractVideoId(uri);
    if (id == null) return;
    if (_lastHoistedId == id) return; // already hoisted this session
    _lastHoistedId = id;
    _hoistToNative(id);
  }

  Future<void> _hoistToNative(String videoId) async {
    final currentTrack = ref.read(currentTrackProvider).valueOrNull;
    if (currentTrack != null && currentTrack.sourceVideoId == videoId) return;
    try {
      final yt = ref.read(youtubeSourceProvider);
      // Kick the audio URL cache immediately (it's likely already warm
      // from the browser's prewarm call, but harmless if not).
      yt.prewarmAudioUrl(videoId);
      final track = await yt.getTrack(videoId);
      await ref.read(audioHandlerProvider).playWithAutoplay(track);
      await ref.read(libraryProvider).recordPlay(track);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Continuing "${track.title}" in background'),
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    } catch (e) {
      debugPrint('[BackgroundHoist] failed: $e');
    }
  }

  String? _extractVideoId(Uri uri) {
    if (uri.host.contains('youtube.com')) {
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
      final segs = uri.pathSegments;
      final shortsIdx = segs.indexOf('shorts');
      if (shortsIdx != -1 && shortsIdx + 1 < segs.length) {
        return segs[shortsIdx + 1];
      }
    } else if (uri.host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.first;
    }
    return null;
  }

  void _maybeShowUpdate() {
    if (_updateChecked) return;
    _updateChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(updateCheckProvider, (_, next) {
        final info = next.valueOrNull;
        if (info == null) return;
        if (UpdateSheet.isDismissed(info.version)) return;
        if (mounted) UpdateSheet.show(context, info);
      }, fireImmediately: true);
    });
  }

  static final List<Widget Function()> _pageBuilders = kIsWeb
      ? [
          () => const HomeScreen(),
          () => const SearchScreen(),
          () => const LibraryScreen(),
          () => const ProfileScreen(),
        ]
      : [
          () => const HomeScreen(),
          () => const SearchScreen(),
          () => const BrowserScreen(),
          () => const LibraryScreen(),
          () => const ProfileScreen(),
        ];

  static final List<NavigationDestination> _destinations = kIsWeb
      ? const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search_outlined), selectedIcon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Library'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'You'),
        ]
      : const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search_outlined), selectedIcon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.public_outlined), selectedIcon: Icon(Icons.public), label: 'Browse'),
          NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Library'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'You'),
        ];

  @override
  Widget build(BuildContext context) {
    _maybeShowUpdate();

    // Surface playback errors as snackbars.
    ref.listen(playerErrorProvider, (_, next) {
      final msg = next.valueOrNull;
      if (msg == null) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
        );
    });

    // Hide the mini player on the Browse tab so it doesn't sit on top
    // of the YouTube UI (the browser tab has its own top-bar controls).
    final showMiniPlayer = kIsWeb || _index != _browseTabIndex;

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: List.generate(_pageBuilders.length, (i) {
          if (_visited.contains(i)) return _pageBuilders[i]();
          return const SizedBox.shrink();
        }),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showMiniPlayer) const MiniPlayer(),
          NavigationBar(
            animationDuration: const Duration(milliseconds: 400),
            selectedIndex: _index,
            onDestinationSelected: (i) {
              _visited.add(i);
              setState(() => _index = i);
            },
            destinations: _destinations,
          ),
        ],
      ),
    );
  }
}
