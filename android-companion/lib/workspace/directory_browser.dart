/// Full-screen directory browser for picking a project folder on the desktop.
///
/// Fetches directory listings from the desktop via the `directory.list` bridge
/// command and lets the user navigate the filesystem. Tapping "Open Here"
/// creates a new workspace at the current directory via `workspace.create`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/colors.dart';
import '../app/providers.dart';

/// A single entry returned by `directory.list`.
class _DirEntry {
  final String name;
  final String path;
  final bool isDirectory;

  const _DirEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
  });

  factory _DirEntry.fromJson(Map<String, dynamic> json) {
    return _DirEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      isDirectory: json['is_directory'] as bool? ?? false,
    );
  }
}

/// Directory browser screen shown when the user taps "+" in the drawer header.
///
/// Navigates the desktop filesystem and creates a workspace at the selected
/// directory.
class DirectoryBrowser extends ConsumerStatefulWidget {
  const DirectoryBrowser({super.key});

  @override
  ConsumerState<DirectoryBrowser> createState() => _DirectoryBrowserState();
}

class _DirectoryBrowserState extends ConsumerState<DirectoryBrowser> {
  String _currentPath = '';
  List<_DirEntry> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Start at home directory (no path param = default to home).
    _fetchDirectory(null);
  }

  /// Fetches directory contents from the desktop via bridge command.
  Future<void> _fetchDirectory(String? path) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final manager = ref.read(connectionManagerProvider);
    final params = <String, dynamic>{
      'directories_only': true,
    };
    if (path != null && path.isNotEmpty) {
      params['path'] = path;
    }

    try {
      final response = await manager.sendRequest('directory.list', params: params);
      if (!mounted) return;

      if (response.ok && response.result != null) {
        final result = response.result!;
        final rawEntries = result['entries'] as List<dynamic>? ?? [];
        setState(() {
          _currentPath = result['path'] as String? ?? path ?? '';
          _entries = rawEntries
              .map((e) => _DirEntry.fromJson(e as Map<String, dynamic>))
              .toList();
          _loading = false;
        });
      } else {
        setState(() {
          _error = response.error?.message ?? 'Failed to list directory';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Connection error';
        _loading = false;
      });
    }
  }

  /// Navigate to parent directory.
  void _goUp() {
    if (_currentPath.isEmpty) return;
    // Go up one level by removing the last path component.
    final parent = _currentPath.substring(
      0,
      _currentPath.lastIndexOf('/'),
    );
    // Don't go above root.
    _fetchDirectory(parent.isEmpty ? '/' : parent);
  }

  /// Create a workspace at the current directory and close the browser.
  void _openHere() {
    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest('workspace.create', params: {
      'cwd': _currentPath,
    });
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1A1A1F) : const Color(0xFFF5F5F7),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: c.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Open Project',
          style: GoogleFonts.ibmPlexSans(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: c.textPrimary,
          ),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Current path bar with up button.
          _buildPathBar(c, isDark),

          // Directory listing.
          Expanded(child: _buildBody(c, isDark)),

          // "Open Here" button.
          _buildOpenButton(c),
        ],
      ),
    );
  }

  Widget _buildPathBar(AppColorScheme c, bool isDark) {
    // Extract a short display path: show last 2 components with ellipsis.
    final displayPath = _currentPath.isEmpty ? '~' : _currentPath;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252530) : const Color(0xFFEAEAEF),
      ),
      child: Row(
        children: [
          // Up button.
          GestureDetector(
            onTap: _goUp,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF35354A)
                    : const Color(0xFFDDDDE5),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.arrow_upward,
                size: 16,
                color: c.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Path display.
          Expanded(
            child: Text(
              displayPath,
              style: GoogleFonts.ibmPlexMono(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: c.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppColorScheme c, bool isDark) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          color: c.accent,
          strokeWidth: 2,
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: c.textMuted, size: 32),
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: c.textMuted, fontSize: 13)),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => _fetchDirectory(_currentPath),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_entries.isEmpty) {
      return Center(
        child: Text(
          'Empty directory',
          style: TextStyle(color: c.textMuted, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _DirectoryEntryRow(
          entry: entry,
          colors: c,
          isDark: isDark,
          onTap: () {
            if (entry.isDirectory) {
              _fetchDirectory(entry.path);
            }
          },
        );
      },
    );
  }

  Widget _buildOpenButton(AppColorScheme c) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton(
            onPressed: _loading ? null : _openHere,
            style: ElevatedButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: 0,
            ),
            child: Text(
              'Open Here',
              style: GoogleFonts.ibmPlexSans(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single directory entry row in the listing.
class _DirectoryEntryRow extends StatelessWidget {
  final _DirEntry entry;
  final AppColorScheme colors;
  final bool isDark;
  final VoidCallback onTap;

  const _DirectoryEntryRow({
    required this.entry,
    required this.colors,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              entry.isDirectory ? Icons.folder : Icons.insert_drive_file,
              size: 20,
              color: entry.isDirectory
                  ? const Color(0xFFE0A030)
                  : colors.textMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                entry.name,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: colors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (entry.isDirectory)
              Icon(
                Icons.chevron_right,
                size: 16,
                color: colors.textMuted,
              ),
          ],
        ),
      ),
    );
  }
}
