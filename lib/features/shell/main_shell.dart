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

class _MainShellState extends ConsumerState<MainShell> {
  int _index = 0;

  // Track which tabs have been visited to defer building until first visit.
  final Set<int> _visited = {0};

  bool _updateChecked = false;

  void _maybeShowUpdate() {
    if (_updateChecked) return;
    _updateChecked = true;
    // Kick off in the next frame so the initial build finishes first.
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

    // Show playback errors as a snackbar so the user knows why audio
    // isn't progressing instead of staring at a silent paused player.
    ref.listen(playerErrorProvider, (_, next) {
      final msg = next.valueOrNull;
      if (msg == null) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
        );
    });

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
          const MiniPlayer(),
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
