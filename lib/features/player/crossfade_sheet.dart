import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

/// Bottom sheet you can pop from the Now Playing extras row to change
/// crossfade duration + a couple of smart-mix toggles without leaving
/// the player. All settings persist in the Hive `settings` box so the
/// audio handler picks them up on the next transition.
class CrossfadeSheet extends StatefulWidget {
  const CrossfadeSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const CrossfadeSheet(),
    );
  }

  @override
  State<CrossfadeSheet> createState() => _CrossfadeSheetState();
}

class _CrossfadeSheetState extends State<CrossfadeSheet> {
  late int _seconds;
  late bool _auto;
  late bool _loudnessMatch;
  late bool _debug;

  Box get _box => Hive.box('settings');

  @override
  void initState() {
    super.initState();
    _seconds = _box.containsKey('crossfadeSeconds')
        ? (_box.get('crossfadeSeconds') as int).clamp(0, 12)
        : 5;
    _auto = _box.get('crossfadeAuto', defaultValue: false) as bool;
    _loudnessMatch =
        _box.get('crossfadeLoudnessMatch', defaultValue: true) as bool;
    _debug = _box.get('crossfadeDebug', defaultValue: false) as bool;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Crossfade',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            _seconds == 0
                ? 'Off — songs change with no overlap'
                : 'Songs blend for the last $_seconds seconds',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
          Row(
            children: [
              Text('0', style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.5))),
              Expanded(
                child: Slider(
                  value: _seconds.toDouble(),
                  min: 0,
                  max: 12,
                  divisions: 12,
                  label: _seconds == 0 ? 'Off' : '${_seconds}s',
                  onChanged: (v) {
                    setState(() => _seconds = v.round());
                    _box.put('crossfadeSeconds', _seconds);
                  },
                ),
              ),
              Text('12',
                  style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.5))),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto duration'),
            subtitle: Text(
              'Shorten the fade for short tracks (< 90 s) and lengthen it for long ones. '
              'Uses the slider above as the max.',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
            value: _auto,
            onChanged: (v) {
              setState(() => _auto = v);
              _box.put('crossfadeAuto', v);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Match loudness'),
            subtitle: Text(
              'Even out volume differences between quiet and loud tracks '
              'so the mix stays smooth.',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
            value: _loudnessMatch,
            onChanged: (v) {
              setState(() => _loudnessMatch = v);
              _box.put('crossfadeLoudnessMatch', v);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show fade events (debug)'),
            subtitle: Text(
              'Snackbar messages when the fade preloads, fires, and '
              'completes. Use to verify the fade is actually kicking in.',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
            value: _debug,
            onChanged: (v) {
              setState(() => _debug = v);
              _box.put('crossfadeDebug', v);
            },
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.info_outline,
                  size: 14,
                  color: scheme.onSurface.withValues(alpha: 0.5)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'BPM detection + beat-aligned mixing would need heavy '
                  'audio analysis on the device. Not enabled for streaming.',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.5),
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
