/// File explorer view with breadcrumb navigation, scrollable file list, and
/// bottom action bar.
///
/// Uses static mock data to render a realistic file browser layout.
import 'package:flutter/material.dart';

import '../app/colors.dart';
import 'breadcrumb_bar.dart';
import 'file_action_bar.dart';
import 'file_list_item.dart';

/// Static mock file entries for the explorer view.
const _mockFiles = [
  FileEntry(name: 'Sources', isFolder: true),
  FileEntry(name: 'Tests', isFolder: true),
  FileEntry(name: 'Resources', isFolder: true),
  FileEntry(name: 'AppDelegate.swift', isFolder: false, size: '12.4 KB', extension: 'swift'),
  FileEntry(name: 'ContentView.swift', isFolder: false, size: '8.2 KB', extension: 'swift'),
  FileEntry(name: 'Theme.swift', isFolder: false, size: '3.1 KB', extension: 'swift'),
  FileEntry(name: 'config.json', isFolder: false, size: '1.8 KB', extension: 'json'),
];

class FileExplorerView extends StatelessWidget {
  const FileExplorerView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Column(
      children: [
        // Breadcrumb path bar
        const BreadcrumbBar(
          segments: ['~', 'cmux', 'Sources'],
        ),

        // Scrollable file list
        Expanded(
          child: Container(
            color: c.bgDeep,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _mockFiles.length,
              itemBuilder: (context, index) {
                return FileListItem(entry: _mockFiles[index]);
              },
            ),
          ),
        ),

        // Bottom action bar
        const FileActionBar(),
      ],
    );
  }
}
