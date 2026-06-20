import 'package:flutter/material.dart';

import '../data/models/track.dart';
import '../services/palette_service.dart';
import 'eq_indicator.dart';
import 'track_artwork.dart';

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
            TrackArtwork(
              url: track.thumbnailUrl,
              width: 52,
              height: 52,
              borderRadius: BorderRadius.circular(8),
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
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<MelodyPalette>(
      future: PaletteService.instance.getPalette(track.thumbnailUrl),
      builder: (context, snap) {
        // Soft horizontal gradient tinted with the artwork's dominant
        // colour. Only paints once palette is resolved so first paint
        // doesn't flash a wrong color.
        final tint = snap.data?.primary;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: tint == null
                ? null
                : LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      tint.withValues(alpha: 0.22),
                      scheme.surface.withValues(alpha: 0.0),
                    ],
                  ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
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
                        child: TrackArtwork(url: track.thumbnailUrl),
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
                              child: EqIndicator(
                                size: 28,
                                color: Theme.of(context).colorScheme.primary,
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
          ),
        );
      },
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

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
