import 'package:cmux_companion/app/colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper to get integer alpha (0-255) from a Color's `a` channel (0.0-1.0).
int _alpha(Color c) => (c.a * 255.0).round().clamp(0, 255);

void main() {
  group('AppColorScheme', () {
    test('dark scheme provides all non-transparent colors', () {
      const c = AppColors.dark;
      // Backgrounds should all be opaque
      expect(_alpha(c.bgDeep), 255);
      expect(_alpha(c.bgPrimary), 255);
      expect(_alpha(c.bgElevated), 255);
      expect(_alpha(c.bgSurface), 255);
      expect(_alpha(c.bgHover), 255);
      expect(_alpha(c.bgActive), 255);
      // Text should have reasonable opacity
      expect(_alpha(c.textPrimary), 255);
      expect(_alpha(c.textSecondary), greaterThan(0));
      expect(_alpha(c.textMuted), greaterThan(0));
      // Accent should be opaque
      expect(_alpha(c.accent), 255);
      expect(_alpha(c.accentText), 255);
      // Connected color should be opaque
      expect(_alpha(c.connectedColor), 255);
    });

    test('light scheme provides all non-transparent colors', () {
      const c = AppColors.light;
      expect(_alpha(c.bgDeep), 255);
      expect(_alpha(c.bgPrimary), 255);
      expect(_alpha(c.bgElevated), 255);
      expect(_alpha(c.bgSurface), 255);
      expect(_alpha(c.bgHover), 255);
      expect(_alpha(c.bgActive), 255);
      expect(_alpha(c.textPrimary), 255);
      expect(_alpha(c.textSecondary), greaterThan(0));
      expect(_alpha(c.textMuted), greaterThan(0));
      expect(_alpha(c.accent), 255);
      expect(_alpha(c.accentText), 255);
      expect(_alpha(c.connectedColor), 255);
    });

    test('dark and light have same accent base color', () {
      // The signature amber accent should be the same in both themes
      expect(AppColors.dark.accent, AppColors.light.accent);
    });

    test('dark backgrounds are darker than light backgrounds', () {
      expect(
        AppColors.dark.bgDeep.computeLuminance(),
        lessThan(AppColors.light.bgDeep.computeLuminance()),
      );
    });

    test('pane type colors are all distinct in dark scheme', () {
      const c = AppColors.dark;
      final colors = {c.terminalColor, c.browserColor, c.filesColor, c.overviewColor};
      expect(colors.length, 4, reason: 'All pane type colors should be unique');
    });

    test('pane type colors are all distinct in light scheme', () {
      const c = AppColors.light;
      final colors = {c.terminalColor, c.browserColor, c.filesColor, c.overviewColor};
      expect(colors.length, 4, reason: 'All pane type colors should be unique');
    });

    test('pane type bg colors have low alpha (tinted backgrounds)', () {
      const c = AppColors.dark;
      expect(_alpha(c.terminalBg), lessThan(128));
      expect(_alpha(c.browserBg), lessThan(128));
      expect(_alpha(c.filesBg), lessThan(128));
      expect(_alpha(c.overviewBg), lessThan(128));
    });
  });

  group('AppColors.of', () {
    testWidgets('returns dark scheme for dark theme', (tester) async {
      late AppColorScheme result;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Builder(
            builder: (context) {
              result = AppColors.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(result.bgDeep, AppColors.dark.bgDeep);
    });

    testWidgets('returns light scheme for light theme', (tester) async {
      late AppColorScheme result;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          home: Builder(
            builder: (context) {
              result = AppColors.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(result.bgDeep, AppColors.light.bgDeep);
    });
  });

  group('AppColors radii', () {
    test('radii are ordered from smallest to largest', () {
      expect(AppColors.radiusXs, lessThan(AppColors.radiusSm));
      expect(AppColors.radiusSm, lessThan(AppColors.radiusMd));
      expect(AppColors.radiusMd, lessThan(AppColors.radiusLg));
      expect(AppColors.radiusLg, lessThan(AppColors.radiusXl));
    });
  });
}
