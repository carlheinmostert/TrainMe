import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// HomeFit Studio — Brand Design System
// ---------------------------------------------------------------------------
//
// Palette inspired by Strava's energetic orange, Peloton's dark-mode workout
// aesthetic, and FIIT's bold typography. Designed for biokineticists and
// trainers who want to look modern and professional, not clinical.
//
// Typography: Montserrat (headings) + Inter (body). Both on Google Fonts.
// Add to pubspec.yaml:
//   google_fonts: ^6.1.0
//
// Usage:
//   MaterialApp(theme: AppTheme.light, darkTheme: AppTheme.dark, ...)

// ── Colour Tokens ──────────────────────────────────────────────────────────

class AppColors {
  AppColors._();

  // Primary — Coral Orange: energy, warmth, motivation
  static const Color primary = Color(0xFFFF6B35);
  static const Color primaryDark = Color(0xFFE85A24);
  static const Color primaryLight = Color(0xFFFF8F5E);
  static const Color primarySurface = Color(0xFFFFF3ED);

  // Neutrals — warm-tinted greys (not pure grey, adds personality)
  static const Color grey50 = Color(0xFFFAFAFB);
  static const Color grey100 = Color(0xFFF3F4F6);
  static const Color grey200 = Color(0xFFE5E7EB);
  static const Color grey300 = Color(0xFFD1D5DB);
  static const Color grey400 = Color(0xFF9CA3AF);
  static const Color grey500 = Color(0xFF6B7280);
  static const Color grey600 = Color(0xFF4B5563);
  static const Color grey700 = Color(0xFF374151);
  static const Color grey800 = Color(0xFF1F2937);
  static const Color grey900 = Color(0xFF111827);

  // Text
  static const Color textPrimary = Color(0xFF1A1A2E); // near-black with depth
  static const Color textSecondary = Color(0xFF6B7280); // grey-500
  static const Color textOnPrimary = Color(0xFFFFFFFF);
  static const Color textOnDark = Color(0xFFF0F0F5);
  static const Color textSecondaryOnDark = Color(0xFF9CA3AF);

  // Semantic — status colours
  static const Color success = Color(0xFF22C55E); // green-500
  static const Color successLight = Color(0xFFDCFCE7);
  static const Color warning = Color(0xFFF59E0B); // amber-500
  static const Color warningLight = Color(0xFFFEF3C7);
  static const Color error = Color(0xFFEF4444); // red-500
  static const Color errorLight = Color(0xFFFEE2E2);

  // Feature accents — now unified with primary coral orange (was teal)
  static const Color circuit = Color(0xFFFF6B35); // coral orange, circuits
  static const Color circuitLight = Color(0xFFFFF3ED);
  static const Color circuitDark = Color(0xFFE85A24);

  static const Color rest = Color(0xFF64748B); // slate-500, rest periods
  static const Color restLight = Color(0xFFF1F5F9); // slate-50
  static const Color restSurface =
      Color(0xFFE2E8F0); // slate-200, rest card bg

  // ── Dark surface tokens (semantic names — D-02) ──
  // Mirrors docs/design/project/tokens.json `color.surface.dark.*`.
  static const Color surfaceBg = Color(0xFF0F1117);      // App root bg. Elevation 0.
  static const Color surfaceBase = Color(0xFF1A1D27);    // Card / sheet. Elevation 1.
  static const Color surfaceRaised = Color(0xFF242733);  // Popover / modal / hover. Elevation 2.
  static const Color surfaceBorder = Color(0xFF2E3140);  // 1px hairline separation.

  // ── Light surface tokens (mirror — D-08, gated by kEnableLightTheme) ──
  // Mirrors docs/design/project/tokens.json `color.surface.light.*`.
  static const Color lightBg = Color(0xFFFAFAF7);
  static const Color lightBase = Color(0xFFFFFFFF);
  static const Color lightRaised = Color(0xFFF5F5F0);
  static const Color lightBorder = Color(0xFFE5E7EB);

