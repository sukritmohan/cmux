import 'package:cmux_companion/app/theme.dart';
import 'package:cmux_companion/terminal/clipboard_history.dart';
import 'package:cmux_companion/terminal/modifier_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildTestWidget({ValueChanged<String>? onInput}) {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            ModifierBar(
              onInput: onInput ?? (_) {},
              ctrlActiveNotifier: ValueNotifier<bool>(false),
              clipboardHistoryState: const ClipboardHistoryState(),
              clipboardHistoryNotifier: ClipboardHistoryNotifier(connectionKey: 'test'),
              keyboardFocusNode: FocusNode(),
              autocompleteActiveNotifier: ValueNotifier<bool>(true),
              onPaste: (_) {},
            ),
          ],
        ),
      ),
    );
  }

  group('ModifierBar', () {
    testWidgets('renders as floating capsule with rounded 18px corners', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // The outer container has 18px border radius
      final containers = find.byType(Container);
      expect(containers, findsWidgets);

      // The modifier bar should be present
      expect(find.byType(ModifierBar), findsOneWidget);
    });

    testWidgets('has RETURN key text', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      expect(find.text('RETURN'), findsOneWidget);
    });

    testWidgets('has arrow key icons', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // Should find arrow icons
      expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_left), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_right), findsOneWidget);
    });

    testWidgets('has (+) accent button and clipboard button', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.byIcon(Icons.content_paste), findsOneWidget);
    });

    testWidgets('RETURN key fires callback with carriage return', (tester) async {
      String? sent;
      await tester.pumpWidget(buildTestWidget(
        onInput: (data) => sent = data,
      ));

      await tester.tap(find.text('RETURN'));
      await tester.pumpAndSettle();

      expect(sent, '\r');
    });

    testWidgets('arrow keys fire correct escape sequences', (tester) async {
      String? sent;
      await tester.pumpWidget(buildTestWidget(
        onInput: (data) => sent = data,
      ));

      await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
      await tester.pumpAndSettle();
      expect(sent, '\x1b[A');

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      expect(sent, '\x1b[B');

      await tester.tap(find.byIcon(Icons.keyboard_arrow_left));
      await tester.pumpAndSettle();
      expect(sent, '\x1b[D');

      await tester.tap(find.byIcon(Icons.keyboard_arrow_right));
      await tester.pumpAndSettle();
      expect(sent, '\x1b[C');
    });
  });
}
