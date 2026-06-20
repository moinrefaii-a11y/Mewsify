import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// Extracts dominant colors from album art for the Spotify-style
/// gradient player background. Results are cached in-memory keyed by
/// the artwork URL so the same lookup doesn't repeat for every rebuild.
class PaletteService {
  PaletteService._();
  static final PaletteService instance = PaletteService._();

  final Map<String, MelodyPalette> _cache = {};

  static const _fallback = MelodyPalette(
    primary: Color(0xFF1A1A1D),
    secondary: Color(0xFF0F0F10),
    text: Colors.white,
  );

  Future<MelodyPalette> getPalette(String url) async {
    if (_cache.containsKey(url)) return _cache[url]!;

    try {
      final provider = CachedNetworkImageProvider(url);
      final palette = await PaletteGenerator.fromImageProvider(
        provider,
        size: const Size(120, 120),
        maximumColorCount: 16,
      );

      final dominant = palette.dominantColor?.color;
      final dark = palette.darkVibrantColor?.color ??
          palette.darkMutedColor?.color ??
          palette.dominantColor?.color;

      if (dominant == null) {
        _cache[url] = _fallback;
        return _fallback;
      }

      final result = MelodyPalette(
        primary: dominant,
        secondary: dark ?? dominant,
        text: _isLight(dominant) ? Colors.black87 : Colors.white,
      );
      _cache[url] = result;
      return result;
    } catch (_) {
      return _fallback;
    }
  }

  /// Approximate luminance check to pick readable text color.
  bool _isLight(Color c) {
    final lum = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b);
    return lum > 0.6;
  }
}

class MelodyPalette {
  final Color primary;
  final Color secondary;
  final Color text;
  const MelodyPalette({
    required this.primary,
    required this.secondary,
    required this.text,
  });
}
