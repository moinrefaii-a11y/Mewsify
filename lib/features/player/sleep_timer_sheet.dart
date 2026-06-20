import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Bottom sheet with sleep-timer presets. Tapping a preset arms a Timer
/// in MelodyAudioHandler that pauses playback when fired.
class SleepTimerSheet extends ConsumerWidget {
  const SleepTimerSheet({super.key});

  static const _presets = [
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(hours: 1),
    Duration(hours: 2),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(audioHandlerProvider);
    final active = ref.watch(sleepTimerProvider).valueOrNull;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Sleep timer',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Pause playback after a set time.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            ),
            ..._presets.map((d) {
              final selected = active == d;
              return ListTile(
                leading: Icon(selected ? Icons.timer : Icons.timer_outlined,
                    color: selected ? Theme.of(context).colorScheme.primary : null),
                title: Text(_label(d)),
                trailing: selected
                    ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () async {
                  await handler.setSleepTimer(d);
                  if (context.mounted) Navigator.pop(context);
                },
              );
            }),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.timer_off_outlined),
              title: const Text('Turn off'),
              enabled: active != null,
              onTap: () async {
                await handler.setSleepTimer(null);
                if (context.mounted) Navigator.pop(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _label(Duration d) {
    if (d.inHours > 0) {
      final mins = d.inMinutes - d.inHours * 60;
      return mins == 0 ? '${d.inHours} hour${d.inHours > 1 ? "s" : ""}' : '${d.inHours}h ${mins}m';
    }
    return '${d.inMinutes} minutes';
  }
}
