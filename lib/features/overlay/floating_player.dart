import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// Entry point for the Android floating overlay window. This widget
/// runs in a *separate* FlutterEngine spawned by flutter_overlay_window,
/// so it does NOT share state with the main app. We exchange tiny
/// JSON messages over the OverlayWindow port instead.
///
/// The overlay shows current track info + a play / pause button and a
/// "open app" tap target. Tapping the body of the bubble brings the
/// main app forward.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _OverlayApp());
}

class _OverlayApp extends StatelessWidget {
  const _OverlayApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const Material(
        color: Colors.transparent,
        child: _OverlayBody(),
      ),
    );
  }
}

class _OverlayBody extends StatefulWidget {
  const _OverlayBody();

  @override
  State<_OverlayBody> createState() => _OverlayBodyState();
}

class _OverlayBodyState extends State<_OverlayBody> {
  String _title = 'MewSify';
  String _artist = '';
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((data) {
      if (data is Map) {
        setState(() {
          _title = data['title']?.toString() ?? _title;
          _artist = data['artist']?.toString() ?? _artist;
          _playing = data['playing'] as bool? ?? _playing;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Tap the bubble body to open the main app.
      onTap: () => FlutterOverlayWindow.shareData({'action': 'open_app'}),
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xCC18181B),
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 4)),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircleAvatar(
              radius: 18,
              backgroundColor: Color(0xFFE53935),
              child: Icon(Icons.music_note, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (_artist.isNotEmpty)
                    Text(
                      _artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 20,
              ),
              onPressed: () => FlutterOverlayWindow.shareData({
                'action': _playing ? 'pause' : 'play',
              }),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const Icon(Icons.close, color: Colors.white70, size: 18),
              onPressed: () => FlutterOverlayWindow.shareData({'action': 'close'}),
            ),
          ],
        ),
      ),
    );
  }
}
