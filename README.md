# MewSify

<div align="center">

**A YouTube-powered music streamer with full background playback, video mode, playlists, and Spotify-style discovery.**

[![Latest Release](https://img.shields.io/github/v/release/moinrefaii-a11y/Mewsify?color=1DE97C&label=Latest)](https://github.com/moinrefaii-a11y/Mewsify/releases/latest)
[![Download APK](https://img.shields.io/badge/Download-APK-1DE97C?style=for-the-badge&logo=android)](https://github.com/moinrefaii-a11y/Mewsify/releases/latest/download/MewSify.apk)

</div>

## 📥 Install / Update

Sideloaded APKs don't get Play Store's auto-update, so **from v0.2.2 onward MewSify shows an in-app update prompt** every time a new release is available.

**Already have MewSify installed?**
- **v0.2.2+** — you'll get an update alert inside the app the next time you open it. Done.
- **v0.2.0 or v0.2.1** — please install v0.2.2 manually **one last time** so future updates flow automatically:
  👉 [Download MewSify.apk](https://github.com/moinrefaii-a11y/Mewsify/releases/latest/download/MewSify.apk)

**First time?** Same link above. Open it on your Android phone, tap install, allow "Install from unknown sources" when asked.

## ✨ Features

**Discovery**
- Spotify-style home with quick-access grid + 10 curated regional carousels (Bollywood, Hindi, Telugu, Tamil, Punjabi, Podcasts, Vlogs, Workout, Lo-fi, Comedy)
- All-content YouTube search (music, videos, vlogs, podcasts, anything)
- 4 search categories: All / Songs / Videos / Artists
- Voice search via mic icon
- Recent searches + smart suggestions
- Embedded YouTube browser tab
- Artist pages with "Fans also like"

**Playback**
- Background audio with lock-screen + notification controls
- YouTube autoplay-style queue (tap track → related songs fill Up Next)
- True two-player crossfade (0–12s, equal-power curve)
- Sleep timer, shuffle, repeat, Smart Shuffle
- Video mode — YouTube embed for full HD quality with the native quality picker

**Library**
- Favorites + history
- Custom playlists with drag-to-reorder + swipe-to-delete
- Profile with top artists + listening stats

**Now Playing**
- Blurred album-art gradient backdrop
- Up Next preview strip
- Hero animation between mini player and full player
- Swipe artwork left/right to skip
- Long-press track menu with Play next, Add to playlist, Start radio, Share, View artist

**Sharing**
- Spotify-style share message with a YouTube link
- Deep links — tapping a YouTube URL opens MewSify to that track (Android intent filter)
- `mewsify://track/{id}` custom scheme

## 🛠 Tech

Flutter · Riverpod · just_audio · audio_service · youtube_explode_dart · Hive · palette_generator · flutter_inappwebview · flutter_overlay_window · share_plus · speech_to_text · app_links · package_info_plus

## 🖥 Build from source

```bash
git clone https://github.com/moinrefaii-a11y/Mewsify.git
cd Mewsify
flutter pub get
flutter run  # Android device / emulator
```

For a release APK: `JAVA_HOME=$(/usr/libexec/java_home -v 17) flutter build apk --release`

## 📝 License / notes

This app scrapes YouTube via its private InnerTube API. That violates YouTube's Terms of Service which is why MewSify can't be published on Play Store or App Store. It's a learning / personal project distributed as a sideload APK.

---

<div align="center">

Created with ❤️ by [Moin](https://github.com/moinrefaii-a11y)

</div>
