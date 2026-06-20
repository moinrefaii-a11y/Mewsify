import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Robust thumbnail loader. Tries the user-supplied URL first; if that
/// fails (e.g. `maxresdefault.jpg` 404 for non-HD videos), it walks
/// the YouTube fallback chain: hq720 → hqdefault → mqdefault.
///
/// Avoids the "broken image" placeholder that CachedNetworkImage shows
/// when the primary URL is missing.
class TrackArtwork extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  const TrackArtwork({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
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

  /// Given any YouTube thumbnail URL, return the URL plus a fallback
  /// chain that progressively asks for smaller variants.
  List<String> _expand(String url) {
    final id = _extractVideoId(url);
    if (id == null) return [url];
    return <String>{
      url,
      'https://i.ytimg.com/vi/$id/maxresdefault.jpg',
      'https://i.ytimg.com/vi/$id/hq720.jpg',
      'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      'https://i.ytimg.com/vi/$id/mqdefault.jpg',
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
      errorWidget: (context, _, __) {
        // Move to the next fallback URL on the next frame and rebuild.
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
