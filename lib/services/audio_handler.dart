import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../data/models/track.dart';
import '../data/sources/youtube_source.dart';

/// Glues just_audio (the player) to audio_service (the OS-level
/// foreground service / lock-screen integration).
///
/// Uses **two AudioPlayer instances in alternation** so we can do a
/// real Apple-Music / Spotify-style audio crossfade:
///   - During the last N seconds of a track, the next track is
///     pre-loaded on the inactive player at volume 0 and starts
///     playing while the active track ramps down to 0.
///   - When the active track finishes the inactive player has already
///     ramped up to full volume; we then promote it to "primary".
class MelodyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  MelodyAudioHandler() {
    _player = _a;
    _init();
  }

  /// Primary player. The secondary one (`_b`) is only created the
  /// first time we actually need to crossfade — most users keep
  /// crossfade off, and an idle AudioPlayer still costs CPU + memory.
  late final AudioPlayer _a = AudioPlayer();
  AudioPlayer? _bLazy;
  AudioPlayer get _b => _bLazy ??= AudioPlayer();

  late AudioPlayer _player; // foreground player; UI listens to this
  AudioPlayer get _other => identical(_player, _a) ? _b : _a; // lazy-allocates _b

  /// Listener subscriptions on the active player. Re-bound after every
  /// crossfade swap so events keep flowing to audio_service / UI.
  StreamSubscription? _eventSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _indexSub;

  final YouTubeSource _yt = YouTubeSource();
  final List<Track> _queue = [];
  List<int>? _shuffleOrder;
  int _currentIndex = -1;

  // Reactive state surfaced to the UI.
  final BehaviorSubject<bool> shuffleMode = BehaviorSubject.seeded(false);
  final BehaviorSubject<PlaybackRepeat> repeatMode =
      BehaviorSubject.seeded(PlaybackRepeat.off);
  final BehaviorSubject<Duration?> sleepTimer = BehaviorSubject.seeded(null);

  /// Stream of player errors (network 403, source not found, etc.).
  final BehaviorSubject<String?> errorEvents = BehaviorSubject.seeded(null);

  bool _completionEnabled = true;

  Timer? _sleepTimerTask;
  Timer? _crossfadeWatchdog;
  bool _crossfading = false;

  Future<void> _init() async {
    _bindActiveListeners();

    // Restore the last queue from disk so reopening the app continues
    // where the user left off (paused at the last track + position).
    _restoreQueue();
  }

  /// Listens to the *currently active* player. Called once at startup
  /// and every time we promote the inactive player after a crossfade.
  void _bindActiveListeners() {
    _eventSub?.cancel();
    _stateSub?.cancel();
    _indexSub?.cancel();

    _bindProgress();

    _eventSub = _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) {
        // Mid-stream error (URL expired mid-play, network dropped, DRM).
        // Guard the auto-skip with `_advancing` so we don't stack up on
        // the resolve path's own retry logic — one failure, one skip.
        debugPrint('[Player] mid-stream error: $e');
        if (_advancing) return;
        _advancing = true;
        _completionEnabled = false;
        errorEvents.add('Playback error — skipping');
        Future.microtask(() async {
          try {
            await skipToNext();
          } catch (_) {}
          Future.delayed(const Duration(seconds: 1), () {
            _advancing = false;
          });
        });
      },
    );

    _stateSub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed &&
          _completionEnabled &&
          !_crossfading) {
        _onTrackCompleted();
      }
      if (state == ProcessingState.ready) {
        _completionEnabled = true;
      }
    });

    _indexSub = _player.currentIndexStream.listen((index) {
      if (index == null || _currentIndex >= _queue.length) return;
      mediaItem.add(_queue[_currentIndex].toMediaItem());
    });

    // When just_audio resolves the real duration of the current track,
    // rebroadcast the MediaItem with that duration. Bluetooth head units
    // (AVRCP) and Android Auto need a non-zero duration to display track
    // info — otherwise you get "No info provided" on the car screen.
    _durationSub?.cancel();
    _durationSub = _player.durationStream.listen((d) {
      if (d == null || d == Duration.zero) return;
      if (_currentIndex < 0 || _currentIndex >= _queue.length) return;
      final current = _queue[_currentIndex];
      // Update the queue entry so future reads (and lock screen "next")
      // carry the correct duration too.
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

  StreamSubscription? _durationSub;

  // --- Queue persistence ------------------------------------------------

  static const _queueBoxName = 'queue';

  Future<void> _restoreQueue() async {
    if (!Hive.isBoxOpen(_queueBoxName)) return;
    final box = Hive.box<Track>(_queueBoxName);
    if (box.isEmpty) return;
    final settings = Hive.box('settings');
    final savedIndex = settings.get('queueIndex', defaultValue: 0) as int;
    final savedPositionMs = settings.get('queuePositionMs', defaultValue: 0) as int;

    _queue
      ..clear()
      ..addAll(box.values);
    _currentIndex = savedIndex.clamp(0, _queue.length - 1);
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
    if (_currentIndex < _queue.length) {
      mediaItem.add(_queue[_currentIndex].toMediaItem());
    }

    // Resolve audio URL in the background so the app doesn't freeze
    // on the splash screen waiting for a network response.
    unawaited(_loadRestoredTrack(savedPositionMs));
  }

  Future<void> _loadRestoredTrack(int savedPositionMs) async {
    try {
      final track = _queue[_currentIndex];
      final url = await _yt.resolveAudioUrl(track.sourceVideoId);
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(url)),
        initialPosition: Duration(milliseconds: savedPositionMs),
      );
    } catch (_) {
      // Network unavailable at startup — user can tap play later.
    }
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

  // --- Queue setup ------------------------------------------------------

  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    _queue
      ..clear()
      ..addAll(tracks);
    _shuffleOrder = null;
    if (shuffleMode.value) _rebuildShuffleOrder(startIndex);
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
    _currentIndex = startIndex.clamp(0, _queue.length - 1);
    await _playIndex(_currentIndex);
    await _persistQueue();
  }

  /// Pre-warm the native audio pipeline for a specific video without
  /// actually playing it. Used by the Browse tab: as soon as the user
  /// lands on a /watch page we load the audio source into the player
  /// muted + paused. If the user then backgrounds the app, we can
  /// resume with just `play()` — no async URL resolution racing the
  /// OS's foreground-service-from-background restrictions.
  ///
  /// Called at most once per videoId; subsequent calls short-circuit
  /// if the same track is already warmed.
  String? _warmedVideoId;
  Future<void> prepareForBackgroundHoist(Track track) async {
    if (_warmedVideoId == track.sourceVideoId) return;
    _warmedVideoId = track.sourceVideoId;
    try {
      final url = await _yt.resolveAudioUrl(track.sourceVideoId);
      // We only warm on the primary player if it's *not* currently
      // playing something else — never interrupt an existing session.
      if (_player.playing) {
        debugPrint('[Hoist] skipping warm — primary is already playing');
        return;
      }
      _queue
        ..clear()
        ..add(track);
      _currentIndex = 0;
      queue.add(_queue.map((t) => t.toMediaItem()).toList());
      mediaItem.add(track.toMediaItem());
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(url)),
        preload: true,
      );
      await _player.setVolume(0);
      // Explicitly paused; we'll flip to playing when the app goes
      // background.
      debugPrint('[Hoist] warmed native pipeline for ${track.title}');
    } catch (e) {
      debugPrint('[Hoist] warm failed: $e');
      _warmedVideoId = null;
    }
  }

  /// Flip the pre-warmed audio into audible playback. Synchronous fast
  /// path used on `AppLifecycleState.inactive` when the user
  /// backgrounds the app with the Browser tab still on a /watch page.
  Future<void> resumeWarmedHoist({
    required Duration startAt,
  }) async {
    if (_warmedVideoId == null) return;
    try {
      if (startAt > Duration.zero) {
        await _player.seek(startAt);
      }
      await _player.setVolume(1.0);
      await _player.play();
      _scheduleCrossfade();
      // Kick related-tracks fetch off in the background so autoplay
      // has a queue to move into.
      unawaited(_appendRelatedToQueue(_warmedVideoId!));
      debugPrint('[Hoist] resumed warmed hoist at ${startAt.inSeconds}s');
    } catch (e) {
      debugPrint('[Hoist] resume failed: $e');
    }
  }

  /// Reset the warmed marker so a different video can be warmed next.
  void clearWarmedHoist() {
    _warmedVideoId = null;
  }

  Future<void> playWithAutoplay(Track seed) async {
    _queue
      ..clear()
      ..add(seed);
    _currentIndex = 0;
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
    await _playIndex(0);
    await _persistQueue();
    // Await the related-tracks fetch so the queue is populated *before*
    // the current track can end. Previously we fired-and-forgot which
    // meant Next / auto-advance could be a no-op if the fetch hadn't
    // returned in time.
    await _appendRelatedToQueue(seed.sourceVideoId);
  }

  Future<void> _playIndex(int index, [int retryCount = 0]) async {
    if (index < 0 || index >= _queue.length) return;
    _currentIndex = index;
    final track = _queue[index];
    mediaItem.add(track.toMediaItem());

    try {
      final url = await _yt.resolveAudioUrl(track.sourceVideoId);
      _completionEnabled = true;
      // Passing the search-result duration as a fallback lets just_audio
      // populate `duration` even when the stream itself doesn't ship
      // one (some Music tracks do this). Without it the crossfade
      // watchdog silently gives up because `_player.duration` is null.
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(url)),
        preload: true,
      );
      await _player.setVolume(1.0);
      await _player.play();
      _scheduleCrossfade();
      _armDurationFallback(track);
    } catch (e) {
      if (retryCount < 1) {
        await Future.delayed(const Duration(milliseconds: 800));
        return _playIndex(index, retryCount + 1);
      }
      // Auto-recover — advance to the next track instead of leaving the
      // user stuck. Only bail entirely if there *is* no next track.
      debugPrint('[Player] resolve failed for ${track.title}: $e');
      errorEvents.add('Skipped "${track.title}" — could not stream');
      final next = _peekNextIndex();
      if (next != null && next != index) {
        await _playIndex(next);
      } else {
        _completionEnabled = false;
      }
    }
  }

  // --- Crossfade --------------------------------------------------------

  /// Watchdog running every 250 ms while a track is playing.
  ///
  /// Two jobs, both critical:
  ///   1. **Crossfade trigger** — if crossfade is on and a next track
  ///      exists, kick off the fade the moment we enter the window.
  ///   2. **End-of-track fallback** — YouTube's timed URLs sometimes
  ///      hang at the end of playback without emitting
  ///      `ProcessingState.completed`. When we're within 300 ms of the
  ///      duration and no completion event has fired, we manually
  ///      trigger the same handler so autoplay never stalls.
  void _scheduleCrossfade() {
    _crossfadeWatchdog?.cancel();
    _crossfadeWatchdog =
        Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_crossfading) return;
      if (!_player.playing) {
        // Reset stall bookkeeping when we're intentionally paused so
        // resuming after a long pause doesn't immediately count as a
        // stall.
        _stallTicks = 0;
        _lastKnownPosMs = _player.position.inMilliseconds;
        return;
      }

      final pos = _player.position;

      // ---- 1) Stall detection (duration-independent) ----------------
      // MUST run before any duration-dependent early-return. YouTube
      // Music tracks often don't publish a stream duration, which
      // previously blocked the watchdog from ever reaching the stall
      // check. Result: audio would freeze silently mid-song, UI still
      // showed "playing", and nothing would auto-advance.
      if (_lastKnownPosMs == pos.inMilliseconds) {
        _stallTicks++;
        // 3 s of no forward progress while the player claims to be
        // playing = stalled. Skip aggressively so the user isn't
        // staring at a silent "playing" state.
        if (_stallTicks >= 12 && !_advancing) {
          _advancing = true;
          _stallTicks = 0;
          debugPrint('[Watchdog] stall detected at ${pos.inSeconds}s — skipping');
          errorEvents.add('Playback stalled — skipping');
          try {
            // Pause first so the UI reflects the transition instead of
            // continuing to show a "playing" state during the resolve
            // for the next track.
            await _player.pause();
          } catch (_) {}
          try {
            await skipToNext();
          } catch (_) {}
          Future.delayed(const Duration(seconds: 1), () {
            _advancing = false;
          });
          return;
        }
      } else {
        _lastKnownPosMs = pos.inMilliseconds;
        _stallTicks = 0;
      }

      // ---- 2) Duration-dependent checks below -----------------------
      final dur = _effectiveDuration();
      if (dur == null || dur.inMilliseconds < 1000) return;

      final remaining = dur - pos;
      final rmMs = remaining.inMilliseconds;
      final seconds = _crossfadeSeconds();

      // Proactive up-next refill: as soon as we cross the "last 30 s"
      // threshold and don't have a next slot lined up, fire off a
      // related-tracks fetch. Without this the fetch races the natural
      // end of the track and autoplay stalls on the last song.
      if (rmMs <= 30000 && !_refillInFlight && _peekNextIndex() == null) {
        _refillInFlight = true;
        Future(() async {
          try {
            if (_currentIndex >= 0 && _currentIndex < _queue.length) {
              await _appendRelatedToQueue(_queue[_currentIndex].sourceVideoId);
            }
          } finally {
            _refillInFlight = false;
          }
        });
      }

      // 3) Crossfade window.
      if (seconds > 0 && rmMs > 200 && rmMs <= seconds * 1000 + 300) {
        final next = _peekNextIndex();
        if (next != null) {
          debugPrint(
              '[Watchdog] crossfade triggering with ${rmMs}ms remaining');
          await _startCrossfade(toIndex: next, durationSeconds: seconds);
          return;
        }
      }

      // 4) Track-end fallback. Ignores `_completionEnabled` because a
      // stuck-false flag was the exact bug that stranded users at end
      // of track when just_audio ate the `completed` event.
      if (rmMs <= 300 && rmMs > -3000 && !_advancing) {
        _advancing = true;
        _completionEnabled = false;
        debugPrint('[Watchdog] forcing track end at ${rmMs}ms remaining');
        try {
          await _onTrackCompleted();
        } finally {
          Future.delayed(const Duration(seconds: 1), () {
            _advancing = false;
          });
        }
      }
    });
  }

  int _lastKnownPosMs = 0;
  int _stallTicks = 0;

  /// True while the player claims to be playing but position hasn't
  /// advanced in > 750 ms — a real-time signal that the stream is
  /// stalled / buffering. Consumed by the mini-player and Now Playing
  /// UI to swap the "playing" animation for a spinner so the user
  /// isn't lied to during a network hiccup.
  bool get isStalled => _stallTicks >= 3 && _player.playing;

  bool _advancing = false;
  bool _refillInFlight = false;

  /// Best-effort duration for the current track. Prefers just_audio's
  /// resolved duration; falls back to the search-result duration on the
  /// Track model for the small subset of streams that don't publish
  /// one. Used by the watchdog so crossfade + end-of-track detection
  /// stay alive even when `_player.duration` is null.
  Duration? _effectiveDuration() {
    final playerDur = _player.duration;
    if (playerDur != null && playerDur > Duration.zero) return playerDur;
    if (_currentIndex >= 0 && _currentIndex < _queue.length) {
      final track = _queue[_currentIndex];
      if (track.duration > Duration.zero) return track.duration;
    }
    return null;
  }

  /// If just_audio hasn't resolved a duration within 3 seconds of us
  /// starting a track, rebroadcast the MediaItem with the search-result
  /// duration so car head units + Android Auto still show track info.
  void _armDurationFallback(Track track) {
    if (track.duration == Duration.zero) return;
    Future.delayed(const Duration(seconds: 3), () {
      if (_currentIndex < 0 || _currentIndex >= _queue.length) return;
      if (_queue[_currentIndex] != track) return;
      final resolved = _player.duration;
      if (resolved != null && resolved > Duration.zero) return;
      debugPrint(
          '[Player] duration fallback: using ${track.duration}');
      mediaItem.add(track.toMediaItem());
    });
  }

  int _crossfadeSeconds() {
    if (!Hive.isBoxOpen('settings')) return 5;
    final box = Hive.box('settings');
    // If the user has never touched the Crossfade slider we default to
    // 5 s. `containsKey` (not Hive's `defaultValue`) makes upgraders
    // from < v0.4 fall through to the new default too.
    final base = box.containsKey('crossfadeSeconds')
        ? (box.get('crossfadeSeconds') as int).clamp(0, 12)
        : 5;
    if (base == 0) return 0;

    // Auto-duration mode: shorten the fade for short tracks so we
    // don't blend across, say, a 60 s snippet's chorus. Longer tracks
    // get the full user-configured length.
    final auto = box.get('crossfadeAuto', defaultValue: false) as bool;
    if (auto &&
        _currentIndex >= 0 &&
        _currentIndex < _queue.length) {
      final dur = _queue[_currentIndex].duration;
      if (dur.inSeconds > 0) {
        if (dur.inSeconds < 90) return 2;
        if (dur.inSeconds < 150) return 3;
        if (dur.inSeconds < 240) return (base * 0.7).round().clamp(2, base);
      }
    }
    return base;
  }

  bool _loudnessMatchEnabled() {
    if (!Hive.isBoxOpen('settings')) return true;
    return Hive.box('settings')
        .get('crossfadeLoudnessMatch', defaultValue: true) as bool;
  }

  int? _peekNextIndex() {
    if (_queue.isEmpty) return null;
    if (shuffleMode.value && _shuffleOrder != null) {
      final pos = _shuffleOrder!.indexOf(_currentIndex);
      if (pos < 0 || pos + 1 >= _shuffleOrder!.length) return null;
      return _shuffleOrder![pos + 1];
    }
    return _currentIndex + 1 < _queue.length ? _currentIndex + 1 : null;
  }

  /// Pre-loads `_queue[toIndex]` on the inactive player and animates a
  /// volume crossover. After the crossover, the inactive player becomes
  /// the new "primary".
  Future<void> _startCrossfade({
    required int toIndex,
    required int durationSeconds,
  }) async {
    if (_crossfading) return;
    _crossfading = true;
    _completionEnabled = false;
    _crossfadeWatchdog?.cancel();

    final fadeOut = _player;
    final fadeIn = _other;
    final nextTrack = _queue[toIndex];

    try {
      final url = await _yt.resolveAudioUrl(nextTrack.sourceVideoId);
      await fadeIn.setAudioSource(AudioSource.uri(Uri.parse(url)));
      await fadeIn.setVolume(0.0);
      await fadeIn.play();
    } catch (e) {
      // Failed to preload — abort crossfade gracefully.
      _crossfading = false;
      _completionEnabled = true;
      errorEvents.add('Could not preload next track: $e');
      _scheduleCrossfade();
      return;
    }

    // Peak volumes for each side of the fade. When "Match loudness" is
    // on we cap the incoming track at 0.92 and pad the outgoing side
    // to 1.08 (via a soft ramp) so a jarring-loud next track doesn't
    // slam over a mellow current one. It's a coarse approximation of
    // real replay-gain / LUFS matching but works well enough that the
    // seams don't feel like a "volume click".
    final match = _loudnessMatchEnabled();
    final inPeak = match ? 0.92 : 1.0;
    final outPeak = match ? 1.05 : 1.0;

    final steps = (durationSeconds * 20).clamp(20, 240); // 20 fps
    final stepInterval = Duration(milliseconds: durationSeconds * 1000 ~/ steps);

    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      // Equal-power crossfade curve sounds smoother than a linear ramp.
      final outVol = (cos(t * pi / 2) * outPeak).clamp(0.0, 1.0);
      final inVol = (sin(t * pi / 2) * inPeak).clamp(0.0, 1.0);
      await fadeOut.setVolume(outVol);
      await fadeIn.setVolume(inVol);
      await Future.delayed(stepInterval);
      if (!_crossfading) break; // user skipped or stopped
    }
    // After the fade, restore incoming to full volume so subsequent
    // playback isn't ceiling-limited.
    try {
      await fadeIn.setVolume(1.0);
    } catch (_) {}

    // Promote the fade-in player to "primary".
    await fadeOut.pause();
    await fadeOut.seek(Duration.zero);
    _player = fadeIn;
    _currentIndex = toIndex;
    _bindActiveListeners();
    mediaItem.add(nextTrack.toMediaItem());
    _crossfading = false;
    _completionEnabled = true;
    _scheduleCrossfade();
    await _persistQueue();
  }

  // --- Track-end handling ----------------------------------------------

  Future<void> _onTrackCompleted() async {
    final mode = repeatMode.value;
    if (mode == PlaybackRepeat.one) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    // Try to extend the queue with related tracks if we don't already
    // have a next slot lined up. This makes autoplay work exactly like
    // YouTube / YouTube Music — the "up next" is inferred from what's
    // playing now, not a fixed playlist.
    if (_peekNextIndex() == null && _queue.isNotEmpty) {
      await _appendRelatedToQueue(_queue.last.sourceVideoId);
    }
    final hasNext = _peekNextIndex() != null;
    if (hasNext) {
      await skipToNext();
    } else if (mode == PlaybackRepeat.all) {
      await skipToQueueItem(0);
    }
  }

  Future<void> _appendRelatedToQueue(String videoId) async {
    List<Track> pool = const [];
    try {
      pool = await _yt.related(videoId, limit: 20);
    } catch (e) {
      debugPrint('[Autoplay] related() failed: $e');
    }
    // If related came back empty (happens sometimes when YT's PO token
    // gate flips), fall back to a keyword search on the current track's
    // artist so autoplay still gives the user something to play.
    if (pool.isEmpty &&
        _currentIndex >= 0 &&
        _currentIndex < _queue.length) {
      final current = _queue[_currentIndex];
      try {
        pool = await _yt.search(current.artist, limit: 20);
      } catch (e) {
        debugPrint('[Autoplay] fallback search failed: $e');
      }
    }
    // Filter with a graceful fallback: try aggressive first, then just
    // duration, and finally the unfiltered pool. Bad filter output is
    // way worse than "some autoplay picks are compilations" — a filter
    // that rejects everything and stalls playback is the worst outcome.
    final notInQueue = pool.where((t) => !_queue.contains(t)).toList();
    var picks = notInQueue.where(_looksLikeASong).toList();
    if (picks.isEmpty) {
      // Just duration filter — drops multi-hour mixes but keeps
      // legitimate long titles like "Song Name (Extended Mix)".
      picks = notInQueue.where(_reasonableDuration).toList();
    }
    if (picks.isEmpty) picks = notInQueue; // last resort
    if (picks.isEmpty) return;
    debugPrint('[Autoplay] appending ${picks.take(10).length} related tracks');
    _queue.addAll(picks.take(10));
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
  }

  /// Heuristic filter for autoplay picks. First-pass filter that
  /// rejects on both duration + title. If it kills the entire pool we
  /// fall back to just duration, so autoplay never fully stalls on
  /// filter output.
  bool _looksLikeASong(Track t) {
    if (!_reasonableDuration(t)) return false;
    final title = t.title.toLowerCase();
    // Only reject titles with *strong* signals of a compilation /
    // long-form upload. Generic words like "mix" alone are too
    // common in legit remix titles ("Extended Mix", "Radio Mix").
    const blockers = [
      'compilation',
      'full album',
      'nonstop',
      'jukebox',
      '1 hour',
      '2 hour',
      '3 hour',
      '10 hour',
      'megamix',
      'top 100',
      'top 50',
      'playlist',
      'lo-fi mix',
      'chill mix',
      'workout mix',
    ];
    for (final b in blockers) {
      if (title.contains(b)) return false;
    }
    return true;
  }

  /// Loose duration filter (45 s – 15 min). Kept separate so it can be
  /// used as a fallback when the strict `_looksLikeASong` filter would
  /// have rejected everything.
  bool _reasonableDuration(Track t) {
    final secs = t.duration.inSeconds;
    if (secs == 0) return true; // unknown → give it the benefit of the doubt
    if (secs > 15 * 60) return false;
    if (secs < 45) return false;
    return true;
  }

  // --- Shuffle / repeat / sleep ----------------------------------------

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
  }

  Future<void> cycleRepeat() async {
    final modes = PlaybackRepeat.values;
    final next = modes[(repeatMode.value.index + 1) % modes.length];
    repeatMode.add(next);
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

  // --- Index navigation -------------------------------------------------

  int? _previousIndex() {
    if (_queue.isEmpty) return null;
    if (shuffleMode.value && _shuffleOrder != null) {
      final pos = _shuffleOrder!.indexOf(_currentIndex);
      if (pos <= 0) return null;
      return _shuffleOrder![pos - 1];
    }
    return _currentIndex - 1 >= 0 ? _currentIndex - 1 : null;
  }

  // --- audio_service handler overrides ----------------------------------

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() async {
    await _player.pause();
    await _persistQueue();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    await _player.stop();
    if (_bLazy != null) await _bLazy!.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    var next = _peekNextIndex();
    // If the user just kicked off playWithAutoplay, the related-tracks
    // background fetch may not have completed yet. When that happens
    // we eagerly fill the queue here so the lock-screen Next button
    // never becomes a no-op.
    if (next == null && _queue.isNotEmpty) {
      await _appendRelatedToQueue(_queue.last.sourceVideoId);
      next = _peekNextIndex();
    }
    if (next != null) await _playIndex(next);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    final prev = _previousIndex();
    if (prev != null) await _playIndex(prev);
  }

  @override
  Future<void> skipToQueueItem(int index) async => _playIndex(index);

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    final track = _trackFromMediaItem(mediaItem);
    _queue.add(track);
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
  }

  Future<void> playNext(Track track) async {
    final insertAt = (_currentIndex + 1).clamp(0, _queue.length);
    _queue.insert(insertAt, track);
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
  }

  Future<void> startRadio(Track seed) async {
    _queue
      ..clear()
      ..add(seed);
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
    _currentIndex = 0;
    await _playIndex(0);
    await _appendRelatedToQueue(seed.sourceVideoId);
  }

  /// Spotify-style "Smart Shuffle" — interleave the user's library with
  /// fresh related-track recommendations. Half familiar, half new.
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

    // Pull related videos for fresh discovery.
    final related = <Track>[];
    try {
      final fresh = await _yt.related(seed.sourceVideoId, limit: 30);
      related.addAll(fresh);
    } catch (_) {}

    // Interleave 1 known + 1 new + 1 known + 1 new...
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
    if (index < _currentIndex) _currentIndex--;
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
  }

  // --- Public read-only state -------------------------------------------

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<bool> get playingStream => _player.playingStream;
  AudioPlayer get rawPlayer => _player;
  List<Track> get currentQueue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;

  /// Progress stream emitted by whichever player is currently active.
  /// We use the broadcast subject below so a swap (post-crossfade)
  /// rebinds without leaking stale positions from the inactive player.
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
      _currentIndex >= 0 && _currentIndex < _queue.length ? _queue[_currentIndex] : null;

  // --- Private helpers --------------------------------------------------

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
