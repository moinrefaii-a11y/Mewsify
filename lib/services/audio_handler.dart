import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../data/models/track.dart';
import '../data/sources/youtube_source.dart';
import 'automix_analyzer.dart';

/// Two-deck playback engine — the same model DJ software and crossfade
/// music players use.
///
/// Why two plain decks instead of a ConcatenatingAudioSource:
///   * We control every transition explicitly, so autoplay can never
///     get "stuck" (no reliance on ProcessingState.completed, which
///     YouTube streams don't fire reliably; no LoopMode hacks that
///     could trap the player repeating one song).
///   * A true Apple-Music-style crossfade needs two tracks playing at
///     once. Two decks give us that directly.
///
/// Deck A and Deck B are symmetric. One is "active" (what you hear),
/// the other is "idle" (used to pre-load / fade-in the next track).
/// Every track change — whether a plain skip, a natural end, or a
/// crossfade — goes through the SAME `_transitionTo` path: load the
/// next track on the idle deck, (optionally) crossfade, then swap which
/// deck is active. Clean and uniform.
///
/// Both decks are created with `handleAudioSessionActivation: false`
/// and `handleInterruptions: false` so neither steals audio focus from
/// the other (that was the bug making crossfades silent). We own the
/// audio session ourselves via the audio_session package.
class MelodyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  MelodyAudioHandler() {
    _init();
  }

  final AudioPlayer _deckA = AudioPlayer(
    handleAudioSessionActivation: false,
    handleInterruptions: false,
  );
  final AudioPlayer _deckB = AudioPlayer(
    handleAudioSessionActivation: false,
    handleInterruptions: false,
  );
  bool _useA = true;
  AudioPlayer get _active => _useA ? _deckA : _deckB;
  AudioPlayer get _idle => _useA ? _deckB : _deckA;

  final YouTubeSource _yt = YouTubeSource();
  late final AutoMixAnalyzer _analyzer = AutoMixAnalyzer(_yt);

  final List<Track> _queue = [];
  int _currentIndex = 0;
  List<int>? _shuffleOrder;

  /// Which queue index (if any) is currently pre-loaded on the idle
  /// deck, so we can start it instantly for a gapless/crossfade
  /// transition.
  int? _preloadedIndex;

  // Reactive state for the UI.
  final BehaviorSubject<bool> shuffleMode = BehaviorSubject.seeded(false);
  final BehaviorSubject<PlaybackRepeat> repeatMode =
      BehaviorSubject.seeded(PlaybackRepeat.off);
  final BehaviorSubject<Duration?> sleepTimer = BehaviorSubject.seeded(null);
  final BehaviorSubject<String?> errorEvents = BehaviorSubject.seeded(null);

  // Active-deck subscriptions, rebound on every swap.
  StreamSubscription? _eventSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _durationSub;

  Timer? _sleepTimerTask;
  Timer? _watchdog;

  bool _transitioning = false;
  bool _advancing = false;
  bool _appendingRelated = false;
  bool _sessionActive = false;

  AudioSession? _session;

  Future<void> _init() async {
    // Own the audio session ourselves. Both decks defer to us
    // (handleAudioSessionActivation:false) so they can play together.
    try {
      _session = await AudioSession.instance;
      await _session!.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
      // Manual interruption handling (since both decks opt out).
      _session!.interruptionEventStream.listen((event) {
        if (event.begin) {
          _active.pause();
        }
      });
      _session!.becomingNoisyEventStream.listen((_) {
        _active.pause(); // headphones unplugged
      });
    } catch (e) {
      debugPrint('[AudioSession] configure failed: $e');
    }

    await AutoMixAnalyzer.ensureBoxOpen();
    _bindActiveDeck();
    _bindProgress();
    _startWatchdog();
    _restoreQueue();
  }

  // ---------------------------------------------------------------------
  //  Active-deck event wiring
  // ---------------------------------------------------------------------

  void _bindActiveDeck() {
    _eventSub?.cancel();
    _stateSub?.cancel();
    _durationSub?.cancel();

    _eventSub = _active.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) {
        debugPrint('[Deck] mid-stream error: $e');
        errorEvents.add('Skipping — connection issue');
        _advance(auto: true);
      },
    );

    // Completion is a SECONDARY advance trigger (the watchdog is
    // primary). Useful for very short tracks where the watchdog window
    // math is tight.
    _stateSub = _active.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _advance(auto: true);
      }
    });

    _durationSub = _active.durationStream.listen((d) {
      if (d == null || d == Duration.zero) return;
      if (_currentIndex < 0 || _currentIndex >= _queue.length) return;
      final cur = _queue[_currentIndex];
      if (cur.duration != d) {
        _queue[_currentIndex] = cur.copyWithDuration(d);
      }
      mediaItem.add(_queue[_currentIndex].toMediaItem());
    });
  }

  void _broadcastState(PlaybackEvent event) {
    final playing = _active.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_active.processingState]!,
      playing: playing,
      updatePosition: _active.position,
      bufferedPosition: _active.bufferedPosition,
      speed: _active.speed,
      queueIndex: _currentIndex,
    ));
  }

  // ---------------------------------------------------------------------
  //  Watchdog — the single driver of transitions
  // ---------------------------------------------------------------------

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_transitioning || _advancing) return;
      if (!_active.playing) return;
      final dur = _effectiveDuration();
      final pos = _active.position;
      if (dur == null || dur.inMilliseconds < 1500) return;
      final remainingMs = dur.inMilliseconds - pos.inMilliseconds;

      // Repeat-one: loop the current track at its end.
      if (repeatMode.value == PlaybackRepeat.one) {
        if (remainingMs <= 250) {
          await _active.seek(Duration.zero);
          await _active.play();
        }
        return;
      }

      final fadeSecs = _crossfadeSeconds();
      final nextIndex = _peekNextIndex();

      // Pre-load the next track on the idle deck a bit before we need
      // it (fade window + 8 s) so the transition can start instantly.
      if (nextIndex != null &&
          _preloadedIndex != nextIndex &&
          remainingMs <= (fadeSecs * 1000) + 8000) {
        unawaited(_preloadIdle(nextIndex));
      }

      if (nextIndex == null) {
        // Near the end with nothing queued — pull related tracks in.
        if (remainingMs <= 20000) unawaited(_maybeAppendRelated());
        return;
      }

      if (fadeSecs > 0) {
        // Crossfade: begin so the fade COMPLETES around the natural end
        // (start when remaining ≈ fade duration). Apple-style: we don't
        // wait for the song to fully end — the next one is already
        // rising while this one tails out.
        if (remainingMs <= fadeSecs * 1000 && remainingMs > 250) {
          await _transitionTo(nextIndex, fadeSecs: fadeSecs, auto: true);
        }
      } else {
        // No crossfade: hard-advance right at the end. Gapless because
        // the idle deck is pre-loaded.
        if (remainingMs <= 300) {
          await _transitionTo(nextIndex, fadeSecs: 0, auto: true);
        }
      }
    });
  }

  Duration? _effectiveDuration() {
    final d = _active.duration;
    if (d != null && d > Duration.zero) return d;
    if (_currentIndex >= 0 && _currentIndex < _queue.length) {
      final td = _queue[_currentIndex].duration;
      if (td > Duration.zero) return td;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  //  The unified transition path
  // ---------------------------------------------------------------------

  /// Load [index] on the idle deck (if not already), optionally
  /// crossfade, then swap decks so the idle becomes active. This one
  /// method handles plain skips (fadeSecs 0), natural ends, and
  /// crossfades.
  Future<void> _transitionTo(
    int index, {
    required int fadeSecs,
    bool auto = false,
  }) async {
    if (_transitioning) return;
    if (index < 0 || index >= _queue.length) return;
    _transitioning = true;

    final track = _queue[index];
    final incoming = _idle;
    final outgoing = _active;

    final debug = _debugEnabled();

    try {
      // Make sure the incoming deck holds this track.
      if (_preloadedIndex != index) {
        final ok = await _loadOnDeck(incoming, track);
        if (!ok) {
          // Couldn't load this track — drop it and try the next one.
          _transitioning = false;
          _queue.removeAt(index);
          _broadcastQueue();
          if (index < _queue.length) {
            await _transitionTo(index, fadeSecs: fadeSecs, auto: auto);
          }
          return;
        }
      }
      _preloadedIndex = null;

      await incoming.seek(Duration.zero);

      if (fadeSecs <= 0) {
        // Instant swap.
        await incoming.setSpeed(1.0);
        await incoming.setVolume(1.0);
        await incoming.play();
        await outgoing.pause();
        await outgoing.setVolume(1.0);
      } else {
        if (debug) errorEvents.add('🎚️ Crossfading…');
        // Beat match: bend the OUTGOING track's tempo to the incoming
        // track's BPM during the fade. Incoming stays at natural speed,
        // so it just continues cleanly after the swap — no post-fade
        // tempo correction needed.
        double outSpeed = 1.0;
        if (_beatMatchEnabled()) {
          final outA = _analyzer.cached(_queue[_currentIndex].sourceVideoId);
          final inA = _analyzer.cached(track.sourceVideoId);
          if (outA != null &&
              inA != null &&
              outA.confident &&
              inA.confident &&
              outA.bpm > 0 &&
              inA.bpm > 0) {
            final ratio = inA.bpm / outA.bpm;
            if (ratio >= 0.92 && ratio <= 1.08) {
              outSpeed = ratio;
              if (debug) {
                errorEvents.add('🥁 Beat-match '
                    '${outA.bpm.toStringAsFixed(0)}→'
                    '${inA.bpm.toStringAsFixed(0)}');
              }
            }
          }
        }

        await incoming.setSpeed(1.0);
        await incoming.setVolume(0.0);
        await incoming.play();

        final match = _loudnessMatchEnabled();
        final inPeak = match ? 0.94 : 1.0;
        final outPeak = match ? 1.04 : 1.0;

        // Steady 40 fps ramp; non-blocking volume calls so the ramp
        // keeps real-time cadence.
        final steps = (fadeSecs * 40).clamp(40, 480);
        final stepMs = (fadeSecs * 1000 / steps).round();
        for (var i = 1; i <= steps; i++) {
          final t = i / steps;
          final outVol = (cos(t * pi / 2) * outPeak).clamp(0.0, 1.0);
          final inVol = (sin(t * pi / 2) * inPeak).clamp(0.0, 1.0);
          outgoing.setVolume(outVol).catchError((_) {});
          incoming.setVolume(inVol).catchError((_) {});
          if (outSpeed != 1.0) {
            // Ease the outgoing tempo toward the match over the fade.
            final s = 1.0 + (outSpeed - 1.0) * t;
            outgoing.setSpeed(s).catchError((_) {});
          }
          await Future.delayed(Duration(milliseconds: stepMs));
          if (!_transitioning) break;
        }
        await incoming.setVolume(1.0);
        await outgoing.pause();
        await outgoing.setVolume(1.0);
        await outgoing.setSpeed(1.0);
      }

      // Swap decks.
      _useA = !_useA;
      _currentIndex = index;
      _bindActiveDeck();
      mediaItem.add(track.toMediaItem());
      _broadcastState(PlaybackEvent());
      if (debug) errorEvents.add('✅ Now: ${track.title}');
    } catch (e) {
      debugPrint('[Transition] failed: $e');
      // Recover — make sure SOMETHING is playing.
      try {
        await _active.setVolume(1.0);
        await _active.play();
      } catch (_) {}
    } finally {
      _transitioning = false;
    }

    _persistQueue();
    unawaited(_preloadNextIdle());
    unawaited(_maybeAppendRelated());
    _analyzeAroundCurrent();
  }

  /// Load a track's audio URL onto a specific deck. Returns false if
  /// the URL couldn't be resolved (geo-block / removed / age-gate).
  Future<bool> _loadOnDeck(AudioPlayer deck, Track track) async {
    try {
      final url = await _yt.resolveAudioUrl(track.sourceVideoId);
      await deck.setAudioSource(
        AudioSource.uri(Uri.parse(url), tag: track.toMediaItem()),
        preload: true,
      );
      return true;
    } catch (e) {
      debugPrint('[Deck] load failed for ${track.title}: $e');
      return false;
    }
  }

  Future<void> _preloadIdle(int index) async {
    if (index < 0 || index >= _queue.length) return;
    if (_preloadedIndex == index) return;
    if (_transitioning) return;
    final ok = await _loadOnDeck(_idle, _queue[index]);
    if (ok) {
      await _idle.setVolume(0.0);
      _preloadedIndex = index;
    }
  }

  Future<void> _preloadNextIdle() async {
    final next = _peekNextIndex();
    if (next != null) await _preloadIdle(next);
  }

  // ---------------------------------------------------------------------
  //  Playing tracks / queue setup
  // ---------------------------------------------------------------------

  /// Start playing [index] fresh on the active deck (no fade). Used for
  /// setQueue / skipToQueueItem / previous.
  Future<void> _playIndexNow(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _transitioning = true;
    try {
      await _ensureSessionActive();
      final ok = await _loadOnDeck(_active, _queue[index]);
      if (!ok) {
        _queue.removeAt(index);
        _broadcastQueue();
        _transitioning = false;
        if (index < _queue.length) await _playIndexNow(index);
        return;
      }
      _currentIndex = index;
      await _active.setSpeed(1.0);
      await _active.setVolume(1.0);
      await _active.play();
      mediaItem.add(_queue[index].toMediaItem());
      _preloadedIndex = null;
    } finally {
      _transitioning = false;
    }
    _persistQueue();
    unawaited(_preloadNextIdle());
    unawaited(_maybeAppendRelated());
    _analyzeAroundCurrent();
  }

  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    _queue
      ..clear()
      ..addAll(tracks);
    _shuffleOrder = null;
    if (shuffleMode.value) _rebuildShuffleOrder(startIndex);
    _broadcastQueue();
    await _playIndexNow(startIndex.clamp(0, _queue.length - 1));
  }

  Future<void> playWithAutoplay(Track seed) async {
    _queue
      ..clear()
      ..add(seed);
    _broadcastQueue();
    await _playIndexNow(0);
    unawaited(_maybeAppendRelated());
  }

  Future<void> startRadio(Track seed) => playWithAutoplay(seed);

  // ---------------------------------------------------------------------
  //  Advance helpers
  // ---------------------------------------------------------------------

  int? _peekNextIndex() {
    if (_queue.isEmpty) return null;
    if (shuffleMode.value && _shuffleOrder != null) {
      final pos = _shuffleOrder!.indexOf(_currentIndex);
      if (pos < 0 || pos + 1 >= _shuffleOrder!.length) return null;
      return _shuffleOrder![pos + 1];
    }
    return _currentIndex + 1 < _queue.length ? _currentIndex + 1 : null;
  }

  int? _previousIndex() {
    if (_queue.isEmpty) return null;
    if (shuffleMode.value && _shuffleOrder != null) {
      final pos = _shuffleOrder!.indexOf(_currentIndex);
      if (pos <= 0) return null;
      return _shuffleOrder![pos - 1];
    }
    return _currentIndex - 1 >= 0 ? _currentIndex - 1 : null;
  }

  /// Advance to the next track (used by natural end + error recovery).
  Future<void> _advance({bool auto = false}) async {
    if (_advancing || _transitioning) return;
    _advancing = true;
    try {
      var next = _peekNextIndex();
      if (next == null) {
        await _maybeAppendRelated();
        next = _peekNextIndex();
      }
      if (next == null && repeatMode.value == PlaybackRepeat.all) {
        next = 0;
      }
      if (next != null) {
        await _transitionTo(next, fadeSecs: 0, auto: auto);
      }
    } finally {
      _advancing = false;
    }
  }

  Future<void> _maybeAppendRelated() async {
    if (_appendingRelated) return;
    // Only fetch when we're near the tail.
    if (_currentIndex + 3 < _queue.length) return;
    _appendingRelated = true;
    try {
      if (_queue.isEmpty) return;
      final seed = _queue.last;
      List<Track> pool = const [];
      try {
        pool = await _yt.related(seed.sourceVideoId, limit: 15);
      } catch (_) {}
      if (pool.isEmpty) {
        try {
          pool = await _yt.search(seed.artist, limit: 15);
        } catch (_) {}
      }
      final picks = pool
          .where((t) => !_queue.contains(t))
          .where(_reasonableDuration)
          .take(8)
          .toList();
      if (picks.isEmpty) return;
      _queue.addAll(picks);
      _broadcastQueue();
      unawaited(_preloadNextIdle());
    } finally {
      _appendingRelated = false;
    }
  }

  bool _reasonableDuration(Track t) {
    final s = t.duration.inSeconds;
    if (s == 0) return true;
    return s >= 45 && s <= 15 * 60;
  }

  void _broadcastQueue() {
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
  }

  // ---------------------------------------------------------------------
  //  Crossfade settings + analysis
  // ---------------------------------------------------------------------

  int _crossfadeSeconds() {
    if (!Hive.isBoxOpen('settings')) return 6;
    final box = Hive.box('settings');
    final base = box.containsKey('crossfadeSeconds')
        ? (box.get('crossfadeSeconds') as int).clamp(0, 12)
        : 6;
    if (base == 0) return 0;
    final auto = box.get('crossfadeAuto', defaultValue: false) as bool;
    if (!auto) return base;
    if (_currentIndex >= 0 && _currentIndex < _queue.length) {
      final d = _queue[_currentIndex].duration.inSeconds;
      if (d > 0) {
        if (d < 90) return 3;
        if (d < 150) return 4;
        if (d < 240) return (base * 0.8).round().clamp(3, base);
      }
    }
    return base;
  }

  bool _loudnessMatchEnabled() =>
      Hive.isBoxOpen('settings') &&
      Hive.box('settings').get('crossfadeLoudnessMatch', defaultValue: true)
          as bool;

  bool _beatMatchEnabled() =>
      Hive.isBoxOpen('settings') &&
      Hive.box('settings').get('crossfadeBeatMatch', defaultValue: true) as bool;

  bool _debugEnabled() =>
      Hive.isBoxOpen('settings') &&
      Hive.box('settings').get('crossfadeDebug', defaultValue: false) as bool;

  void _analyzeAroundCurrent() {
    if (!_beatMatchEnabled()) return;
    for (var i = _currentIndex;
        i <= _currentIndex + 2 && i < _queue.length;
        i++) {
      final vid = _queue[i].sourceVideoId;
      if (_analyzer.cached(vid) == null) {
        unawaited(_analyzer.analyze(vid));
      }
    }
  }

  // ---------------------------------------------------------------------
  //  Session
  // ---------------------------------------------------------------------

  Future<void> _ensureSessionActive() async {
    if (_sessionActive) return;
    try {
      await _session?.setActive(true);
      _sessionActive = true;
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  //  Shuffle / repeat / sleep
  // ---------------------------------------------------------------------

  void _rebuildShuffleOrder(int currentIndex) {
    final indices = List.generate(_queue.length, (i) => i)..remove(currentIndex);
    indices.shuffle(Random());
    _shuffleOrder = [currentIndex, ...indices];
  }

  Future<void> toggleShuffle() async {
    final v = !shuffleMode.value;
    shuffleMode.add(v);
    if (v && _queue.isNotEmpty) {
      _rebuildShuffleOrder(_currentIndex);
    } else {
      _shuffleOrder = null;
    }
    _preloadedIndex = null;
    unawaited(_preloadNextIdle());
  }

  Future<void> cycleRepeat() async {
    final modes = PlaybackRepeat.values;
    repeatMode.add(modes[(repeatMode.value.index + 1) % modes.length]);
  }

  Future<void> setSleepTimer(Duration? duration) async {
    _sleepTimerTask?.cancel();
    sleepTimer.add(duration);
    if (duration == null) return;
    _sleepTimerTask = Timer(duration, () {
      pause();
      sleepTimer.add(null);
    });
  }

  // ---------------------------------------------------------------------
  //  Handler overrides
  // ---------------------------------------------------------------------

  @override
  Future<void> play() async {
    await _ensureSessionActive();
    await _active.play();
  }

  @override
  Future<void> pause() async {
    await _active.pause();
    _persistQueue();
  }

  @override
  Future<void> seek(Duration position) => _active.seek(position);

  @override
  Future<void> stop() async {
    await _deckA.stop();
    await _deckB.stop();
    try {
      await _session?.setActive(false);
    } catch (_) {}
    _sessionActive = false;
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }

  @override
  Future<void> skipToNext() async {
    if (_transitioning) return;
    var next = _peekNextIndex();
    if (next == null) {
      await _maybeAppendRelated();
      next = _peekNextIndex();
    }
    if (next == null) {
      // Aggressive fallback so Next is never a dead button.
      try {
        final pool = await _yt.search(_queue.last.title, limit: 10);
        final picks =
            pool.where((t) => !_queue.contains(t)).take(5).toList();
        if (picks.isNotEmpty) {
          _queue.addAll(picks);
          _broadcastQueue();
          next = _peekNextIndex();
        }
      } catch (_) {}
    }
    if (next != null) {
      // User-initiated skip = instant (no crossfade).
      await _transitionTo(next, fadeSecs: 0);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_transitioning) return;
    if (_active.position > const Duration(seconds: 3)) {
      await _active.seek(Duration.zero);
      return;
    }
    final prev = _previousIndex();
    if (prev != null) await _playIndexNow(prev);
  }

  @override
  Future<void> skipToQueueItem(int index) => _playIndexNow(index);

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    _queue.add(_trackFromMediaItem(mediaItem));
    _broadcastQueue();
    unawaited(_preloadNextIdle());
  }

  Future<void> playNext(Track track) async {
    final insertAt = (_currentIndex + 1).clamp(0, _queue.length);
    _queue.insert(insertAt, track);
    _broadcastQueue();
    _preloadedIndex = null;
    unawaited(_preloadNextIdle());
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    if (index < _currentIndex) _currentIndex--;
    _preloadedIndex = null;
    _broadcastQueue();
    unawaited(_preloadNextIdle());
  }

  Future<void> smartShuffle() async {
    final libRepo = Hive.isBoxOpen('favorites')
        ? Hive.box<Track>('favorites').values.toList()
        : <Track>[];
    final history = Hive.isBoxOpen('history')
        ? Hive.box<Track>('history').values.toList()
        : <Track>[];
    final library = ([...libRepo, ...history].toSet().toList())..shuffle();
    if (library.isEmpty) return;
    final seed = library.first;
    final related = <Track>[];
    try {
      related.addAll(await _yt.related(seed.sourceVideoId, limit: 30));
    } catch (_) {}
    final mix = <Track>[];
    final lib = library.take(20).toList();
    for (var i = 0; i < (lib.length + related.length); i++) {
      if (i.isEven && i ~/ 2 < lib.length) {
        mix.add(lib[i ~/ 2]);
      } else if (i.isOdd && i ~/ 2 < related.length) {
        mix.add(related[i ~/ 2]);
      }
    }
    final unique = mix.toSet().toList();
    if (unique.isEmpty) return;
    shuffleMode.add(true);
    await setQueue(unique);
  }

  // ---------------------------------------------------------------------
  //  Background hoist (Browse tab → native audio)
  // ---------------------------------------------------------------------

  String? _warmedVideoId;

  Future<void> prepareForBackgroundHoist(Track track) async {
    if (_warmedVideoId == track.sourceVideoId) return;
    _warmedVideoId = track.sourceVideoId;
    try {
      if (_active.playing) return;
      _queue
        ..clear()
        ..add(track);
      _currentIndex = 0;
      _broadcastQueue();
      mediaItem.add(track.toMediaItem());
      final ok = await _loadOnDeck(_active, track);
      if (ok) await _active.setVolume(0.0);
    } catch (e) {
      debugPrint('[Hoist] warm failed: $e');
      _warmedVideoId = null;
    }
  }

  Future<void> resumeWarmedHoist({required Duration startAt}) async {
    if (_warmedVideoId == null) return;
    try {
      await _ensureSessionActive();
      if (startAt > Duration.zero) await _active.seek(startAt);
      await _active.setVolume(1.0);
      await _active.play();
      unawaited(_maybeAppendRelated());
    } catch (e) {
      debugPrint('[Hoist] resume failed: $e');
    }
  }

  void clearWarmedHoist() => _warmedVideoId = null;

  // ---------------------------------------------------------------------
  //  Persistence
  // ---------------------------------------------------------------------

  static const _queueBoxName = 'queue';

  Future<void> _restoreQueue() async {
    if (!Hive.isBoxOpen(_queueBoxName)) return;
    final box = Hive.box<Track>(_queueBoxName);
    if (box.isEmpty) return;
    final settings = Hive.box('settings');
    final savedIndex = settings.get('queueIndex', defaultValue: 0) as int;
    _queue
      ..clear()
      ..addAll(box.values);
    _currentIndex = savedIndex.clamp(0, _queue.length - 1);
    _broadcastQueue();
    if (_currentIndex < _queue.length) {
      mediaItem.add(_queue[_currentIndex].toMediaItem());
    }
    // Don't auto-play on restore.
  }

  Future<void> _persistQueue() async {
    if (!Hive.isBoxOpen(_queueBoxName)) return;
    final box = Hive.box<Track>(_queueBoxName);
    await box.clear();
    await box.addAll(_queue);
    final settings = Hive.box('settings');
    await settings.put('queueIndex', _currentIndex);
    await settings.put('queuePositionMs', _active.position.inMilliseconds);
  }

  // ---------------------------------------------------------------------
  //  Public read-only state
  // ---------------------------------------------------------------------

  Stream<Duration> get positionStream => _active.positionStream;
  Stream<Duration?> get durationStream => _active.durationStream;
  Stream<bool> get playingStream => _active.playingStream;
  AudioPlayer get rawPlayer => _active;
  List<Track> get currentQueue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  bool get isStalled => false;

  Track? get currentTrack =>
      _currentIndex >= 0 && _currentIndex < _queue.length
          ? _queue[_currentIndex]
          : null;

  final BehaviorSubject<ProgressData> _progressSubject =
      BehaviorSubject<ProgressData>.seeded(
    const ProgressData(
      position: Duration.zero,
      duration: Duration.zero,
      playing: false,
    ),
  );

  StreamSubscription? _progressPosSub;
  StreamSubscription? _progressDurSub;
  StreamSubscription? _progressPlaySub;

  /// Rebound whenever the active deck changes so progress always
  /// reflects what you're hearing.
  void _bindProgress() {
    _progressPosSub?.cancel();
    _progressDurSub?.cancel();
    _progressPlaySub?.cancel();

    Duration pos = _active.position;
    Duration? dur = _active.duration;
    bool playing = _active.playing;

    void emit() {
      _progressSubject.add(ProgressData(
        position: pos,
        duration: dur ?? Duration.zero,
        playing: playing,
      ));
    }

    // Listen to BOTH decks; only forward events from whichever is
    // active right now. Simpler than tearing down + rebinding on every
    // swap, and avoids missing the first events after a swap.
    void wire(AudioPlayer deck) {
      deck.positionStream.listen((p) {
        if (!identical(deck, _active)) return;
        pos = p;
        emit();
      });
      deck.durationStream.listen((d) {
        if (!identical(deck, _active)) return;
        dur = d;
        emit();
      });
      deck.playingStream.listen((p) {
        if (!identical(deck, _active)) return;
        playing = p;
        emit();
      });
    }

    wire(_deckA);
    wire(_deckB);
    emit();
  }

  Stream<ProgressData> get progressStream => _progressSubject.stream;

  Track _trackFromMediaItem(MediaItem mediaItem) => Track(
        id: mediaItem.id,
        title: mediaItem.title,
        artist: mediaItem.artist ?? 'Unknown',
        album: mediaItem.album,
        thumbnailUrl: mediaItem.artUri?.toString() ?? '',
        duration: mediaItem.duration ?? Duration.zero,
        sourceVideoId: mediaItem.extras?['videoId'] as String? ?? '',
        addedAt: DateTime.now(),
      );
}

class ProgressData {
  final Duration position;
  final Duration duration;
  final bool playing;
  const ProgressData({
    required this.position,
    required this.duration,
    required this.playing,
  });
}

enum PlaybackRepeat { off, all, one }
