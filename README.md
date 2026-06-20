# Melody

A YouTube-powered music streamer for Android and iOS, built with Flutter. Mirrors the architecture and feature set of YMusic, NewPipe, ViMusic, Demus, and Video Lite.

## Features

**Playback**
- Search YouTube and play any track (via `youtube_explode_dart` InnerTube extractor)
- True background playback with lock-screen controls + notification (Android foreground service + iOS audio session)
- Auto-advancing queue with prev/next, shuffle, and repeat (off/all/one)
- Auto-queue from related videos when the current queue ends (toggleable)
- Sleep timer with presets (5m / 10m / 15m / 30m / 45m / 1h / 2h)
- Per-band equalizer + loudness boost (Android)

**Discovery**
- Trending music feed on the home tab
- Live search with debounce
- Embedded YouTube browser tab — Demus / Video Lite style — that lets you browse `m.youtube.com` natively and intercept tapped videos into the queue

**Now Playing**
- Full-screen player with artwork, scrubber, transport, queue, lyrics
- Persistent mini-player above the bottom nav across all tabs
- Lyrics fetched from the free [lyrics.ovh API](https://lyricsovh.docs.apiary.io/)
- Up-next queue with reorder + remove
- Track menu with favorite, add to queue, play next, share

**Library**
- Favorites + listening history persisted with Hive
- Reactive UI updates when items are added/removed

**Floating popup (Android only)**
- YMusic-style overlay window over other apps using `flutter_overlay_window`
- Live track info + play/pause + close, draggable

**Settings**
- Sleep timer
- Equalizer
- Auto-queue toggle
- Floating popup launcher
- Clear history

## Architecture

```
UI (Riverpod + Flutter widgets)
    │
    ├── HomeScreen, SearchScreen, BrowserScreen,
    │   PlayerScreen, LibraryScreen, SettingsScreen
    │
Services
    │
    ├── MelodyAudioHandler  ── audio_service + just_audio + AudioPipeline (EQ)
    │       └── on play()   ── YouTubeSource.resolveAudioUrl(videoId)
    │
    ├── OverlayService      ── flutter_overlay_window bridge (Android)
    │
Data
    │
    ├── YouTubeSource       ── youtube_explode_dart (InnerTube)
    ├── LyricsSource        ── lyrics.ovh
    ├── LibraryRepository   ── Hive (favorites, history)
    └── Track model         ── universal playback unit
```

## Running

You need Flutter 3.19+. If you don't have it:
```bash
brew install --cask flutter
flutter doctor
```

In this directory:
```bash
flutter pub get
```

### Android
```bash
# List devices / emulators
flutter devices

# Spin up an emulator if needed
flutter emulators
flutter emulators --launch Pixel_7_API_34

# Run
flutter run -d <android_device_id>

# Sideload APK
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

### iOS
You need a Mac with Xcode. A free Apple Developer account is enough for 7-day device installs.
```bash
cd ios && pod install && cd ..
flutter run -d <ios_device_id>
```

Or open `ios/Runner.xcworkspace` in Xcode, set your team in **Signing & Capabilities**, and run.

### Why not Chrome?
The app uses Android foreground services, iOS audio session, the WKWebView/Android WebView, and overlay windows — none of which exist in the browser. It also needs to play YouTube CDN streams, which are CORS-blocked in browsers. Use a real device or emulator.

## File map

| Path | Purpose |
|---|---|
| `lib/main.dart` | App entry + Hive + AudioService bootstrap |
| `lib/app.dart` | MaterialApp + theme + root |
| `lib/core/theme.dart` | Material 3 dark theme |
| `lib/core/providers.dart` | Riverpod providers (DI) |
| `lib/data/models/track.dart` | Track model + Hive adapter |
| `lib/data/sources/youtube_source.dart` | InnerTube extractor |
| `lib/data/sources/lyrics_source.dart` | lyrics.ovh client |
| `lib/data/repositories/library_repository.dart` | Favorites + history |
| `lib/services/audio_handler.dart` | Background audio + queue + EQ + shuffle/repeat/sleep |
| `lib/services/overlay_service.dart` | Floating popup bridge (Android) |
| `lib/features/shell/main_shell.dart` | Bottom nav + persistent mini player |
| `lib/features/home/home_screen.dart` | Trending + recents + favorites |
| `lib/features/search/search_screen.dart` | Live search |
| `lib/features/browser/browser_screen.dart` | Embedded YouTube WebView |
| `lib/features/player/player_screen.dart` | Full Now Playing |
| `lib/features/player/queue_sheet.dart` | Up-next queue |
| `lib/features/player/lyrics_sheet.dart` | Lyrics viewer |
| `lib/features/player/sleep_timer_sheet.dart` | Sleep timer presets |
| `lib/features/library/library_screen.dart` | Favorites + history tabs |
| `lib/features/settings/settings_screen.dart` | Settings list |
| `lib/features/settings/equalizer_screen.dart` | Equalizer (Android) |
| `lib/features/overlay/floating_player.dart` | Overlay UI (separate Dart entry point) |
| `android/app/src/main/AndroidManifest.xml` | Permissions + foreground service |
| `ios/Runner/Info.plist` | UIBackgroundModes: audio |
| `ios/Runner/AppDelegate.swift` | AVAudioSession setup |

## Why it can't go on Play Store / App Store

The app calls YouTube's private `youtubei/v1` endpoints, which violates YouTube's ToS. Distribution is sideload-only:
- Android: signed APK distributed via your own site or GitHub releases
- iOS: Xcode build to your own device, AltStore, or Sideloadly

## Known limitations

- **Stream URLs expire.** YouTube signs them and rotates ciphers. When playback breaks, run `flutter pub upgrade youtube_explode_dart`.
- **Lyrics coverage is patchy.** lyrics.ovh has limited matches for non-English titles or YouTube uploads with messy titles.
- **Equalizer is Android-only.** iOS doesn't expose system EQ bands the same way.
- **Cast not implemented.** Add the `cast` package for Chromecast, native AVRoutePicker for AirPlay.

## Possible next steps

If you want to keep extending:
1. **Cast support** (Chromecast via `cast`, AirPlay via platform channel)
2. **Synced lyrics** (use Musixmatch or LRCLib for timed lyrics)
3. **Smart playlists** (auto-generated radio from a seed track)
4. **Theme switcher** (light / dark / dynamic colors from album art)
5. **Recommendations feed** (currently uses simple search; could call `music.youtube.com` charts endpoints)
6. **Offline cache** (the user explicitly didn't want downloads, but a transparent stream cache for repeat plays is friendlier on data)
