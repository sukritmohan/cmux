/// Design tokens for the cmux companion app.
///
/// Warm amber palette with dual dark/light themes per the pane-type-switcher spec.
/// Access the current theme's colors via `AppColors.of(context)`.
library;

import 'package:flutter/material.dart';

/// Color scheme with all tokens needed across the app.
///
/// Two const instances exist: [AppColors.dark] and [AppColors.light].
class AppColorScheme {
  // -- Backgrounds --
  final Color bgDeep;
  final Color bgPrimary;
  final Color bgElevated;
  final Color bgSurface;
  final Color bgHover;
  final Color bgActive;

  // -- Text --
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  // -- Borders --
  final Color border;
  final Color borderStrong;

  // -- Accent --
  final Color accent;
  final Color accentGlow;
  final Color accentGlowStrong;
  final Color accentText;

  // -- Pane type colors --
  final Color terminalColor;
  final Color terminalBg;
  final Color browserColor;
  final Color browserBg;
  final Color filesColor;
  final Color filesBg;
  final Color overviewColor;
  final Color overviewBg;

  // -- Drawer --
  final Color drawerBg;
  final Color drawerScrim;

  // -- Modifier bar --
  final Color modifierBarBg;

  // -- Connection indicator --
  final Color connectedColor;

  const AppColorScheme({
    required this.bgDeep,
    required this.bgPrimary,
    required this.bgElevated,
    required this.bgSurface,
    required this.bgHover,
    required this.bgActive,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.border,
    required this.borderStrong,
    required this.accent,
    required this.accentGlow,
    required this.accentGlowStrong,
    required this.accentText,
    required this.terminalColor,
    required this.terminalBg,
    required this.browserColor,
    required this.browserBg,
    required this.filesColor,
    required this.filesBg,
    required this.overviewColor,
    required this.overviewBg,
    required this.drawerBg,
    required this.drawerScrim,
    required this.modifierBarBg,
    required this.connectedColor,
  });
}

/// Convenience accessors and shared constants for the color system.
abstract final class AppColors {
  /// Dark color scheme — warm near-blacks, tinted surfaces.
  static const dark = AppColorScheme(
    bgDeep: Color(0xFF0A0A0F),
    bgPrimary: Color(0xFF0E0E14),
    bgElevated: Color(0xFF16161E),
    bgSurface: Color(0xFF1A1A24),
    bgHover: Color(0xFF20202C),
    bgActive: Color(0xFF262634),
    textPrimary: Color(0xFFE8E8EE),
    textSecondary: Color(0x8CE8E8EE), // 55% alpha
    textMuted: Color(0x4DE8E8EE), // 30% alpha
    border: Color(0x0FFFFFFF), // 6% white
    borderStrong: Color(0x1AFFFFFF), // 10% white
    accent: Color(0xFFE0A030),
    accentGlow: Color(0x26E0A030), // 15%
    accentGlowStrong: Color(0x40E0A030), // 25%
    accentText: Color(0xFFF0C060),
    terminalColor: Color(0xFF50C878),
    terminalBg: Color(0x1A50C878),
    browserColor: Color(0xFF5B9BD5),
    browserBg: Color(0x1A5B9BD5),
    filesColor: Color(0xFFE0A030),
    filesBg: Color(0x1AE0A030),
    overviewColor: Color(0xFFB08CDC),
    overviewBg: Color(0x1AB08CDC),
    drawerBg: Color(0xEB0E0E14), // 92% alpha
    drawerScrim: Color(0x66000000), // 40%
    modifierBarBg: Color(0xD1101018), // 82%
    connectedColor: Color(0xFF50C878),
  );

  /// Light color scheme — warm off-whites, clean surfaces.
  static const light = AppColorScheme(
    bgDeep: Color(0xFFF5F5F0),
    bgPrimary: Color(0xFFFAFAF7),
    bgElevated: Color(0xFFFFFFFF),
    bgSurface: Color(0xFFF0F0EB),
    bgHover: Color(0xFFEAEAE5),
    bgActive: Color(0xFFE2E2DC),
    textPrimary: Color(0xFF1A1A1F),
    textSecondary: Color(0x8C1A1A1F), // 55% alpha
    textMuted: Color(0x4D1A1A1F), // 30% alpha
    border: Color(0x12000000), // 7% black
    borderStrong: Color(0x1F000000), // 12% black
    accent: Color(0xFFE0A030),
    accentGlow: Color(0x1AE0A030), // 10%
    accentGlowStrong: Color(0x2EE0A030), // 18%
    accentText: Color(0xFFB07810),
    terminalColor: Color(0xFF1B8C4E),
    terminalBg: Color(0x1A2DB45A),
    browserColor: Color(0xFF2D6AB0),
    browserBg: Color(0x1A5B9BD5),
    filesColor: Color(0xFFB07810),
    filesBg: Color(0x1AE0A030),
    overviewColor: Color(0xFF7A5AAE),
    overviewBg: Color(0x1AB08CDC),
    drawerBg: Color(0xEBFAFAF7), // 92% alpha
    drawerScrim: Color(0x14000000), // 8%
    modifierBarBg: Color(0xBFFFFFFF), // 75%
    connectedColor: Color(0xFF2D8A4E),
  );

  /// Returns the color scheme matching the current theme brightness.
  static AppColorScheme of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }

  // -- Shared radius constants --
  static const radiusXs = 4.0;
  static const radiusSm = 6.0;
  static const radiusMd = 10.0;
  static const radiusLg = 14.0;
  static const radiusXl = 20.0;
}
