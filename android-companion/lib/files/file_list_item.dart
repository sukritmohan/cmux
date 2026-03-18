/// A single row in the file explorer list.
///
/// Shows a typed icon (colored by file type), the file name, and either
/// a size string (for files) or a chevron (for folders).
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/colors.dart';

/// Describes one entry in the file list — either a folder or a file.
class FileEntry {
  final String name;
  final bool isFolder;

  /// Human-readable size (e.g. "12.4 KB"). Only meaningful for files.
  final String? size;

  /// File extension used to pick the icon color scheme (e.g. "swift", "json").
  final String? extension;

  const FileEntry({
    required this.name,
    required this.isFolder,
    this.size,
    this.extension,
  });
}

class FileListItem extends StatelessWidget {
  final FileEntry entry;

  const FileListItem({
    super.key,
    required this.entry,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.border),
        ),
      ),
      child: Row(
        children: [
          // Typed icon
          _buildIcon(c),
          const SizedBox(width: 12),

          // File name
          Expanded(
            child: Text(
              entry.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: c.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Size (files) or chevron (folders)
          if (entry.isFolder)
            Text(
              '\u203A', // right-pointing angle
              style: TextStyle(
                fontSize: 11,
                color: c.textMuted,
              ),
            )
          else if (entry.size != null)
            Text(
              entry.size!,
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11,
                color: c.textMuted,
              ),
            ),
        ],
      ),
    );
  }

  /// Builds the 28x28 icon container with colors based on entry type.
  Widget _buildIcon(AppColorScheme c) {
    final (bg, fg, icon) = _iconStyle(c);

    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      child: Icon(icon, size: 14, color: fg),
    );
  }

  /// Returns (background, foreground, icon) for the entry type.
  (Color, Color, IconData) _iconStyle(AppColorScheme c) {
    if (entry.isFolder) {
      return (c.filesBg, c.filesColor, Icons.folder_outlined);
    }

    // Pick colors by file extension
    return switch (entry.extension) {
      'swift' => (c.browserBg, c.browserColor, Icons.code),
      'json' => (c.overviewBg, c.overviewColor, Icons.data_object),
      _ => (c.filesBg, c.filesColor, Icons.insert_drive_file_outlined),
    };
  }
}
