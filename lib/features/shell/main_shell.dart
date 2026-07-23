import 'dart:async';

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
  double _hoistedFromSeconds = 0.0;

  /// Track the videoId we've pre-warmed on the native audio pipeline
  /// so we don't re-warm on every browser URL change or rebuild.
  String? _warmedForVideoId;

  /// Pre-warm the native audio pipeline for the /watch page the
  /// browser is currently on. Runs while the app is still in the
  /// foreground so all the async setup (URL resolution, setAudioSource,
  /// MediaSession registration) is done under normal foreground rules.
  /// When the user then backgrounds the app, `resumeWarmedHoist` is
  /// synchronous and doesn't run afoul of Android 14's
  /// foreground-service-from-background restrictions.
  Future<void> _maybeWarmForBrowse(String? urlStr) async {
    if (urlStr == null || urlStr.isEmpty) return;
    Uri uri;
    try {
      uri = Uri.parse(urlStr);
    } catch (_) {
      return;
    }
    final id = _extractVideoId(uri);
    if (id == null) return;
    if (_warmedForVideoId == id) return;
    // Never warm if the user has active native playback of a DIFFERENT
    // track — we'd trample their session.
    final currentTrack = ref.read(currentTrackProvider).valueOrNull;
    if (currentTrack != null &&
        currentTrack.sourceVideoId != id &&
        ref.read(audioHandlerProvider).rawPlayer.playing) {
      return;
    }
    _warmedForVideoId = id;
    try {
      final yt = ref.read(youtubeSourceProvider);
      final track = await yt.getTrack(id);
      await ref.read(audioHandlerProvider).prepareForBackgroundHoist(track);
      await ref.read(libraryProvider).recordPlay(track);
    } catch (e) {
      debugPrint('[Shell] warm failed: $e');
      _warmedForVideoId = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) return;
    if (state == AppLifecycleState.resumed) {
      _maybeReturnToBrowse();
      return;
    }
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused) {
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
    if (_lastHoistedId == id) return;
    _lastHoistedId = id;
    _hoistedFromSeconds = ref.read(browserVideoPositionProvider);
    _resumeHoist(id, _hoistedFromSeconds);
  }

  /// Fast path executed on app-going-background: assume the pipeline is
  /// pre-warmed (see [_maybeWarmForBrowse]) and just flip to playing
  /// at the correct position. Falls back to a full [playWithAutoplay]
  /// only if the warm didn't happen (edge cases: user opens app for
  /// the first time then immediately backgrounds).
  Future<void> _resumeHoist(String videoId, double fromSeconds) async {
    final handler = ref.read(audioHandlerProvider);
    final startAt = Duration(milliseconds: (fromSeconds * 1000).round());
    try {
      if (_warmedForVideoId == videoId) {
        // Fast path: just play the pre-warmed source.
        await handler.resumeWarmedHoist(startAt: startAt);
      } else {
        // Slow path: user backgrounded before we finished warming.
        final yt = ref.read(youtubeSourceProvider);
        final track = await yt.getTrack(videoId);
        await handler.playWithAutoplay(track);
        if (startAt > Duration.zero) await handler.seek(startAt);
        await ref.read(libraryProvider).recordPlay(track);
      }
      if (mounted) {
        final title = handler.currentTrack?.title ?? 'this video';
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Playing "$title" in background'),
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    } catch (e) {
      debugPrint('[Hoist] resume failed: $e');
    }
  }

  /// Called on resume. If we hoisted a WebView video into native audio
  /// while the app was away and the user came back to the Browse tab,
  /// hand playback back to the WebView so their visual experience is
  /// uninterrupted. We seek the WebView video to native audio's
  /// current second, tell it to play, then pause native audio.
  Future<void> _maybeReturnToBrowse() async {
    final hoistedId = _lastHoistedId;
    _lastHoistedId = null; // allow another hoist next background
    if (hoistedId == null) return;
    if (_index != _browseTabIndex) return;
    final handler = ref.read(audioHandlerProvider);
    final current = handler.currentTrack;
    if (current == null || current.sourceVideoId != hoistedId) return;

    // Where should the video jump back to? Take native audio's live
    // position; that's the exact moment the user is hearing right now.
    final resumeSec =
        handler.rawPlayer.position.inMilliseconds / 1000.0;

    // Fire the JS but don't block on it — we want the pause + snackbar
    // to happen even if the browser is slow to respond.
    unawaited(_seekBrowserVideoAndPlay(resumeSec));

    // Small delay so the WebView has a beat to start decoding before
    // we cut native audio — avoids an audible gap.
    await Future.delayed(const Duration(milliseconds: 300));
    try {
      await handler.pause();
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Resumed video in Browse'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  Future<void> _seekBrowserVideoAndPlay(double seconds) async {
    // We can't reach into BrowserScreen's InAppWebViewController from
    // here — the shell isn't the WebView owner. Publish the desired
    // resume position via a provider; BrowserScreen listens and does
    // the JS eval on its next frame.
    ref.read(browserResumeSecondsProvider.notifier).state = seconds;
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

    // Pre-warm the native audio pipeline whenever the Browser tab
    // lands on a new /watch page. This means backgrounding the app
    // triggers a synchronous `play()` instead of a slow async
    // resolve → set-source → play chain that Android 14+ can block
    // from a paused-app state.
    ref.listen<String?>(browserCurrentUrlProvider, (_, next) {
      _maybeWarmForBrowse(next);
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
