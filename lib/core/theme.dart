import 'package:flutter/material.dart';

/// All app theming. Themes are constructed at runtime so the user can
/// switch the seed color from settings without restarting the app.
class MelodyTheme {
  static const defaultSeed = Color(0xFF1DB954); // Spotify-inspired green

  /// Curated set of seed colors the user can pick from.
  static const seedPalette = <ThemeSeed>[
    ThemeSeed('Spotify', Color(0xFF1DB954)),
    ThemeSeed('Crimson', Color(0xFFE53935)),
    ThemeSeed('Sunset', Color(0xFFFF7043)),
    ThemeSeed('Amber', Color(0xFFFFB300)),
    ThemeSeed('Teal', Color(0xFF00897B)),
    ThemeSeed('Ocean', Color(0xFF1E88E5)),
    ThemeSeed('Indigo', Color(0xFF3949AB)),
    ThemeSeed('Violet', Color(0xFF8E24AA)),
    ThemeSeed('Rose', Color(0xFFEC407A)),
    ThemeSeed('Slate', Color(0xFF546E7A)),
  ];

  static ThemeData light(Color seed) => _build(seed, Brightness.light);
  static ThemeData dark(Color seed) => _build(seed, Brightness.dark);

  static ThemeData _build(Color seed, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: isDark ? const Color(0xFF0F0F10) : scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF18181B) : scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        height: 68,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? const Color(0xFF1A1A1D) : scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.12),
        thumbColor: scheme.primary,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF1A1A1D) : scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    );
  }
}

class ThemeSeed {
  final String name;
  final Color color;
  const ThemeSeed(this.name, this.color);
}
