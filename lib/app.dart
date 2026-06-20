import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/shell/main_shell.dart';
import 'features/splash/splash_overlay.dart';

class MelodyApp extends ConsumerWidget {
  const MelodyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final seed = Color(ref.watch(themeSeedProvider));
    return MaterialApp(
      title: 'MewSify',
      debugShowCheckedModeBanner: false,
      theme: MelodyTheme.light(seed),
      darkTheme: MelodyTheme.dark(seed),
      themeMode: mode,
      home: const SplashOverlay(child: MainShell()),
    );
  }
}
