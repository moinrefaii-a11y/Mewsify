import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:just_waveform/just_waveform.dart';
import 'package:path_provider/path_provider.dart';

import '../data/sources/youtube_source.dart';

/// Result of analysing a track for AutoMix.
class TrackAnalysis {
  /// Beats per minute. 0 if detection failed / not yet analysed.
  final double bpm;

  /// Whether this is a confident detection (autocorrelation peak was
  /// well above the noise floor). Low-confidence results are still
  /// returned but the mixer treats them cautiously.
  final bool confident;

  const TrackAnalysis({required this.bpm, required this.confident});

  Map<String, dynamic> toMap() => {'bpm': bpm, 'confident': confident};
  factory TrackAnalysis.fromMap(Map m) => TrackAnalysis(
        bpm: (m['bpm'] as num?)?.toDouble() ?? 0,
        confident: m['confident'] as bool? ?? false,
      );

  static const empty = TrackAnalysis(bpm: 0, confident: false);
}

/// On-device BPM analysis for AutoMix.
///
/// Pipeline:
///   1. Resolve the lowest-bitrate audio-only URL for the video.
///   2. Download the first ~45 s to a temp file (small — a low-bitrate
///      Opus stream is ~250 KB for 45 s).
///   3. Run `just_waveform` to extract an amplitude envelope. This uses
///      the platform's native decoder, so it transparently handles
///      YouTube's AAC / Opus containers.
///   4. Autocorrelate the envelope to find the dominant beat period,
///      convert to BPM.
///   5. Cache the result in Hive keyed by videoId so a track is only
///      ever analysed once.
///
/// Analysis runs in the background while the current track plays, so
/// the next track's BPM is ready by the time a crossfade fires.
class AutoMixAnalyzer {
  AutoMixAnalyzer(this._yt);

  final YouTubeSource _yt;
  final http.Client _http = http.Client();

  static const _boxName = 'automix_analysis';

  /// In-flight analyses keyed by videoId so we don't double-analyse.
  final Map<String, Future<TrackAnalysis>> _inFlight = {};

  Box? get _box => Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : null;

