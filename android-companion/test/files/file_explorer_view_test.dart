import 'package:cmux_companion/app/theme.dart';
import 'package:cmux_companion/files/breadcrumb_bar.dart';
import 'package:cmux_companion/files/file_action_bar.dart';
import 'package:cmux_companion/files/file_explorer_view.dart';
import 'package:cmux_companion/files/file_list_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildTestWidget() {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: const Scaffold(
        body: FileExplorerView(),
      ),
    );
  }

  group('FileExplorerView', () {
    testWidgets('renders BreadcrumbBar and file list items', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // BreadcrumbBar should be present
      expect(find.byType(BreadcrumbBar), findsOneWidget);

      // File list items should render (7 mock entries)
      expect(find.byType(FileListItem), findsNWidgets(7));
    });

    testWidgets('renders file action bar at the bottom', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // FileActionBar should be present
      expect(find.byType(FileActionBar), findsOneWidget);

      // Action buttons should have their labels
      expect(find.text('+ New File'), findsOneWidget);
      expect(find.text('+ New Folder'), findsOneWidget);
      expect(find.text('Sort'), findsOneWidget);
    });

    testWidgets('folder items show chevron, file items show size',
        (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // Folder names should be present
      expect(find.text('Sources'), findsWidgets); // Also in breadcrumb
      expect(find.text('Tests'), findsOneWidget);
      expect(find.text('Resources'), findsOneWidget);

      // Chevrons for folders (unicode right-pointing angle)
      // There are 3 folders, each showing a chevron
      expect(find.text('\u203A'), findsWidgets);

      // File sizes should be present
      expect(find.text('12.4 KB'), findsOneWidget);
      expect(find.text('8.2 KB'), findsOneWidget);
      expect(find.text('3.1 KB'), findsOneWidget);
      expect(find.text('1.8 KB'), findsOneWidget);
    });

    testWidgets('breadcrumb shows correct path segments', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // Path segments should be visible
      expect(find.text('~'), findsOneWidget);
      expect(find.text('cmux'), findsOneWidget);
      // 'Sources' appears both in breadcrumb and as a folder name
      expect(find.text('Sources'), findsWidgets);
    });
  });

  group('FileListItem', () {
    testWidgets('folder entry renders folder icon and chevron',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(
            body: FileListItem(
              entry: FileEntry(name: 'MyFolder', isFolder: true),
            ),
          ),
        ),
      );

      expect(find.text('MyFolder'), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      expect(find.text('\u203A'), findsOneWidget);
    });

    testWidgets('file entry renders size text instead of chevron',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(
            body: FileListItem(
              entry: FileEntry(
                name: 'main.swift',
                isFolder: false,
                size: '5.0 KB',
                extension: 'swift',
              ),
            ),
          ),
        ),
      );

      expect(find.text('main.swift'), findsOneWidget);
      expect(find.text('5.0 KB'), findsOneWidget);
      // Should not show a chevron for files
      expect(find.text('\u203A'), findsNothing);
    });
  });
}
