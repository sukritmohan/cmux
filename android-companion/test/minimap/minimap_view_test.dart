import 'package:cmux_companion/app/theme.dart';
import 'package:cmux_companion/minimap/minimap_pane.dart';
import 'package:cmux_companion/minimap/minimap_view.dart';
import 'package:cmux_companion/state/pane_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Duration sufficient for the entry animation to finish (200ms) plus margin.
const _pumpDuration = Duration(milliseconds: 300);

void main() {
  /// Wraps the MinimapView in a MaterialApp with dark theme so
  /// AppColors.of(context) resolves correctly.
  ///
  /// Uses a SizedBox to provide a phone-sized surface (412 x 732)
  /// so the 16:10 aspect ratio layout does not overflow.
  Widget buildTestWidget({
    List<Pane> panes = const [],
    String? focusedPaneId,
    String? workspaceName,
    String? workspaceBranch,
    ValueChanged<String>? onPaneTapped,
    VoidCallback? onDismiss,
  }) {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: SizedBox(
          width: 412,
          height: 732,
          child: MinimapView(
            panes: panes,
            focusedPaneId: focusedPaneId,
            onPaneTapped: onPaneTapped ?? (_) {},
            onDismiss: onDismiss ?? () {},
            workspaceName: workspaceName,
            workspaceBranch: workspaceBranch,
          ),
        ),
      ),
    );
  }

  group('MinimapView header', () {
    testWidgets('renders WORKSPACE section header', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      // Use pump (not pumpAndSettle) because the LIVE dot pulses forever
      await tester.pump(_pumpDuration);

      expect(find.text('WORKSPACE'), findsOneWidget);
    });

    testWidgets('renders workspace name when provided', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        workspaceName: 'My Project',
      ));
      await tester.pump(_pumpDuration);

      expect(find.text('My Project'), findsOneWidget);
    });

    testWidgets('renders default workspace name when none provided',
        (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pump(_pumpDuration);

      expect(find.text('Workspace'), findsOneWidget);
    });

    testWidgets('renders LIVE badge', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pump(_pumpDuration);

      expect(find.text('LIVE'), findsOneWidget);
    });

    testWidgets('renders branch badge when branch is provided',
        (tester) async {
      await tester.pumpWidget(buildTestWidget(
        workspaceBranch: 'feat/minimap',
      ));
      await tester.pump(_pumpDuration);

      expect(find.text('feat/minimap'), findsOneWidget);
    });

    testWidgets('omits branch badge when branch is null', (tester) async {
      await tester.pumpWidget(buildTestWidget(workspaceBranch: null));
      await tester.pump(_pumpDuration);

      expect(find.text('feat/minimap'), findsNothing);
    });
  });

  group('MinimapView hint text', () {
    testWidgets('renders usage hint', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pump(_pumpDuration);

      expect(
        find.text('Tap a pane to focus \u00b7 Pinch in to dismiss'),
        findsOneWidget,
      );
    });
  });

  group('MinimapView pane rendering', () {
    testWidgets('shows "No panes" when list is empty', (tester) async {
      await tester.pumpWidget(buildTestWidget(panes: []));
      await tester.pump(_pumpDuration);

      expect(find.text('No panes'), findsOneWidget);
    });

    testWidgets('renders MinimapPane widgets for each pane', (tester) async {
      final panes = [
        const Pane(
          id: 'p1',
          type: 'terminal',
          x: 0,
          y: 0,
          width: 0.5,
          height: 1,
        ),
        const Pane(
          id: 'p2',
          type: 'browser',
          x: 0.5,
          y: 0,
          width: 0.5,
          height: 1,
        ),
      ];

      await tester.pumpWidget(buildTestWidget(panes: panes));
      await tester.pump(_pumpDuration);

      expect(find.byType(MinimapPane), findsNWidgets(2));
    });
  });

  group('MinimapView interactions', () {
    testWidgets('tapping background dismisses the minimap', (tester) async {
      var dismissed = false;

      await tester.pumpWidget(buildTestWidget(
        onDismiss: () => dismissed = true,
      ));
      await tester.pump(_pumpDuration);

      // Tap the outer GestureDetector (top-left corner, which is background)
      await tester.tapAt(const Offset(10, 10));
      // Pump repeatedly to complete the reverse animation (200ms controller)
      // and allow the async callback to fire after it finishes.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(dismissed, isTrue);
    });
  });

  group('MinimapPane stack badges', () {
    testWidgets('shows stack count badge for surfaceCount > 1',
        (tester) async {
      final panes = [
        const Pane(
          id: 'p1',
          type: 'terminal',
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          surfaceCount: 3,
        ),
      ];

      await tester.pumpWidget(buildTestWidget(panes: panes));
      await tester.pump(_pumpDuration);

      // The badge should show the count as text
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('does not show stack badge for surfaceCount == 1',
        (tester) async {
      final panes = [
        const Pane(
          id: 'p1',
          type: 'terminal',
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          surfaceCount: 1,
        ),
      ];

      await tester.pumpWidget(buildTestWidget(panes: panes));
      await tester.pump(_pumpDuration);

      // Verify the badge text '1' does not appear inside the MinimapPane
      final paneFinder = find.byType(MinimapPane);
      expect(paneFinder, findsOneWidget);

      expect(
        find.descendant(of: paneFinder, matching: find.text('1')),
        findsNothing,
      );
    });

    testWidgets('shows multiple stacked layers for surfaceCount > 1',
        (tester) async {
      final panes = [
        const Pane(
          id: 'p1',
          type: 'terminal',
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          surfaceCount: 4,
        ),
      ];

      await tester.pumpWidget(buildTestWidget(panes: panes));
      await tester.pump(_pumpDuration);

      // Badge should display the count
      expect(find.text('4'), findsOneWidget);
    });
  });
}
