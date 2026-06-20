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

  static final List<Widget> _pages = kIsWeb
      ? const [
          HomeScreen(),
          SearchScreen(),
          LibraryScreen(),
          ProfileScreen(),
        ]
      : const [
          HomeScreen(),
          SearchScreen(),
          BrowserScreen(),
          LibraryScreen(),
          ProfileScreen(),
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
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: _destinations,
          ),
        ],
      ),
    );
  }
}
