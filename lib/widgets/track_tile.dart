import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/models/track.dart';

/// Reusable track row. Two visual styles:
///  - compact (default) for queue / library / horizontal carousels
///  - wide for search results, mimicking YouTube's mobile layout
///    with a 16:9 thumbnail
///
/// Long-press on any tile opens the Spotify-style quick actions sheet.
class TrackTile extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool wide;
  final bool isPlaying;

  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.onMore,
    this.onLongPress,
    this.trailing,
    this.wide = false,
    this.isPlaying = false,
  });

  @override
  Widget build(BuildContext context) {
    return wide ? _wideLayout(context) : _compactLayout(context);
  }

  Widget _compactLayout(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: track.thumbnailUrl,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => _placeholder(context, 52, 52),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _meta(context)),
            if (trailing != null) trailing!,
            if (onMore != null)
              IconButton(icon: const Icon(Icons.more_vert), onPressed: onMore),
          ],
        ),
      ),
    );
  }

  Widget _wideLayout(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 16:9 thumbnail like YouTube. Stack a duration pill in the
            // bottom-right corner.
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 156,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CachedNetworkImage(
                          imageUrl: track.thumbnailUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _placeholder(context, 0, 0),
                        ),
                      ),
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.78),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _fmt(track.duration),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      if (isPlaying)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.45),
                            child: Center(
                              child: Icon(
                                Icons.equalizer,
                                color: Theme.of(context).colorScheme.primary,
                                size: 32,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        height: 1.3,
                        color: isPlaying ? Theme.of(context).colorScheme.primary : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (onMore != null)
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_vert, size: 20),
                onPressed: onMore,
              ),
          ],
        ),
      ),
    );
  }

  Widget _meta(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: isPlaying ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${track.artist} · ${_fmt(track.duration)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _placeholder(BuildContext context, double w, double h) => Container(
        width: w == 0 ? null : w,
        height: h == 0 ? null : h,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.music_note),
      );

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
