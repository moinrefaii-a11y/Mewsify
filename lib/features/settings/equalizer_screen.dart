import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/providers.dart';

bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Android-only equalizer. Surfaces the system equalizer's bands as a
/// row of vertical sliders. On iOS we show a friendly placeholder
/// because just_audio doesn't expose equivalent effects there.
class EqualizerScreen extends ConsumerStatefulWidget {
  const EqualizerScreen({super.key});

  @override
  ConsumerState<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends ConsumerState<EqualizerScreen> {
  @override
  Widget build(BuildContext context) {
    if (!_isAndroid) return const _IosPlaceholder();
    final eq = ref.read(audioHandlerProvider).equalizer;
    final loudness = ref.read(audioHandlerProvider).loudnessEnhancer;

    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: FutureBuilder<AndroidEqualizerParameters>(
        future: eq.parameters,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final params = snapshot.data!;
          return SafeArea(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Equalizer'),
                  subtitle: const Text('Adjust frequency bands'),
                  value: eq.enabled,
                  onChanged: (v) async {
                    await eq.setEnabled(v);
                    setState(() {});
                  },
                ),
                const Divider(height: 1),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: params.bands.map((band) {
                        return _BandSlider(band: band, params: params);
                      }).toList(),
                    ),
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Loudness boost'),
                  subtitle: const Text('Increase output gain'),
                  value: loudness.enabled,
                  onChanged: (v) async {
                    await loudness.setEnabled(v);
                    setState(() {});
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: StreamBuilder<double>(
                    stream: loudness.targetGainStream,
                    builder: (context, snap) {
                      final gain = snap.data ?? 0.0;
                      return Row(
                        children: [
                          const Icon(Icons.volume_down),
                          Expanded(
                            child: Slider(
                              value: gain.clamp(0.0, 1.0),
                              onChanged: loudness.enabled
                                  ? (v) => loudness.setTargetGain(v)
                                  : null,
                            ),
                          ),
                          const Icon(Icons.volume_up),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BandSlider extends StatefulWidget {
  final AndroidEqualizerBand band;
  final AndroidEqualizerParameters params;
  const _BandSlider({required this.band, required this.params});

  @override
  State<_BandSlider> createState() => _BandSliderState();
}

class _BandSliderState extends State<_BandSlider> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: widget.band.gainStream,
      builder: (context, snap) {
        final gain = snap.data ?? widget.band.gain;
        return Column(
          children: [
            SizedBox(
              height: 200,
              child: RotatedBox(
                quarterTurns: -1,
                child: Slider(
                  min: widget.params.minDecibels,
                  max: widget.params.maxDecibels,
                  value: gain.clamp(widget.params.minDecibels, widget.params.maxDecibels),
                  onChanged: (v) => widget.band.setGain(v),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(_freqLabel(widget.band.centerFrequency),
                style: const TextStyle(fontSize: 11)),
          ],
        );
      },
    );
  }

  String _freqLabel(double hz) {
    if (hz >= 1000) return '${(hz / 1000).toStringAsFixed(0)}k';
    return hz.toStringAsFixed(0);
  }
}

class _IosPlaceholder extends StatelessWidget {
  const _IosPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            'iOS does not expose system equalizer bands to apps the same way Android does.\n\nFor a full iOS equalizer, integrate a platform channel that reads from MPVolumeView or use a custom AVAudioEngine pipeline.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ),
      ),
    );
  }
}
