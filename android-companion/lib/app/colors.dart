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

  // -- Modifier bar components --
  final Color keyGroupResting;
  final Color keyGroupText;
  final Color keyGroupActive;
  final Color fanBtnResting;
  final Color fanBtnActive;
  final Color fanPopoverBg;
  final Color symKeyResting;
  final Color joystickFill;
  final Color joystickBorder;
  final Color joystickPressed;
  final Color joystickPressedBorder;
  final Color returnGradientStart;
  final Color returnGradientEnd;
  final Color returnGlow;
  final Color returnText;

  // -- Clipboard --
  final Color clipboardBadge;
  final Color clipboardBadgeBorder;
  final Color clipboardLatestBorder;
  final Color clipboardLatestBadge;

  // -- Keyboard button --
  final Color keyboardBtnGradientStart;
  final Color keyboardBtnGradientEnd;
  final Color keyboardBtnBorder;
  final Color keyboardBtnGlow;
  final Color keyboardBtnIcon;

  // -- Bottom sheet --
  final Color sheetBg;
  final Color sheetHandle;
  final Color sheetSearch;
  final Color sheetSearchBorder;

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
    required this.keyGroupResting,
    required this.keyGroupText,
    required this.keyGroupActive,
    required this.fanBtnResting,
    required this.fanBtnActive,
    required this.fanPopoverBg,
    required this.symKeyResting,
    required this.joystickFill,
    required this.joystickBorder,
    required this.joystickPressed,
    required this.joystickPressedBorder,
    required this.returnGradientStart,
    required this.returnGradientEnd,
    required this.returnGlow,
    required this.returnText,
    required this.clipboardBadge,
    required this.clipboardBadgeBorder,
    required this.clipboardLatestBorder,
    required this.clipboardLatestBadge,
    required this.keyboardBtnGradientStart,
    required this.keyboardBtnGradientEnd,
    required this.keyboardBtnBorder,
    required this.keyboardBtnGlow,
    required this.keyboardBtnIcon,
    required this.sheetBg,
    required this.sheetHandle,
    required this.sheetSearch,
    required this.sheetSearchBorder,
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
    keyGroupResting: Color(0x0FFFFFFF),       // rgba(255,255,255,0.06)
    keyGroupText: Color(0x73FFFFFF),          // rgba(255,255,255,0.45)
    keyGroupActive: Color(0x26E0A030),        // rgba(224,160,48,0.15)
    fanBtnResting: Color(0x0FFFFFFF),         // rgba(255,255,255,0.06)
    fanBtnActive: Color(0x1FE0A030),          // rgba(224,160,48,0.12)
    fanPopoverBg: Color(0xF214141E),          // rgba(20,20,30,0.95)
    symKeyResting: Color(0x0FFFFFFF),         // rgba(255,255,255,0.06)
    joystickFill: Color(0x0FFFFFFF),          // rgba(255,255,255,0.06)
    joystickBorder: Color(0x1AFFFFFF),        // rgba(255,255,255,0.10)
    joystickPressed: Color(0x1FE0A030),       // rgba(224,160,48,0.12)
    joystickPressedBorder: Color(0x40E0A030), // rgba(224,160,48,0.25)
    returnGradientStart: Color(0xFFE8B84A),   // opaque warm amber top
    returnGradientEnd: Color(0xFFC8922E),     // opaque warm amber bottom
    returnGlow: Color(0x26E0A030),            // rgba(224,160,48,0.15)
    returnText: Color(0xFF3D2800),            // warm dark brown
    clipboardBadge: Color(0xB3E0A030),        // rgba(224,160,48,0.7)
    clipboardBadgeBorder: Color(0xE6101018),  // rgba(16,16,24,0.9)
    clipboardLatestBorder: Color(0x6678B4FF), // rgba(120,180,255,0.4)
    clipboardLatestBadge: Color(0x9978B4FF),  // rgba(120,180,255,0.6)
    keyboardBtnGradientStart: Color(0x3378B4FF), // rgba(120,180,255,0.2)
    keyboardBtnGradientEnd: Color(0x1A508CDC),   // rgba(80,140,220,0.1)
    keyboardBtnBorder: Color(0x2678B4FF),     // rgba(120,180,255,0.15)
    keyboardBtnGlow: Color(0x1478B4FF),       // rgba(120,180,255,0.08)
    keyboardBtnIcon: Color(0xB378B4FF),       // rgba(120,180,255,0.7)
    sheetBg: Color(0xFA14141E),              // rgba(20,20,30,0.98)
    sheetHandle: Color(0x26FFFFFF),           // rgba(255,255,255,0.15)
    sheetSearch: Color(0x0AFFFFFF),           // rgba(255,255,255,0.04)
    sheetSearchBorder: Color(0x0FFFFFFF),     // rgba(255,255,255,0.06)
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
    keyGroupResting: Color(0x0A000000),       // rgba(0,0,0,0.04)
    keyGroupText: Color(0x61000000),          // rgba(0,0,0,0.38)
    keyGroupActive: Color(0x1FE0A030),        // rgba(224,160,48,0.12)
    fanBtnResting: Color(0x0A000000),         // rgba(0,0,0,0.04)
    fanBtnActive: Color(0x1AE0A030),          // rgba(224,160,48,0.10)
    fanPopoverBg: Color(0xEBFFFFFF),          // rgba(255,255,255,0.92)
    symKeyResting: Color(0x0A000000),         // rgba(0,0,0,0.04)
    joystickFill: Color(0x0A000000),          // rgba(0,0,0,0.04)
    joystickBorder: Color(0x0F000000),        // rgba(0,0,0,0.06)
    joystickPressed: Color(0x1AE0A030),       // rgba(224,160,48,0.10)
    joystickPressedBorder: Color(0x33E0A030), // rgba(224,160,48,0.20)
    returnGradientStart: Color(0xFFD4A030),   // opaque warm amber top
    returnGradientEnd: Color(0xFFB88228),     // opaque warm amber bottom
    returnGlow: Color(0x1AE0A030),            // rgba(224,160,48,0.10)
    returnText: Color(0xFF3D2800),            // warm dark brown
    clipboardBadge: Color(0xB3C08020),        // warm amber
    clipboardBadgeBorder: Color(0xE6F8F8FA),  // light background
    clipboardLatestBorder: Color(0x664080C0), // blue accent
    clipboardLatestBadge: Color(0x994080C0),  // blue accent
    keyboardBtnGradientStart: Color(0x264080C0),
    keyboardBtnGradientEnd: Color(0x1A3060A0),
    keyboardBtnBorder: Color(0x264080C0),
    keyboardBtnGlow: Color(0x144080C0),       // blue glow
    keyboardBtnIcon: Color(0xB34080C0),
    sheetBg: Color(0xFAF8F8FA),
    sheetHandle: Color(0x26000000),
    sheetSearch: Color(0x0A000000),
    sheetSearchBorder: Color(0x0F000000),
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
