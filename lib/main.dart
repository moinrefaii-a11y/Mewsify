import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'data/models/track.dart';
import 'services/audio_handler.dart';

late MelodyAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Local storage for library, history, downloads.
  await Hive.initFlutter();
  Hive.registerAdapter(TrackAdapter());
  await Hive.openBox<Track>('favorites');
  await Hive.openBox<Track>('history');
  await Hive.openBox<Track>('queue');
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
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );

  runApp(const ProviderScope(child: MelodyApp()));
}