  // ── Light ink tokens (mirror — D-08) ──
  static const Color lightInkPrimary = Color(0xFF0F1117);
  static const Color lightInkSecondary = Color(0xFF4B5563);
  static const Color lightInkMuted = Color(0xFF6B7280);
  static const Color lightInkDisabled = Color(0xFF9CA3AF);

  // ── Brand tint tokens (D-10) ──
  // Explicit constants so call sites don't reach for .withValues on every use.
  static const Color brandTintBg = Color.fromRGBO(255, 107, 53, 0.12);
  static const Color brandTintBorder = Color.fromRGBO(255, 107, 53, 0.30);

  // NOTE (D-06): Canonical Empty/Loading/Error/Success/Disabled state treatments
  // are a per-screen refactor. Apply incrementally as screens get touched —
  // see docs/design/project/components.md for the approved treatments.
}

// ── Theme Data ─────────────────────────────────────────────────────────────

class AppTheme {
  AppTheme._();

  // ── Shared constants ──

  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 20;

  // ── Light Theme ──

  static ThemeData get light {
    const colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.primary,
      onPrimary: AppColors.textOnPrimary,
      primaryContainer: AppColors.primarySurface,
      onPrimaryContainer: AppColors.primaryDark,
      secondary: AppColors.circuit,
      onSecondary: Colors.white,
      secondaryContainer: AppColors.circuitLight,
      onSecondaryContainer: AppColors.circuitDark,
      tertiary: AppColors.rest,
      onTertiary: Colors.white,
      tertiaryContainer: AppColors.restLight,
      onTertiaryContainer: AppColors.grey800,
      error: AppColors.error,
      onError: Colors.white,
      errorContainer: AppColors.errorLight,
      onErrorContainer: Color(0xFFB91C1C),
      surface: Colors.white,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textSecondary,
      outline: AppColors.grey300,
      outlineVariant: AppColors.grey200,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: AppColors.grey900,
      onInverseSurface: AppColors.grey50,
      inversePrimary: AppColors.primaryLight,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: AppColors.grey50,
      surfaceContainer: AppColors.grey100,
      surfaceContainerHigh: AppColors.grey200,
      surfaceContainerHighest: AppColors.grey300,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.grey50,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Montserrat',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
          color: AppColors.textPrimary,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.grey200),
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: CircleBorder(),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: AppColors.grey200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: AppColors.grey200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide:
              const BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: AppColors.error),
        ),
        hintStyle: const TextStyle(
          color: AppColors.grey400,
          fontFamily: 'Inter',
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: const BorderSide(color: AppColors.grey200),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.grey100,
        labelStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(100),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.grey200,
        thickness: 1,
        space: 1,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.grey400,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: AppColors.primarySurface,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: AppColors.primary);
          }
          return const IconThemeData(color: AppColors.grey400);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
            );
          }
          return const TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppColors.grey500,
          );
        }),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
        linearTrackColor: AppColors.grey200,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: AppColors.grey200,
        thumbColor: AppColors.primary,
        overlayColor: AppColors.brandTintBg,
        trackHeight: 4,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.grey900,
        contentTextStyle: const TextStyle(
          fontFamily: 'Inter',
          color: Colors.white,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      textTheme: _textTheme,
    );
  }

  // ── Dark Theme ──

  static ThemeData get dark {
    const colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFF3D1E0F),
      onPrimaryContainer: AppColors.primaryLight,
      secondary: AppColors.circuit,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFF3D1E0F),
      onSecondaryContainer: AppColors.primaryLight,
      tertiary: Color(0xFF94A3B8), // slate-400
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFF1E293B),
      onTertiaryContainer: Color(0xFFCBD5E1),
      error: Color(0xFFF87171), // red-400, brighter for dark bg
      onError: Colors.white,
      errorContainer: Color(0xFF3B1111),
      onErrorContainer: Color(0xFFFCA5A5),
      surface: AppColors.surfaceBase,
      onSurface: AppColors.textOnDark,
      onSurfaceVariant: AppColors.textSecondaryOnDark,
      outline: AppColors.surfaceBorder,
      outlineVariant: Color(0xFF1E2130),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: AppColors.grey100,
      onInverseSurface: AppColors.grey900,
      inversePrimary: AppColors.primaryDark,
      surfaceContainerLowest: AppColors.surfaceBg,
      surfaceContainerLow: Color(0xFF151822),
      surfaceContainer: AppColors.surfaceBase,
      surfaceContainerHigh: AppColors.surfaceRaised,
      surfaceContainerHighest: Color(0xFF2E3140),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.surfaceBg,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surfaceBase,
        foregroundColor: AppColors.textOnDark,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Montserrat',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
          color: AppColors.textOnDark,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textOnDark,
          side: const BorderSide(color: AppColors.surfaceBorder),
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceRaised,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: AppColors.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: AppColors.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide:
              const BorderSide(color: AppColors.primary, width: 2),
        ),
        hintStyle: const TextStyle(
          color: AppColors.textSecondaryOnDark,
          fontFamily: 'Inter',
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surfaceBase,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: const BorderSide(color: AppColors.surfaceBorder),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.surfaceBorder,
        thickness: 1,
        space: 1,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.surfaceBase,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textSecondaryOnDark,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
        linearTrackColor: AppColors.surfaceBorder,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: AppColors.surfaceBorder,
        thumbColor: AppColors.primary,
        overlayColor: AppColors.brandTintBg,
        trackHeight: 4,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceRaised,
        contentTextStyle: const TextStyle(
          fontFamily: 'Inter',
          color: AppColors.textOnDark,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      textTheme: _textThemeDark,
    );
  }

  // ── Typography ──

  static const _textTheme = TextTheme(
    // Display — splash screens, big numbers
    displayLarge: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 57,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.5,
      color: AppColors.textPrimary,
    ),
    displayMedium: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 45,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: AppColors.textPrimary,
    ),
    displaySmall: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 36,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: AppColors.textPrimary,
    ),
    // Headline — section titles
    headlineLarge: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: AppColors.textPrimary,
    ),
    headlineMedium: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 28,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: AppColors.textPrimary,
    ),
    headlineSmall: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      color: AppColors.textPrimary,
    ),
    // Title — card headers, app bar
    titleLarge: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: AppColors.textPrimary,
    ),
    titleMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: AppColors.textPrimary,
    ),
    titleSmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: AppColors.textPrimary,
    ),
    // Body — main content
    bodyLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 16,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: AppColors.textPrimary,
      height: 1.5,
    ),
    bodyMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 14,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: AppColors.textPrimary,
      height: 1.5,
    ),
    bodySmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 12,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: AppColors.textSecondary,
      height: 1.5,
    ),
    // Label — buttons, chips, badges
    labelLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: AppColors.textPrimary,
    ),
    labelMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: AppColors.textSecondary,
    ),
    labelSmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: AppColors.textSecondary,
    ),
  );

  static const _textThemeDark = TextTheme(
    displayLarge: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 57,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.5,
      color: AppColors.textOnDark,
    ),
    displayMedium: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 45,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: AppColors.textOnDark,
    ),
    displaySmall: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 36,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: AppColors.textOnDark,
    ),
    headlineLarge: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: AppColors.textOnDark,
    ),
    headlineMedium: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 28,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: AppColors.textOnDark,
    ),
    headlineSmall: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      color: AppColors.textOnDark,
    ),
    titleLarge: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: AppColors.textOnDark,
    ),
    titleMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: AppColors.textOnDark,
    ),
    titleSmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: AppColors.textOnDark,
    ),
    bodyLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 16,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: AppColors.textOnDark,
      height: 1.5,
    ),
    bodyMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 14,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: AppColors.textOnDark,
      height: 1.5,
    ),
    bodySmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 12,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: AppColors.textSecondaryOnDark,
      height: 1.5,
    ),
    labelLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: AppColors.textOnDark,
    ),
    labelMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: AppColors.textSecondaryOnDark,
    ),
    labelSmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: AppColors.textSecondaryOnDark,
    ),
  );
}
