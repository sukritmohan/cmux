/// Dual dark/light theme for the cmux companion app.
///
/// Uses the warm amber palette from [AppColors] with three font families:
/// - JetBrains Mono: headings, labels, section headers (bundled)
/// - IBM Plex Sans: body text, UI controls (via google_fonts)
/// - IBM Plex Mono: code, monospace content (via google_fonts)
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'colors.dart';

abstract final class AppTheme {
  // ── Font families ──

  static String get _headingFamily => 'JetBrains Mono';

  static TextStyle _bodyBase() => GoogleFonts.ibmPlexSans();
  static TextStyle _monoBase() => GoogleFonts.ibmPlexMono();

  // ── Named text styles ──

  /// Section header (uppercase, muted, JetBrains Mono).
  static TextStyle sectionHeader(AppColorScheme c) => TextStyle(
        fontFamily: _headingFamily,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: c.textMuted,
        letterSpacing: 2.5,
      );

  /// Heading large (JetBrains Mono).
  static TextStyle headingLarge(AppColorScheme c) => TextStyle(
        fontFamily: _headingFamily,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: c.textPrimary,
      );

  /// Body text style (IBM Plex Sans).
  static TextStyle body(AppColorScheme c) => _bodyBase().copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: c.textSecondary,
      );

  /// Monospace style for code/terminal labels (IBM Plex Mono).
  static TextStyle mono(AppColorScheme c) => _monoBase().copyWith(
        fontSize: 11.5,
        fontWeight: FontWeight.w500,
        color: c.textPrimary,
        letterSpacing: 0.2,
      );

  /// Small monospace for metadata, counters, minimap labels.
  static TextStyle monoSmall(AppColorScheme c) => _monoBase().copyWith(
        fontSize: 9,
        fontWeight: FontWeight.w400,
        color: c.textSecondary,
        height: 1.3,
      );

  // ── Theme factories ──

  static ThemeData _buildTheme(AppColorScheme c, Brightness brightness) {
    final bodyFont = _bodyBase();

    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: c.bgPrimary,

      colorScheme: ColorScheme(
        brightness: brightness,
        primary: c.accent,
        secondary: c.accentText,
        surface: c.bgElevated,
        error: const Color(0xFFF85149),
        onPrimary: c.bgPrimary,
        onSecondary: c.bgPrimary,
        onSurface: c.textPrimary,
        onError: c.bgPrimary,
        outline: c.border,
      ),

      // -- AppBar --
      appBarTheme: AppBarTheme(
        backgroundColor: c.bgPrimary,
        foregroundColor: c.textPrimary,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
      ),

      // -- Cards --
      cardTheme: CardThemeData(
        color: c.bgElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppColors.radiusMd),
          side: BorderSide(color: c.border),
        ),
      ),

      // -- Drawer --
      drawerTheme: DrawerThemeData(
        backgroundColor: c.bgPrimary,
        scrimColor: c.drawerScrim,
        width: 280,
      ),

      // -- BottomSheet --
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.bgElevated,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppColors.radiusLg),
          ),
        ),
      ),

      // -- Elevated buttons --
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.bgPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          textStyle: bodyFont.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),

      // -- Outlined buttons --
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          side: BorderSide(color: c.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),

      // -- Text --
      textTheme: TextTheme(
        headlineLarge: TextStyle(
          fontFamily: _headingFamily,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: c.textPrimary,
          letterSpacing: -0.5,
        ),
        headlineSmall: TextStyle(
          fontFamily: _headingFamily,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: c.textPrimary,
        ),
        bodyLarge: bodyFont.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: c.textPrimary,
        ),
        bodyMedium: bodyFont.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: c.textSecondary,
        ),
        bodySmall: bodyFont.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: c.textMuted,
        ),
        labelLarge: bodyFont.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: c.textPrimary,
          letterSpacing: 0.3,
        ),
        labelSmall: TextStyle(
          fontFamily: _headingFamily,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: c.textMuted,
          letterSpacing: 1.0,
        ),
      ),

      // -- Divider --
      dividerTheme: DividerThemeData(
        color: c.border,
        thickness: 1,
        space: 1,
      ),

      // -- Icon --
      iconTheme: IconThemeData(
        color: c.textSecondary,
        size: 20,
      ),

      // -- Scrollbar --
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(
          c.textMuted.withAlpha(100),
        ),
        radius: const Radius.circular(2),
        thickness: WidgetStateProperty.all(4),
      ),

      // -- SnackBar --
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.bgActive,
        contentTextStyle: bodyFont.copyWith(
          color: c.textPrimary,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      // Disable splash/highlight to feel more terminal-native
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }

  /// Dark theme — warm near-blacks with amber accent.
  static final ThemeData darkTheme = _buildTheme(AppColors.dark, Brightness.dark);

  /// Light theme — warm off-whites with amber accent.
  static final ThemeData lightTheme = _buildTheme(AppColors.light, Brightness.light);
}
