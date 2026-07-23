import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hive_flutter/hive_flutter.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../player/sleep_timer_sheet.dart';

bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(sleepTimerProvider).valueOrNull;

    return SafeArea(
      child: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Text(
              'Settings',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5),
            ),
          ),

          // --- Appearance ---
          const _SectionLabel('Appearance'),
          _ThemeModeTile(),
          _AccentColorRow(),

          // --- Playback section ---
          const _SectionLabel('Playback'),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Sleep timer'),
            subtitle: Text(timer != null ? 'Active' : 'Off'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showModalBottomSheet(
              context: context,
              builder: (_) => const SleepTimerSheet(),
            ),
          ),
          _CrossfadeTile(),
          if (_isAndroid)
            ListTile(
              leading: const Icon(Icons.picture_in_picture_alt_outlined),
              title: const Text('Floating popup player'),
              subtitle: const Text('YMusic-style overlay over other apps'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final overlay = ref.read(overlayServiceProvider);
                if (!await overlay.hasPermission()) {
                  final granted = await overlay.requestPermission();
                  if (!granted) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Overlay permission denied')),
                      );
                    }
                    return;
                  }
                }
                await overlay.show();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Floating player enabled')),
                  );
                }
              },
            ),


          const Divider(),
          const _SectionLabel('Library'),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Clear listening history'),
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Clear history?'),
                  content: const Text('This removes all entries from your Recently Played list.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
                  ],
                ),
              );
              if (confirm == true) {
                await ref.read(libraryProvider).clearHistory();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('History cleared')),
                  );
                }
              }
            },
          ),

          const Divider(),
          const _SectionLabel('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('MewSify'),
            subtitle: Text('Cross-platform YouTube music streamer.\nLearning project demonstrating background\naudio + InnerTube extraction.'),
            isThreeLine: true,
          ),
          const ListTile(
            leading: Icon(Icons.code),
            title: Text('Built with'),
            subtitle: Text('Flutter, just_audio, audio_service, youtube_explode_dart, Riverpod, Hive'),
            isThreeLine: true,
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}


class _ThemeModeTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return ListTile(
      leading: const Icon(Icons.brightness_6_outlined),
      title: const Text('Theme'),
      subtitle: Text(_label(mode)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: ThemeMode.values.map((m) {
              return RadioListTile<ThemeMode>(
                title: Text(_label(m)),
                value: m,
                groupValue: mode,
                onChanged: (v) {
                  if (v != null) ref.read(themeModeProvider.notifier).set(v);
                  Navigator.pop(context);
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  String _label(ThemeMode m) {
    switch (m) {
      case ThemeMode.system:
        return 'Match system';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }
}

class _AccentColorRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(themeSeedProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Accent color',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: MelodyTheme.seedPalette.map((seed) {
              final isSelected = selected == seed.color.value;
              return GestureDetector(
                onTap: () => ref.read(themeSeedProvider.notifier).set(seed.color.value),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: seed.color,
                    shape: BoxShape.circle,
                    border: isSelected
                        ? Border.all(
                            color: Theme.of(context).colorScheme.onSurface,
                            width: 3,
                          )
                        : null,
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                    ],
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 22)
                      : null,
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}


/// Spotify-style crossfade slider 0..12 seconds.
class _CrossfadeTile extends StatefulWidget {
  @override
  State<_CrossfadeTile> createState() => _CrossfadeTileState();
}

class _CrossfadeTileState extends State<_CrossfadeTile> {
  late int _seconds;

  @override
  void initState() {
    super.initState();
    final box = Hive.box('settings');
    // Match the audio-handler default: 5 s if the user has never
    // touched the slider (the box has no entry yet).
    _seconds = box.containsKey('crossfadeSeconds')
        ? (box.get('crossfadeSeconds') as int).clamp(0, 12)
        : 5;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune_rounded),
              const SizedBox(width: 16),
              const Expanded(
                child: Text('Crossfade', style: TextStyle(fontSize: 16)),
              ),
              Text(
                _seconds == 0 ? 'Off' : '${_seconds}s',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Slider(
            value: _seconds.toDouble(),
            min: 0,
            max: 12,
            divisions: 12,
            label: _seconds == 0 ? 'Off' : '${_seconds}s',
            onChanged: (v) {
              setState(() => _seconds = v.round());
              Hive.box('settings').put('crossfadeSeconds', _seconds);
            },
          ),
        ],
      ),
    );
  }
}
