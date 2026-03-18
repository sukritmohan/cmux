import 'package:cmux_companion/app/colors.dart';
import 'package:cmux_companion/app/theme.dart';
import 'package:cmux_companion/shared/pane_type_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PaneType enum', () {
    test('has four values: terminal, browser, files, overview', () {
      expect(PaneType.values.length, 4);
      expect(PaneType.values, contains(PaneType.terminal));
      expect(PaneType.values, contains(PaneType.browser));
      expect(PaneType.values, contains(PaneType.files));
      expect(PaneType.values, contains(PaneType.overview));
    });

    test('each type has unique icon and label', () {
      final labels = PaneType.values.map((t) => t.label).toSet();
      expect(labels.length, 4, reason: 'All labels should be unique');

      final icons = PaneType.values.map((t) => t.icon).toSet();
      expect(icons.length, 4, reason: 'All icons should be unique');
    });

    test('color() returns distinct colors for dark scheme', () {
      const c = AppColors.dark;
      final colors = PaneType.values.map((t) => t.color(c)).toSet();
      expect(colors.length, 4, reason: 'All type colors should be unique');
    });

    test('bgColor() returns semi-transparent tints', () {
      const c = AppColors.dark;
      for (final type in PaneType.values) {
        final bg = type.bgColor(c);
        final alpha = (bg.a * 255.0).round().clamp(0, 255);
        expect(alpha, lessThan(128),
            reason: '${type.label} bgColor should be semi-transparent');
      }
    });
  });

  group('PaneTypeDropdown widget', () {
    Widget buildTestWidget({
      PaneType activeType = PaneType.terminal,
      ValueChanged<PaneType>? onTypeSelected,
    }) {
      return MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Center(
            child: PaneTypeDropdown(
              activeType: activeType,
              onTypeSelected: onTypeSelected,
            ),
          ),
        ),
      );
    }

    testWidgets('renders icon-only trigger button', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // Should find the trigger (36x36 container with icon)
      final icons = find.byType(Icon);
      expect(icons, findsWidgets);
    });

    testWidgets('tap opens overlay with all pane types', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // Tap the trigger to open the dropdown
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      // All four type labels should be visible in the overlay
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('Browser'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Overview'), findsOneWidget);
    });

    testWidgets('selecting a type fires callback', (tester) async {
      PaneType? selected;

      await tester.pumpWidget(buildTestWidget(
        onTypeSelected: (type) => selected = type,
      ));

      // Open dropdown
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      // Tap "Browser" option
      await tester.tap(find.text('Browser'));
      await tester.pumpAndSettle();

      expect(selected, PaneType.browser);
    });

    testWidgets('active type shows checkmark', (tester) async {
      await tester.pumpWidget(buildTestWidget(activeType: PaneType.terminal));

      // Open dropdown
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      // Should find a check icon (for the active item)
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });
}
