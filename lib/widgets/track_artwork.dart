import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Robust thumbnail loader with a YouTube fallback chain.
///
/// Two modes:
///   - `highRes: true` (default for the full Now Playing screen) — try
///     hq720 / maxres first
///   - `highRes: false` — start from `mqdefault.jpg` (320x180), the
///     cheapest reliable variant. Used for tiles + carousels so a
///     scroll doesn't decode dozens of 720p JPEGs.
class TrackArtwork extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final bool highRes;

  const TrackArtwork({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.highRes = false,
  });

  @override
  State<TrackArtwork> createState() => _TrackArtworkState();
}

class _TrackArtworkState extends State<TrackArtwork> {
  late List<String> _candidates;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _candidates = _expand(widget.url);
  }

  @override
  void didUpdateWidget(covariant TrackArtwork old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _candidates = _expand(widget.url);
      _index = 0;
    }
  }

  List<String> _expand(String url) {
    final id = _extractVideoId(url);
    if (id == null) return [url];
    if (widget.highRes) {
      // Full-size player needs crisp art.
      return <String>{
        url,
        'https://i.ytimg.com/vi/$id/maxresdefault.jpg',
        'https://i.ytimg.com/vi/$id/hq720.jpg',
        'https://i.ytimg.com/vi/$id/hqdefault.jpg',
        'https://i.ytimg.com/vi/$id/mqdefault.jpg',
      }.toList();
    }
    // List / carousel mode — small thumbs, fast scroll, less memory.
    return <String>{
      'https://i.ytimg.com/vi/$id/mqdefault.jpg',
      'https://i.ytimg.com/vi/$id/hqdefault.jpg',
    }.toList();
  }

  String? _extractVideoId(String url) {
    final m = RegExp(r'/vi/([A-Za-z0-9_-]+)/').firstMatch(url);
    return m?.group(1);
  }

  @override
  Widget build(BuildContext context) {
    final url = _candidates[_index];
    final image = CachedNetworkImage(
      imageUrl: url,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      fadeInDuration: const Duration(milliseconds: 200),
      fadeOutDuration: const Duration(milliseconds: 100),
      placeholder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      errorWidget: (context, _, __) {
        if (_index + 1 < _candidates.length) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _index += 1);
          });
        }
        return Container(
          width: widget.width,
          height: widget.height,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.music_note),
        );
      },
    );

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: image);
    }
    return image;
  }
}
