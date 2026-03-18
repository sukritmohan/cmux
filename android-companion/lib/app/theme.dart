/// Dark terminal theme for the cmux companion app.
///
/// Uses the merged GitHub-dark palette from the gesture-driven and
/// pane-type-switcher design mockups. All tokens live in [AppColors].
library;

import 'package:flutter/material.dart';

import 'colors.dart';

abstract final class AppTheme {
  static final ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bgPrimary,

    colorScheme: const ColorScheme.dark(
      primary: AppColors.accentBlue,
      secondary: AppColors.accentCyan,
      surface: AppColors.bgSecondary,
      error: AppColors.accentRed,
      onPrimary: AppColors.bgPrimary,
      onSecondary: AppColors.bgPrimary,
      onSurface: AppColors.textPrimary,
      onError: AppColors.bgPrimary,
      outline: AppColors.borderSubtle,
    ),

    // -- AppBar --
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bgSecondary,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),

    // -- Cards --
    cardTheme: CardThemeData(
      color: AppColors.bgSecondary,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        side: const BorderSide(color: AppColors.borderSubtle),
      ),
    ),

    // -- Drawer --
    drawerTheme: const DrawerThemeData(
      backgroundColor: AppColors.bgPrimary,
      scrimColor: Color(0x80000000), // rgba(0,0,0,0.5)
      width: 300,
    ),

    // -- BottomSheet --
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.bgSecondary,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppColors.radiusLg),
        ),
      ),
    ),

    // -- Elevated buttons --
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accentBlue,
        foregroundColor: AppColors.bgPrimary,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    ),

    // -- Outlined buttons --
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.borderSubtle),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),

    // -- Text --
    textTheme: const TextTheme(
      // Headings
      headlineLarge: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: -0.5,
      ),
      headlineSmall: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),

      // Body
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: AppColors.textPrimary,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: AppColors.textMuted,
      ),

      // Labels (section headers, tab bar text)
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
        letterSpacing: 0.3,
      ),
      labelSmall: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: AppColors.textMuted,
        letterSpacing: 1.0,
      ),
    ),

    // -- Divider --
    dividerTheme: const DividerThemeData(
      color: AppColors.borderSubtle,
      thickness: 1,
      space: 1,
    ),

    // -- Icon --
    iconTheme: const IconThemeData(
      color: AppColors.textSecondary,
      size: 20,
    ),

    // -- Scrollbar --
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(
        AppColors.textMuted.withAlpha(100),
      ),
      radius: const Radius.circular(2),
      thickness: WidgetStateProperty.all(4),
    ),

    // -- SnackBar --
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.bgTertiary,
      contentTextStyle: const TextStyle(
        color: AppColors.textPrimary,
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

  // -- Named text styles for code/terminal use --

  /// Monospace text for terminal output and code snippets.
  static const monoStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
    height: 1.4,
  );

  /// Smaller monospace for metadata, counters, minimap labels.
  static const monoSmallStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.3,
  );

  /// Section header (uppercase, muted) used in drawer and panels.
  static const sectionHeaderStyle = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w700,
    color: AppColors.textMuted,
    letterSpacing: 1.2,
  );
}
