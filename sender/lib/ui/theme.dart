import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Palette ──────────────────────────────────────────────────────────────────

class NeonColors {
  NeonColors._();

  static const Color bg = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF15131C);
  static const Color magenta = Color(0xFFFF2D95);
  static const Color cyan = Color(0xFF00E5FF);
  static const Color violet = Color(0xFF7C4DFF);

  // Semantic aliases used by the theme
  static const Color onBg = Colors.white;
  static const Color onSurface = Colors.white;
}

// ── Gradients ─────────────────────────────────────────────────────────────────

/// Primary brand gradient: magenta → cyan → violet.
const LinearGradient brandGradient = LinearGradient(
  colors: [NeonColors.magenta, NeonColors.cyan, NeonColors.violet],
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
);

/// Vertical variant useful for VU-meter fill bars.
const LinearGradient brandGradientVertical = LinearGradient(
  colors: [NeonColors.violet, NeonColors.cyan, NeonColors.magenta],
  begin: Alignment.bottomCenter,
  end: Alignment.topCenter,
);

// ── Glow helper ───────────────────────────────────────────────────────────────

BoxShadow neonGlow(
  Color color, {
  double blur = 18,
  double spread = 1,
}) {
  return BoxShadow(
    color: color.withValues(alpha: 0.5),
    blurRadius: blur,
    spreadRadius: spread,
  );
}

// ── Text styles ───────────────────────────────────────────────────────────────

/// Wordmark style: Orbitron 700, large, wide letter-spacing.
/// The next phase can size/color it as needed; this is the base.
TextStyle get wordmarkStyle => const TextStyle(
      fontFamily: 'Orbitron',
      fontFamilyFallback: ['sans-serif'],
      fontWeight: FontWeight.w700,
      fontSize: 32,
      letterSpacing: 6,
      color: Colors.white,
    );

// ── Theme builder ─────────────────────────────────────────────────────────────

ThemeData buildEverdjTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: NeonColors.magenta,
    brightness: Brightness.dark,
  ).copyWith(
    surface: NeonColors.surface,
    onSurface: NeonColors.onSurface,
    primary: NeonColors.magenta,
    secondary: NeonColors.cyan,
    tertiary: NeonColors.violet,
    // Material3 maps scaffold background to surface by default; override it.
    surfaceContainerLowest: NeonColors.bg,
    surfaceContainerLow: NeonColors.bg,
    surfaceContainer: NeonColors.surface,
  );

  // Rajdhani via google_fonts — resolves to the bundled asset offline because
  // pubspec.yaml declares the family under `flutter.fonts`.
  final textTheme = GoogleFonts.rajdhaniTextTheme(
    ThemeData.dark().textTheme,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: NeonColors.bg,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: NeonColors.bg,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        fontFamily: 'Rajdhani',
        fontWeight: FontWeight.w600,
        letterSpacing: 2,
        color: Colors.white,
      ),
    ),
  );
}
