import 'dart:async';
import 'dart:math';

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

  /// Two AudioPlayer instances used in alternation for the two-player
  /// crossfade. No audio pipeline / effects — keeps the player rock-
  /// solid across all Android OEMs.
  late final AudioPlayer _a = AudioPlayer();
  late final AudioPlayer _b = AudioPlayer();

  late AudioPlayer _player; // foreground player; UI listens to this
  AudioPlayer get _other => identical(_player, _a) ? _b : _a;

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

    _eventSub = _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) {
        _completionEnabled = false;
        errorEvents.add('Could not play: $e');
      },
    );

    _stateSub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && _completionEnabled && !_crossfading) {
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
  }

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

    try {
      final track = _queue[_currentIndex];
      final url = await _yt.resolveAudioUrl(track.sourceVideoId);
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(url)),
        initialPosition: Duration(milliseconds: savedPositionMs),
      );
    } catch (_) {
      // ignore
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

  Future<void> playWithAutoplay(Track seed) async {
    _queue
      ..clear()
      ..add(seed);
    _currentIndex = 0;
    queue.add(_queue.map((t) => t.toMediaItem()).toList());
    await _playIndex(0);
    await _persistQueue();
    _appendRelatedToQueue(seed.sourceVideoId);
  }

  Future<void> _playIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _currentIndex = index;
    final track = _queue[index];
    mediaItem.add(track.toMediaItem());

    try {
      final url = await _yt.resolveAudioUrl(track.sourceVideoId);
      _completionEnabled = true;
      await _player.setAudioSource(AudioSource.uri(Uri.parse(url)));
      await _player.setVolume(1.0);
      await _player.play();
      _scheduleCrossfade();
    } catch (e) {
      _completionEnabled = false;
      errorEvents.add('Could not load track: $e');
    }
  }

  // --- Crossfade --------------------------------------------------------

  /// Watchdog: every second, check if we're inside the crossfade window
  /// of the currently-playing track. If so, kick off the overlap.
  void _scheduleCrossfade() {
    _crossfadeWatchdog?.cancel();
    final seconds = _crossfadeSeconds();
    if (seconds <= 0) return;
    _crossfadeWatchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_crossfading) return;
      final dur = _player.duration;
      final pos = _player.position;
      if (dur == null || dur == Duration.zero) return;
      final remaining = dur - pos;
      if (remaining.inMilliseconds <= seconds * 1000 + 500 &&
          remaining.inMilliseconds > 0) {
        final next = _peekNextIndex();
        if (next == null) return;
        _startCrossfade(toIndex: next, durationSeconds: seconds);
      }
    });
  }

  int _crossfadeSeconds() {
    if (!Hive.isBoxOpen('settings')) return 0;
    return (Hive.box('settings').get('crossfadeSeconds', defaultValue: 0) as int)
        .clamp(0, 12);
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

    final steps = (durationSeconds * 20).clamp(20, 240); // 20 fps
    final stepInterval = Duration(milliseconds: durationSeconds * 1000 ~/ steps);

    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      // Equal-power crossfade curve sounds smoother than a linear ramp.
      final outVol = (cos(t * pi / 2)).clamp(0.0, 1.0);
      final inVol = (sin(t * pi / 2)).clamp(0.0, 1.0);
      await fadeOut.setVolume(outVol);
      await fadeIn.setVolume(inVol);
      await Future.delayed(stepInterval);
      if (!_crossfading) break; // user skipped or stopped
    }

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

  void _onTrackCompleted() async {
    final mode = repeatMode.value;
    if (mode == PlaybackRepeat.one) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    final hasNext = _peekNextIndex() != null;
    if (hasNext) {
      await skipToNext();
    } else if (mode == PlaybackRepeat.all) {
      await skipToQueueItem(0);
    }
  }

  Future<void> _appendRelatedToQueue(String videoId) async {
    try {
      final related = await _yt.related(videoId, limit: 10);
      final filtered = related.where((t) => !_queue.contains(t)).toList();
      if (filtered.isEmpty) return;
      _queue.addAll(filtered);
      queue.add(_queue.map((t) => t.toMediaItem()).toList());
    } catch (_) {
      // Ignore related fetch failures.
    }
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
    await _other.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    final next = _peekNextIndex();
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

  Stream<Duration> get positionStream => _a.positionStream;
  Stream<Duration?> get durationStream => _a.durationStream;
  Stream<bool> get playingStream => _a.playingStream;
  AudioPlayer get rawPlayer => _player;
  List<Track> get currentQueue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;

  /// Combined progress stream that always reflects the *active* player
  /// even after a crossfade swap.
  Stream<ProgressData> get progressStream {
    return Rx.combineLatest3<Duration, Duration?, bool, ProgressData>(
      // We can't statically subscribe to "the currently active player"
      // since `_player` is mutable, so we emit a stream that sources
      // from both players merged. The active player's events dominate
      // because the inactive one is paused or muted.
      Rx.merge([_a.positionStream, _b.positionStream]),
      Rx.merge([_a.durationStream, _b.durationStream]),
      Rx.merge([_a.playingStream, _b.playingStream]),
      (pos, dur, playing) => ProgressData(
        position: pos,
        duration: dur ?? Duration.zero,
        playing: playing,
      ),
    );
  }

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
