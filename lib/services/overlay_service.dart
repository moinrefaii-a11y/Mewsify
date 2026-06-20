import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'audio_handler.dart';

/// Bridges the main app and the floating overlay window.
///
/// On Android only:
///  - Requests SYSTEM_ALERT_WINDOW if not granted
///  - Shows / hides the overlay
///  - Pushes track + playing state into the overlay
///  - Receives action commands ("play", "pause", "open_app", "close")
///    sent by the overlay UI and routes them back to the audio handler
class OverlayService {
  OverlayService(this._audio);

  final MelodyAudioHandler _audio;
  StreamSubscription<dynamic>? _commandSub;
  StreamSubscription? _trackSub;
  StreamSubscription? _playingSub;

  bool get isAndroid => Platform.isAndroid;

  /// True when the system has granted us SYSTEM_ALERT_WINDOW.
  Future<bool> hasPermission() async {
    if (!isAndroid) return false;
    return await FlutterOverlayWindow.isPermissionGranted();
  }

  Future<bool> requestPermission() async {
    if (!isAndroid) return false;
    return await FlutterOverlayWindow.requestPermission() ?? false;
  }

  Future<void> show() async {
    if (!isAndroid) return;
    if (!await hasPermission()) {
      final granted = await requestPermission();
      if (granted != true) return;
    }
    if (await FlutterOverlayWindow.isActive()) return;

    await FlutterOverlayWindow.showOverlay(
      enableDrag: true,
      overlayTitle: 'MewSify',
      overlayContent: 'Now playing',
      flag: OverlayFlag.defaultFlag,
      visibility: NotificationVisibility.visibilityPublic,
      positionGravity: PositionGravity.auto,
      height: 100,
      width: WindowSize.matchParent,
    );

    _wireBridges();
    _pushCurrentState();
  }

  Future<void> hide() async {
    if (!isAndroid) return;
    await FlutterOverlayWindow.closeOverlay();
    _commandSub?.cancel();
    _trackSub?.cancel();
    _playingSub?.cancel();
  }

  void _wireBridges() {
    // Forward actions sent from the overlay back to the audio handler.
    _commandSub?.cancel();
    _commandSub = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is! Map) return;
      switch (event['action']) {
        case 'play':
          _audio.play();
          break;
        case 'pause':
          _audio.pause();
          break;
        case 'open_app':
          // The overlay shouldn't kill itself here; the host activity
          // will be brought forward by the system as the user taps.
          break;
        case 'close':
          hide();
          break;
      }
    });

    // Push state changes into the overlay.
    _trackSub?.cancel();
    _trackSub = _audio.mediaItem.listen((_) => _pushCurrentState());
    _playingSub?.cancel();
    _playingSub = _audio.playingStream.listen((_) => _pushCurrentState());
  }

  Future<void> _pushCurrentState() async {
    if (!isAndroid) return;
    if (!await FlutterOverlayWindow.isActive()) return;
    final t = _audio.currentTrack;
    await FlutterOverlayWindow.shareData({
      'title': t?.title ?? 'MewSify',
      'artist': t?.artist ?? '',
      'playing': _audio.rawPlayer.playing,
    });
  }
}
