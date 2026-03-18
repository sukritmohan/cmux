/// Design tokens for the cmux companion app.
///
/// Merged palette from the gesture-driven and pane-type-switcher mockups.
/// GitHub-dark backgrounds with selective vibrancy for accents and states.
library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  // -- Backgrounds --
  /// Main background (deepest layer).
  static const bgPrimary = Color(0xFF0D1117);

  /// Cards, bars, elevated surfaces.
  static const bgSecondary = Color(0xFF161B22);

  /// Active states, key backgrounds.
  static const bgTertiary = Color(0xFF21262D);

  /// Inset panels (e.g. drawer content area).
  static const bgSurface = Color(0xFF1C2128);

  // -- Text --
  static const textPrimary = Color(0xFFE6EDF3);
  static const textSecondary = Color(0xFF8B949E);
  static const textMuted = Color(0xFF484F58);

  // -- Accents --
  /// Primary accent — tabs, links, active states.
  static const accentBlue = Color(0xFF58A6FF);

  /// Running / connected indicators.
  static const accentGreen = Color(0xFF3FB950);

  /// Warnings, reconnecting.
  static const accentOrange = Color(0xFFD29922);

  /// Errors, destructive actions.
  static const accentRed = Color(0xFFF85149);

  /// Shell type indicator.
  static const accentPurple = Color(0xFFBC8CFF);

  /// Secondary accent.
  static const accentCyan = Color(0xFF39D2C0);

  // -- Borders --
  static const borderSubtle = Color(0xFF30363D);
  static const borderActive = Color(0xFF58A6FF);

  // -- Chips --
  /// rgba(88, 166, 255, 0.12)
  static const chipBg = Color(0x1F58A6FF);

  /// rgba(88, 166, 255, 0.24)
  static const chipBgActive = Color(0x3D58A6FF);

  // -- Radii --
  static const radiusSm = 6.0;
  static const radiusMd = 10.0;
  static const radiusLg = 16.0;
  static const radiusXl = 20.0;

  // -- Terminal defaults (used by the painter) --
  static const terminalFg = Color(0xFFE6EDF3);
  static const terminalBg = Color(0xFF0D1117);
  static const terminalCursor = Color(0xFF58A6FF);
}
