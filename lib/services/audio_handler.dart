import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../data/models/track.dart';
import '../data/sources/youtube_source.dart';

/// Playback pipeline for MewSify.
///
/// v0.6.0 architecture: **ConcatenatingAudioSource** for auto-advance
/// (matches how Spotify / YouTube Music / Apple Music work). The main
/// AudioPlayer plays a concat source; just_audio handles gapless
/// advancement between tracks in native code. Our Dart layer only
/// listens to `currentIndexStream` to know when to fetch more.
///
/// A secondary AudioPlayer overlays during crossfades to blend the
/// last N seconds of the outgoing track with the first N seconds of
/// the incoming one. When the crossfade completes we sync the main
/// player's position to the overlay and hand playback back — the
/// user hears a seamless transition.
///
/// "AutoMix" mode adds three heuristic transition improvements on top
/// of the raw crossfade:
///   - Adaptive fade *duration* (short songs get shorter fades)
///   - Loudness match (caps incoming volume, pads outgoing) so a
///     jarring-loud next track doesn't slam over a mellow current one
///   - Silent-intro detection (implicit — the concat source already
///     handles gapless if the audio itself starts quietly)
class MelodyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  MelodyAudioHandler() {
    _init();
  }

  /// Main player. Plays a `ConcatenatingAudioSource` that grows as we
  /// resolve upcoming tracks. just_audio auto-advances between items
  /// natively so we never rely on Dart-side end-of-track detection.
  final AudioPlayer _player = AudioPlayer();

  /// Overlay player used only during crossfades. Lazily created so we
  /// don't hold a second decoder + audio focus session when crossfade
  /// is off (the default for many users).
  AudioPlayer? _crossfadeLazy;
  AudioPlayer get _crossfadePlayer => _crossfadeLazy ??= AudioPlayer();

  /// The backing playlist source for `_player`. We mutate it (`.add`,
  /// `.removeAt`) to grow / shrink the queue at runtime.
  final ConcatenatingAudioSource _concat =
      ConcatenatingAudioSource(children: []);

  /// Logical queue: full list of user-visible tracks. May run ahead of
  /// `_concat.length` because we resolve URLs lazily (URLs from
  /// YouTube expire ≤ 6 h, so pre-resolving the whole queue is wasteful).
  final List<Track> _queue = [];

  /// Index within `_queue` (and `_concat`) that's currently playing.
  int _currentIndex = 0;

  /// Shuffle bookkeeping (only meaningful when `shuffleMode.value`).
  List<int>? _shuffleOrder;

  final YouTubeSource _yt = YouTubeSource();

  // Reactive state surfaced to the UI.
  final BehaviorSubject<bool> shuffleMode = BehaviorSubject.seeded(false);
  final BehaviorSubject<PlaybackRepeat> repeatMode =
      BehaviorSubject.seeded(PlaybackRepeat.off);
  final BehaviorSubject<Duration?> sleepTimer = BehaviorSubject.seeded(null);
  final BehaviorSubject<String?> errorEvents = BehaviorSubject.seeded(null);

  // Subscriptions on the main player.
  StreamSubscription? _eventSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _indexSub;
  StreamSubscription? _durationSub;

  Timer? _sleepTimerTask;
  Timer? _crossfadeWatchdog;
  bool _crossfading = false;
  bool _resolvingNext = false;

  Future<void> _init() async {
    _bindPlayerListeners();
    _bindProgress();
    await _player.setAudioSource(
      _concat,
      preload: false,
      initialIndex: 0,
    );
    _restoreQueue();
  }

  // ---------------------------------------------------------------------
  //  Player event wiring
  // ---------------------------------------------------------------------

  void _bindPlayerListeners() {
    _eventSub?.cancel();
    _stateSub?.cancel();
    _indexSub?.cancel();
    _durationSub?.cancel();

    _eventSub = _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) {
        // Mid-stream error (URL expired, network dropped, DRM). Try to
        // remove the bad item from the concat source and let just_audio
        // advance to the next one naturally.
        debugPrint('[Player] mid-stream error: $e');
        errorEvents.add('Skipping — connection issue on this track');
        _skipBrokenAndAdvance();
      },
    );

    // Auto-advance is now driven by just_audio's native playlist logic.
    // The Dart side just needs to know WHICH item is playing so it can:
    //   * update the media item (lock screen / notification)
    //   * pre-resolve upcoming URLs
    //   * fetch related tracks when the queue is near-empty
    _indexSub = _player.currentIndexStream.listen((index) {
      if (index == null) return;
      _currentIndex = index;
      if (_currentIndex >= 0 && _currentIndex < _queue.length) {
        mediaItem.add(_queue[_currentIndex].toMediaItem());
      }
      _ensureUpcomingResolved();
      _maybeAppendRelated();
      _persistQueue();
      _scheduleCrossfade();
    });

    _stateSub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        // Reached the end of the concat source — no more items and no
        // more upcoming. Try one last related-tracks fetch.
        _handleFinalCompletion();
      }
    });

    _durationSub = _player.durationStream.listen((d) {
      // Rebroadcast MediaItem with the resolved duration so lockscreen
      // + Bluetooth head units show real track info.
      if (d == null || d == Duration.zero) return;
      if (_currentIndex < 0 || _currentIndex >= _queue.length) return;
      final current = _queue[_currentIndex];
      if (current.duration != d) {
        _queue[_currentIndex] = Track(
          id: current.id,
          title: current.title,
          artist: current.artist,
          album: current.album,
          thumbnailUrl: current.thumbnailUrl,
          duration: d,
          sourceVideoId: current.sourceVideoId,
          addedAt: current.addedAt,
        );
      }
      mediaItem.add(current.toMediaItem().copyWith(duration: d));
    });
  }

  // ---------------------------------------------------------------------
  //  Queue setup
  // ---------------------------------------------------------------------

  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    _queue
      ..clear()
      ..addAll(tracks);
    _shuffleOrder = null;
    if (shuffleMode.value) _rebuildShuffleOrder(startIndex);
    queue.add(_queue.map((t) => t.toMediaItem()).toList());

    _currentIndex = startIndex.clamp(0, _queue.length - 1);
    await _rebuildConcat(startAt: _currentIndex, initialResolveCount: 3);
    await _player.play();
    _persistQueue();
  }

  /// Rebuild `_concat` from scratch starting at `_queue[startAt]`.
  /// Resolves the first `initialResolveCount` upcoming items in
  /// parallel so playback can start ASAP while background resolves
  /// warm up the following items.
  Future<void> _rebuildConcat({
    required int startAt,
    int initialResolveCount = 3,
  }) async {
    await _concat.clear();
    if (_queue.isEmpty) return;
    // Resolve the head of the queue in parallel so playback can start
    // even if some URLs 403 — we'll skip broken items automatically.
    final headEnd = min(startAt + initialResolveCount, _queue.length);
    final futures = <Future<AudioSource?>>[];
    for (var i = startAt; i < headEnd; i++) {
      futures.add(_makeSource(_queue[i]));
    }
    final sources = await Future.wait(futures);
    for (var i = 0; i < sources.length; i++) {
      final src = sources[i];
      if (src != null) {
        await _concat.add(src);
      } else {
        // Broken track — remove from logical queue too so the concat
        // and _queue indices stay aligned.
        final drop = startAt + i;
        if (drop < _queue.length) {
          _queue.removeAt(drop);
          queue.add(_queue.map((t) => t.toMediaItem()).toList());
        }
      }
    }
    if (_concat.length == 0) {
      errorEvents.add('Could not load any tracks');
      return;
    }
    // Point the player at position 0 of the freshly built concat.
    await _player.seek(Duration.zero, index: 0);
  }

  /// Build an [AudioSource] for a single [Track]. Returns null if the
  /// URL couldn't be resolved (which is common for
  /// geo-blocked / age-restricted / removed videos on YouTube).
  Future<AudioSource?> _makeSource(Track track) async {
    try {
      final url = await _yt.resolveAudioUrl(track.sourceVideoId);
      return AudioSource.uri(
        Uri.parse(url),
        tag: track.toMediaItem(),
      );
    } catch (e) {
      debugPrint('[AudioHandler] source failed for ${track.title}: $e');
      return null;
    }
  }

  /// Called after every index change. Ensures the concat source has
  /// resolved sources for the next couple of tracks so just_audio's
  /// native auto-advance can jump straight to them.
  Future<void> _ensureUpcomingResolved() async {
    if (_resolvingNext) return;
    _resolvingNext = true;
    try {
      // Target: at least 2 items after the current in the concat.
      while (_concat.length < _currentIndex + 3 &&
          _concat.length < _queue.length) {
        final idx = _concat.length;
        final src = await _makeSource(_queue[idx]);
        if (src != null) {
          await _concat.add(src);
        } else {
          // Drop broken track from logical queue too. Since it's ahead
          // of the current index, this doesn't shift what's playing.
          _queue.removeAt(idx);
          queue.add(_queue.map((t) => t.toMediaItem()).toList());
        }
      }
    } finally {
      _resolvingNext = false;
    }
  }

  /// If we're within 3 items of the tail of the logical queue, fetch
  /// related tracks and append. This is the "infinite radio" behaviour
  /// Spotify/YMusic use.
  Future<void> _maybeAppendRelated() async {
    if (_currentIndex + 3 < _queue.length) return;
    if (_appendingRelated) return;
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
      // Filter: reasonable duration, not already in queue.
      final picks = pool
          .where((t) => !_queue.contains(t))
          .where(_reasonableDuration)
          .take(8)
          .toList();
      if (picks.isEmpty) return;
      _queue.addAll(picks);
      queue.add(_queue.map((t) => t.toMediaItem()).toList());
      // Kick off resolution for the new items so they're ready when we
      // reach them.
      unawaited(_ensureUpcomingResolved());
    } finally {
      _appendingRelated = false;
    }
  }

  bool _appendingRelated = false;

  bool _reasonableDuration(Track t) {
    final s = t.duration.inSeconds;
    if (s == 0) return true;
    return s >= 45 && s <= 15 * 60;
  }

  Future<void> _skipBrokenAndAdvance() async {
    // Remove the current source; the concat will auto-shift and
    // just_audio will start playing the next item.
    try {
      if (_currentIndex < _concat.length) {
        await _concat.removeAt(_currentIndex);
        if (_currentIndex < _queue.length) {
          _queue.removeAt(_currentIndex);
          queue.add(_queue.map((t) => t.toMediaItem()).toList());
        }
      }
    } catch (_) {}
    // Kick play if we have anything left.
    if (_concat.length > 0) {
      await _player.play();
    }
  }

  Future<void> _handleFinalCompletion() async {
    // End of the entire concat source. Try one more related fetch
    // and, if that yields items, resume playback from there.
    if (repeatMode.value == PlaybackRepeat.all && _queue.isNotEmpty) {
      await _rebuildConcat(startAt: 0);
      await _player.play();
      return;
    }
    await _maybeAppendRelated();
    if (_concat.length > _currentIndex + 1) {
      await _player.seek(Duration.zero, index: _currentIndex + 1);
      await _player.play();
    }
  }

  Future<void> playWithAutoplay(Track seed) async {
    _queue
      ..clear()
      ..add(seed);
    _currentIndex = 0;
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
    await _rebuildConcat(startAt: 0, initialResolveCount: 1);
    await _player.play();
    unawaited(_maybeAppendRelated());
  }

  // ---------------------------------------------------------------------
  //  Queue persistence
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
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
    if (_currentIndex < _queue.length) {
      mediaItem.add(_queue[_currentIndex].toMediaItem());
    }
    // Don't auto-play on restore — user has to hit play.
  }

  Future<void> _persistQueue() async {
    if (!Hive.isBoxOpen(_queueBoxName)) return;
    final box = Hive.box<Track>(_queueBoxName);
    await box.clear();
    await box.addAll(_queue);
    final settings = Hive.box('settings');
    await settings.put('queueIndex', _currentIndex);
    await settings.put('queuePositionMs', _player.position.inMilliseconds);
  }

  // ---------------------------------------------------------------------
  //  Crossfade (AutoMix-style overlay)
  // ---------------------------------------------------------------------

  /// Every 250 ms while the main player is playing, check whether we
  /// should be running a crossfade to the next item. If yes, fire it
  /// off. The main player still auto-advances on its own timeline
  /// (silently, because we ramp its volume to 0); the overlay player
  /// carries the audible transition.
  void _scheduleCrossfade() {
    _crossfadeWatchdog?.cancel();
    _crossfadeWatchdog =
        Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_crossfading) return;
      if (!_player.playing) return;
      final dur = _player.duration;
      final pos = _player.position;
      if (dur == null || dur.inMilliseconds < 1000) return;
      final rmMs = (dur - pos).inMilliseconds;
      final seconds = _crossfadeSeconds();
      if (seconds <= 0) return;
      // Only run the fade if there's a next item queued and we're
      // within the fade window (with a 300 ms lead so the fade starts
      // just before the natural end).
      if (rmMs > 200 && rmMs <= seconds * 1000 + 300) {
        final nextIdx = _currentIndex + 1;
        if (nextIdx >= _queue.length) return;
        await _startCrossfade(toIndex: nextIdx, durationSeconds: seconds);
      }
    });
  }

  int _crossfadeSeconds() {
    if (!Hive.isBoxOpen('settings')) return 5;
    final box = Hive.box('settings');
    // 5 s default if the user has never touched the slider.
    final base = box.containsKey('crossfadeSeconds')
        ? (box.get('crossfadeSeconds') as int).clamp(0, 12)
        : 5;
    if (base == 0) return 0;
    final auto = box.get('crossfadeAuto', defaultValue: false) as bool;
    if (!auto) return base;
    // AutoMix adaptive duration — short songs get shorter fades.
    if (_currentIndex >= 0 && _currentIndex < _queue.length) {
      final d = _queue[_currentIndex].duration.inSeconds;
      if (d > 0) {
        if (d < 90) return 2;
        if (d < 150) return 3;
        if (d < 240) return (base * 0.7).round().clamp(2, base);
      }
    }
    return base;
  }

  bool _loudnessMatchEnabled() {
    if (!Hive.isBoxOpen('settings')) return true;
    return Hive.box('settings')
        .get('crossfadeLoudnessMatch', defaultValue: true) as bool;
  }

  /// Runs a two-player crossfade between the current track (fading out
  /// on `_player`) and the next track (fading in on `_crossfadePlayer`).
  /// After the fade we resync the main player's position to the
  /// overlay's and hand playback back to the main pipeline.
  Future<void> _startCrossfade({
    required int toIndex,
    required int durationSeconds,
  }) async {
    if (_crossfading) return;
    if (toIndex >= _queue.length) return;
    _crossfading = true;
    _crossfadeWatchdog?.cancel();

    final nextTrack = _queue[toIndex];
    final overlay = _crossfadePlayer;

    try {
      final url = await _yt.resolveAudioUrl(nextTrack.sourceVideoId);
      await overlay.setAudioSource(
        AudioSource.uri(Uri.parse(url)),
        preload: true,
      );
      await overlay.setVolume(0.0);
      await overlay.play();
    } catch (e) {
      _crossfading = false;
      errorEvents.add('Could not preload next track for crossfade: $e');
      _scheduleCrossfade();
      return;
    }

    // Loudness match: cap incoming and pad outgoing so a jarring-loud
    // next track doesn't slam over a mellow current one.
    final match = _loudnessMatchEnabled();
    final inPeak = match ? 0.92 : 1.0;
    final outPeak = match ? 1.05 : 1.0;

    final steps = (durationSeconds * 20).clamp(20, 240);
    final stepInterval =
        Duration(milliseconds: durationSeconds * 1000 ~/ steps);

    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      // Equal-power curve sounds smoother than a linear ramp.
      final outVol = (cos(t * pi / 2) * outPeak).clamp(0.0, 1.0);
      final inVol = (sin(t * pi / 2) * inPeak).clamp(0.0, 1.0);
      try {
        await _player.setVolume(outVol);
        await overlay.setVolume(inVol);
      } catch (_) {}
      await Future.delayed(stepInterval);
      if (!_crossfading) break;
    }

    // Hand playback back to the main player. During the fade the main
    // player may have auto-advanced from the outgoing track to the
    // incoming one at position 0 — sync it to where the overlay
    // actually is, then restore volume.
    try {
      final overlayPos = overlay.position;
      if (_player.currentIndex != toIndex) {
        await _player.seek(overlayPos, index: toIndex);
      } else {
        await _player.seek(overlayPos);
      }
      await _player.setVolume(1.0);
      await overlay.setVolume(0.0);
      await overlay.pause();
    } catch (e) {
      debugPrint('[Crossfade] handoff failed: $e');
    }

    _crossfading = false;
    _currentIndex = toIndex;
    mediaItem.add(nextTrack.toMediaItem());
    _scheduleCrossfade();
    unawaited(_ensureUpcomingResolved());
    unawaited(_maybeAppendRelated());
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
    final newValue = !shuffleMode.value;
    shuffleMode.add(newValue);
    if (newValue && _queue.isNotEmpty) {
      _rebuildShuffleOrder(_currentIndex);
    } else {
      _shuffleOrder = null;
    }
    // Native just_audio also supports shuffle via setShuffleModeEnabled +
    // shuffle order, but keeping shuffle logic in our layer for now
    // simplifies the concat-vs-queue index mapping.
  }

  Future<void> cycleRepeat() async {
    final modes = PlaybackRepeat.values;
    final next = modes[(repeatMode.value.index + 1) % modes.length];
    repeatMode.add(next);
    // Map to just_audio's built-in loop mode too so single-track
    // repeat works even without our watchdog code path.
    switch (next) {
      case PlaybackRepeat.off:
        await _player.setLoopMode(LoopMode.off);
        break;
      case PlaybackRepeat.all:
        await _player.setLoopMode(LoopMode.all);
        break;
      case PlaybackRepeat.one:
        await _player.setLoopMode(LoopMode.one);
        break;
    }
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
  Future<void> play() => _player.play();

  @override
  Future<void> pause() async {
    await _player.pause();
    _persistQueue();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    await _player.stop();
    if (_crossfadeLazy != null) await _crossfadeLazy!.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    // Ensure the next item is in the concat source (resolve if not).
    await _ensureUpcomingResolved();
    if (_currentIndex + 1 >= _queue.length) {
      await _maybeAppendRelated();
      await _ensureUpcomingResolved();
    }
    if (_currentIndex + 1 >= _concat.length) return;
    await _player.seekToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_currentIndex <= 0) return;
    await _player.seekToPrevious();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _queue.length) return;
    // If the concat doesn't yet have this index, resolve up to it.
    while (_concat.length <= index) {
      final idx = _concat.length;
      final src = await _makeSource(_queue[idx]);
      if (src != null) {
        await _concat.add(src);
      } else {
        _queue.removeAt(idx);
        queue.add(_queue.map((t) => t.toMediaItem()).toList());
        if (index >= _queue.length) return;
      }
    }
    await _player.seek(Duration.zero, index: index);
    await _player.play();
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    final track = _trackFromMediaItem(mediaItem);
    _queue.add(track);
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
    unawaited(_ensureUpcomingResolved());
  }

  Future<void> playNext(Track track) async {
    final insertAt = (_currentIndex + 1).clamp(0, _queue.length);
    _queue.insert(insertAt, track);
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
    // Insert a resolved source at the same position in the concat if
    // it's within the currently-materialised window.
    if (insertAt <= _concat.length) {
      final src = await _makeSource(track);
      if (src != null) {
        await _concat.insert(insertAt, src);
      }
    }
  }

  Future<void> startRadio(Track seed) async {
    await playWithAutoplay(seed);
  }

  /// Spotify-style Smart Shuffle: interleave the user's library with
  /// fresh related-track recommendations.
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
      final fresh = await _yt.related(seed.sourceVideoId, limit: 30);
      related.addAll(fresh);
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

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    if (index < _concat.length) {
      await _concat.removeAt(index);
    }
    if (index < _currentIndex) _currentIndex--;
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
  }

  // ---------------------------------------------------------------------
  //  Pre-warm hoist (browser → native audio background handoff)
  // ---------------------------------------------------------------------

  String? _warmedVideoId;

  Future<void> prepareForBackgroundHoist(Track track) async {
    if (_warmedVideoId == track.sourceVideoId) return;
    _warmedVideoId = track.sourceVideoId;
    try {
      final url = await _yt.resolveAudioUrl(track.sourceVideoId);
      if (_player.playing) return; // don't clobber active playback
      _queue
        ..clear()
        ..add(track);
      _currentIndex = 0;
      queue.add(_queue.map((t) => t.toMediaItem()).toList());
      mediaItem.add(track.toMediaItem());
      await _concat.clear();
      await _concat
          .add(AudioSource.uri(Uri.parse(url), tag: track.toMediaItem()));
      await _player.seek(Duration.zero, index: 0);
      await _player.setVolume(0.0);
    } catch (e) {
      debugPrint('[Hoist] warm failed: $e');
      _warmedVideoId = null;
    }
  }

  Future<void> resumeWarmedHoist({required Duration startAt}) async {
    if (_warmedVideoId == null) return;
    try {
      if (startAt > Duration.zero) await _player.seek(startAt);
      await _player.setVolume(1.0);
      await _player.play();
      unawaited(_maybeAppendRelated());
    } catch (e) {
      debugPrint('[Hoist] resume failed: $e');
    }
  }

  void clearWarmedHoist() {
    _warmedVideoId = null;
  }

  // ---------------------------------------------------------------------
  //  Public read-only state
  // ---------------------------------------------------------------------

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<bool> get playingStream => _player.playingStream;
  AudioPlayer get rawPlayer => _player;
  List<Track> get currentQueue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;

  bool get isStalled => false; // Legacy field; ConcatSource handles stalls natively.

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

  void _bindProgress() {
    _progressPosSub?.cancel();
    _progressDurSub?.cancel();
    _progressPlaySub?.cancel();

    Duration pos = _player.position;
    Duration? dur = _player.duration;
    bool playing = _player.playing;

    void emit() {
      _progressSubject.add(ProgressData(
        position: pos,
        duration: dur ?? Duration.zero,
        playing: playing,
      ));
    }

    _progressPosSub = _player.positionStream.listen((p) {
      pos = p;
      emit();
    });
    _progressDurSub = _player.durationStream.listen((d) {
      dur = d;
      emit();
    });
    _progressPlaySub = _player.playingStream.listen((p) {
      playing = p;
      emit();
    });
    emit();
  }

  Stream<ProgressData> get progressStream => _progressSubject.stream;

  Track? get currentTrack =>
      _currentIndex >= 0 && _currentIndex < _queue.length
          ? _queue[_currentIndex]
          : null;

  // ---------------------------------------------------------------------
  //  Internal
  // ---------------------------------------------------------------------

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;
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
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _currentIndex,
    ));
  }

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