  static Future<void> ensureBoxOpen() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
  }

  /// Return a cached analysis synchronously, or null if not analysed.
  TrackAnalysis? cached(String videoId) {
    final raw = _box?.get(videoId);
    if (raw is Map) return TrackAnalysis.fromMap(raw);
    return null;
  }

  /// Analyse [videoId] (or return the cached / in-flight result).
  Future<TrackAnalysis> analyze(String videoId) {
    final existing = cached(videoId);
    if (existing != null) return Future.value(existing);
    if (_inFlight.containsKey(videoId)) return _inFlight[videoId]!;
    final fut = _runAnalysis(videoId);
    _inFlight[videoId] = fut;
    fut.whenComplete(() => _inFlight.remove(videoId));
    return fut;
  }

  Future<TrackAnalysis> _runAnalysis(String videoId) async {
    File? audioFile;
    File? waveFile;
    try {
      final url = await _yt.resolveLowBitrateAudioUrl(videoId);
      final dir = await getTemporaryDirectory();
      audioFile = File('${dir.path}/mix_$videoId.audio');
      waveFile = File('${dir.path}/mix_$videoId.wave');

      // Download ~first 700 KB — enough for 45-60 s of a low-bitrate
      // stream, which is plenty for a stable BPM estimate. A ranged
      // GET keeps it fast; if the CDN ignores Range we cap the read.
      final req = http.Request('GET', Uri.parse(url))
        ..headers['Range'] = 'bytes=0-720000';
      final resp = await _http.send(req).timeout(const Duration(seconds: 20));
      final bytes = await _collectCapped(resp.stream, 720000);
      if (bytes.length < 20000) {
        return TrackAnalysis.empty; // too little data to trust
      }
      await audioFile.writeAsBytes(bytes, flush: true);

      // Extract the amplitude envelope via the platform decoder.
      final progressStream = JustWaveform.extract(
        audioInFile: audioFile,
        waveOutFile: waveFile,
        zoom: const WaveformZoom.pixelsPerSecond(100),
      );
      Waveform? waveform;
      await for (final p in progressStream) {
        if (p.waveform != null) {
          waveform = p.waveform;
          break;
        }
      }
      if (waveform == null) return TrackAnalysis.empty;

      final bpmResult = _bpmFromWaveform(waveform);
      final analysis = TrackAnalysis(
        bpm: bpmResult.$1,
        confident: bpmResult.$2,
      );
      await _box?.put(videoId, analysis.toMap());
      debugPrint('[AutoMix] $videoId → ${analysis.bpm.toStringAsFixed(1)} BPM '
          '(confident: ${analysis.confident})');
      return analysis;
    } catch (e) {
      debugPrint('[AutoMix] analysis failed for $videoId: $e');
      return TrackAnalysis.empty;
    } finally {
      // Clean up temp files.
      try {
        await audioFile?.delete();
      } catch (_) {}
      try {
        await waveFile?.delete();
      } catch (_) {}
    }
  }

  Future<List<int>> _collectCapped(Stream<List<int>> stream, int cap) async {
    final out = <int>[];
    await for (final chunk in stream) {
      out.addAll(chunk);
      if (out.length >= cap) break;
    }
    return out;
  }

  /// Estimate BPM from a waveform amplitude envelope via autocorrelation.
  ///
  /// Returns (bpm, confident).
  ///
  /// Method:
  ///   * Build an "onset strength" signal = positive first-difference of
  ///     the rectified envelope (rising amplitude = likely beat onset).
  ///   * Autocorrelate the onset signal over the lag range that
  ///     corresponds to 60-180 BPM.
  ///   * The lag with the highest correlation is the beat period.
  ///   * Confidence = how much that peak stands out over the mean.
  (double, bool) _bpmFromWaveform(Waveform w) {
    // Build a per-pixel amplitude array from the min/max envelope.
    final n = w.length;
    if (n < 100) return (0, false);
    // Envelope samples-per-second = audio sample rate / samples per pixel.
    final pps = w.sampleRate / w.samplesPerPixel;
    if (pps <= 0) return (0, false);
    final amp = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final lo = w.getPixelMin(i).toDouble();
      final hi = w.getPixelMax(i).toDouble();
      amp[i] = (hi - lo).abs();
    }

    // Onset strength: positive difference (half-wave rectified).
    final onset = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      final d = amp[i] - amp[i - 1];
      onset[i] = d > 0 ? d : 0;
    }
    // Normalise.
    final mean = onset.reduce((a, b) => a + b) / n;
    if (mean <= 0) return (0, false);
    for (var i = 0; i < n; i++) {
      onset[i] -= mean;
    }

    // Autocorrelation over lags for 60-180 BPM.
    // lag (in envelope samples) = pps * 60 / bpm
    final minBpm = 60.0, maxBpm = 180.0;
    final minLag = (pps * 60 / maxBpm).floor().clamp(1, n - 1);
    final maxLag = (pps * 60 / minBpm).ceil().clamp(1, n - 1);
    double bestCorr = 0;
    int bestLag = 0;
    double corrSum = 0;
    int corrCount = 0;
    for (var lag = minLag; lag <= maxLag; lag++) {
      double sum = 0;
      for (var i = 0; i + lag < n; i++) {
        sum += onset[i] * onset[i + lag];
      }
      corrSum += sum;
      corrCount++;
      if (sum > bestCorr) {
        bestCorr = sum;
        bestLag = lag;
      }
    }
    if (bestLag == 0) return (0, false);

    var bpm = pps * 60 / bestLag;
    // Fold into a musical range — halve/double so we land in 70-160.
    while (bpm < 70) {
      bpm *= 2;
    }
    while (bpm > 160) {
      bpm /= 2;
    }

    final avgCorr = corrCount > 0 ? corrSum / corrCount : 0;
    final confident = avgCorr > 0 && bestCorr > avgCorr * 2.2;
    return (bpm, confident);
  }

  void dispose() => _http.close();
}
