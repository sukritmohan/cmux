import 'package:cmux_companion/app/theme.dart';
import 'package:cmux_companion/browser/url_bar.dart';
import 'package:cmux_companion/browser/url_rewriter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UrlBar', () {
    Widget buildUrlBar({
      String? url,
      bool canGoBack = false,
      bool canGoForward = false,
      bool isLoading = false,
    }) {
      return MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: UrlBar(
            url: url,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            isLoading: isLoading,
          ),
        ),
      );
    }

    testWidgets('renders back and forward navigation buttons', (tester) async {
      await tester.pumpWidget(buildUrlBar(url: 'https://example.com'));

      expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);
      expect(find.byIcon(Icons.arrow_forward_ios), findsOneWidget);
    });

    testWidgets('renders url field with styled text spans', (tester) async {
      await tester.pumpWidget(buildUrlBar(url: 'https://example.com/page'));

      expect(find.textContaining('https://'), findsOneWidget);
      expect(find.textContaining('example.com'), findsOneWidget);
    });

    testWidgets('shows placeholder when url is null', (tester) async {
      await tester.pumpWidget(buildUrlBar());

      expect(find.textContaining('Search or enter URL'), findsOneWidget);
    });

    testWidgets('shows reload button by default', (tester) async {
      await tester.pumpWidget(buildUrlBar(url: 'https://example.com'));

      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets('shows stop button when loading', (tester) async {
      await tester.pumpWidget(buildUrlBar(
        url: 'https://example.com',
        isLoading: true,
      ));

      expect(find.byIcon(Icons.close), findsOneWidget);
    });
  });

  group('URL Rewriter', () {
    test('classifies localhost as local', () {
      expect(classifyUrl('http://localhost:3000'), UrlClassification.local);
    });

    test('classifies 127.0.0.1 as local', () {
      expect(classifyUrl('http://127.0.0.1:8080'), UrlClassification.local);
    });

    test('classifies 0.0.0.0 as local', () {
      expect(classifyUrl('http://0.0.0.0:5173'), UrlClassification.local);
    });

    test('classifies external URLs as external', () {
      expect(classifyUrl('https://github.com'), UrlClassification.external);
      expect(classifyUrl('https://docs.example.com/api'), UrlClassification.external);
    });

    test('classifies Tailscale CGNAT IPs as local', () {
      expect(classifyUrl('http://100.100.1.1:3000'), UrlClassification.local);
      expect(classifyUrl('http://100.64.0.1:8080'), UrlClassification.local);
      expect(classifyUrl('http://100.127.255.255:80'), UrlClassification.local);
    });

    test('classifies non-Tailscale IPs as external', () {
      expect(classifyUrl('http://100.128.0.1:3000'), UrlClassification.external);
      expect(classifyUrl('http://192.168.1.1:3000'), UrlClassification.external);
    });

    test('rewrites localhost to Tailscale IP', () {
      expect(
        rewriteUrl('http://localhost:3000', '100.100.1.1'),
        'http://100.100.1.1:3000',
      );
    });

    test('rewrites 127.0.0.1 to Tailscale IP', () {
      expect(
        rewriteUrl('http://127.0.0.1:8080/api', '100.100.1.1'),
        'http://100.100.1.1:8080/api',
      );
    });

    test('does not rewrite external URLs', () {
      expect(
        rewriteUrl('https://github.com', '100.100.1.1'),
        'https://github.com',
      );
    });

    test('does not rewrite already-Tailscale URLs', () {
      expect(
        rewriteUrl('http://100.100.1.1:3000', '100.100.1.1'),
        'http://100.100.1.1:3000',
      );
    });

    test('parseDisplayUrl splits URL correctly', () {
      final result = parseDisplayUrl('https://example.com:3000/path?q=1');
      expect(result.scheme, 'https://');
      expect(result.host, 'example.com:3000');
      expect(result.path, '/path?q=1');
    });

    test('isTailscaleCgnat validates range correctly', () {
      expect(isTailscaleCgnat('100.64.0.0'), isTrue);
      expect(isTailscaleCgnat('100.127.255.255'), isTrue);
      expect(isTailscaleCgnat('100.63.255.255'), isFalse);
      expect(isTailscaleCgnat('100.128.0.0'), isFalse);
      expect(isTailscaleCgnat('99.64.0.0'), isFalse);
    });
  });
}
