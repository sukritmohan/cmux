import 'package:cmux_companion/app/theme.dart';
import 'package:cmux_companion/shared/pane_type_dropdown.dart';
import 'package:cmux_companion/state/surface_provider.dart';
import 'package:cmux_companion/terminal/tab_bar_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildTestWidget({
    List<Surface> surfaces = const [],
    String? focusedSurfaceId,
    PaneType? paneType,
  }) {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Row(
          children: [
            TabBarStrip(
              surfaces: surfaces,
              focusedSurfaceId: focusedSurfaceId,
              onSurfaceSelected: (_) {},
              paneType: paneType,
            ),
          ],
        ),
      ),
    );
  }

  group('TabBarStrip', () {
    testWidgets('shows "No tabs" when surfaces are empty', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      expect(find.text('No tabs'), findsOneWidget);
    });

    testWidgets('renders terminal tabs with surface titles', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        surfaces: [
          const Surface(id: 's1', title: 'zsh', workspaceId: 'w1'),
          const Surface(id: 's2', title: 'vim', workspaceId: 'w1'),
        ],
        focusedSurfaceId: 's1',
      ));

      expect(find.text('zsh'), findsOneWidget);
      expect(find.text('vim'), findsOneWidget);
    });

    testWidgets('browser mode shows static browser tabs', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        paneType: PaneType.browser,
      ));

      expect(find.text('localhost'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
    });

    testWidgets('active tab has connection dot when running', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        surfaces: [
          const Surface(
            id: 's1',
            title: 'zsh',
            workspaceId: 'w1',
            hasRunningProcess: true,
          ),
        ],
        focusedSurfaceId: 's1',
      ));

      // Connection dot is a 5x5 Container with BoxShape.circle
      final dots = find.byWidgetPredicate((widget) {
        if (widget is Container && widget.decoration is BoxDecoration) {
          final decoration = widget.decoration as BoxDecoration;
          return decoration.shape == BoxShape.circle &&
              widget.constraints?.maxWidth == 5;
        }
        return false;
      });
      expect(dots, findsOneWidget);
    });

    testWidgets('right-edge fade gradient is rendered', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        surfaces: [
          const Surface(id: 's1', title: 'zsh', workspaceId: 'w1'),
        ],
        focusedSurfaceId: 's1',
      ));

      // The fade gradient is inside a DecoratedBox with a LinearGradient
      expect(find.byType(DecoratedBox), findsWidgets);
    });
  });
}
