import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Thin wrapper around the `melody/pip` method channel exposed by
/// MainActivity.kt. Lets Flutter tell the host activity:
///   - "video mode is on" → auto-enter PiP when user presses Home
///   - "give me PiP right now"
class PipService {
  PipService._();
  static final PipService instance = PipService._();

  static const _channel = MethodChannel('melody/pip');

  bool _videoMode = false;

  Future<void> setVideoMode(bool on) async {
    if (!Platform.isAndroid) return;
    if (_videoMode == on) return;
    _videoMode = on;
    try {
      await _channel.invokeMethod('setVideoMode', {'on': on});
    } catch (_) {
      // No-op: channel may not be wired in some build variants.
    }
  }

  Future<bool> enterPip() async {
    if (!Platform.isAndroid) return false;
    try {
      final v = await _channel.invokeMethod<bool>('enterPip');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isSupported() async {
    if (!Platform.isAndroid) return false;
    try {
      final v = await _channel.invokeMethod<bool>('isPipSupported');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }
}
