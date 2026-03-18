import 'package:cmux_companion/app/theme.dart';
import 'package:cmux_companion/browser/browser_view.dart';
import 'package:cmux_companion/browser/url_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildTestWidget() {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: const Scaffold(
        body: BrowserView(),
      ),
    );
  }

  group('BrowserView', () {
    testWidgets('renders UrlBar and mock web content area', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // UrlBar should be present
      expect(find.byType(UrlBar), findsOneWidget);

      // Mock web content containers should exist (shimmer blocks are rendered
      // inside _MockWebContent which uses FractionallySizedBox children)
      expect(find.byType(FractionallySizedBox), findsWidgets);
    });

    testWidgets('url bar displays the mock URL with scheme and host',
        (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // The URL is rendered as a Text.rich with TextSpan children,
      // so we use textContaining to match within the RichText widget.
      expect(find.textContaining('https://'), findsOneWidget);
      expect(find.textContaining('localhost'), findsOneWidget);
    });
  });

  group('UrlBar', () {
    Widget buildUrlBar({
      bool canGoBack = false,
      bool canGoForward = false,
    }) {
      return MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: UrlBar(
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            url: const MockUrl(
              scheme: 'https://',
              host: 'example.com',
              path: '/page',
            ),
          ),
        ),
      );
    }

    testWidgets('renders back and forward navigation buttons', (tester) async {
      await tester.pumpWidget(buildUrlBar());

      // Should find two navigation button icons (back and forward)
      expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);
      expect(find.byIcon(Icons.arrow_forward_ios), findsOneWidget);
    });

    testWidgets('renders url field with styled text spans', (tester) async {
      await tester.pumpWidget(buildUrlBar());

      // The URL is rendered as a Text.rich with TextSpan children,
      // so we use textContaining to match within the RichText widget.
      expect(find.textContaining('https://'), findsOneWidget);
      expect(find.textContaining('example.com'), findsOneWidget);
    });
  });
}
