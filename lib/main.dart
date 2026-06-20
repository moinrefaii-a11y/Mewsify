import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'dart:async';

import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'app.dart';
import 'data/models/playlist.dart';
import 'data/models/track.dart';
import 'data/sources/youtube_source.dart';
import 'services/audio_handler.dart';
import 'services/deep_link_service.dart';

late MelodyAudioHandler audioHandler;

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // Hold the native splash until our Flutter splash overlay takes over.
  // Released in lib/features/splash/splash_overlay.dart's first frame.
  FlutterNativeSplash.preserve(widgetsBinding: binding);

  // Local storage for library, history, downloads.
  await Hive.initFlutter();
  Hive.registerAdapter(TrackAdapter());
  Hive.registerAdapter(PlaylistAdapter());
  await Hive.openBox<Track>('favorites');
  await Hive.openBox<Track>('history');
  await Hive.openBox<Track>('queue');
  await Hive.openBox<Playlist>('playlists');
  await Hive.openBox<String>('recent_searches');
  await Hive.openBox('settings');

  // Background audio service. This sets up the foreground service on Android
  // and the audio session on iOS so playback survives backgrounding and
  // surfaces on the lock screen / notification shade.
  audioHandler = await AudioService.init(
    builder: () => MelodyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.mewsify.audio',
      androidNotificationChannelName: 'MewSify Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'drawable/ic_notification',
    ),
  );

  // Listen for incoming YouTube / mewsify:// links so tapping a shared
  // link from elsewhere opens the right track in the app.
  unawaited(DeepLinkService(audioHandler, YouTubeSource()).start());

  runApp(const ProviderScope(child: MelodyApp()));
}
