/// Workspace drawer shown from the left edge.
///
/// Frosted glass backdrop with blur(40px), search bar, workspace list,
/// dark/light appearance toggle, and "+ New Workspace" button.
/// Width 280px (set via theme). Uses Riverpod to toggle theme mode.
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/colors.dart';
import '../app/providers.dart';
import '../app/theme.dart';
import '../state/workspace_provider.dart';
import 'workspace_tile.dart';

class WorkspaceDrawer extends ConsumerStatefulWidget {
  final List<Workspace> workspaces;
  final String? activeWorkspaceId;
  final ValueChanged<String> onWorkspaceSelected;
  final VoidCallback? onSettings;

  const WorkspaceDrawer({
    super.key,
    required this.workspaces,
    this.activeWorkspaceId,
    required this.onWorkspaceSelected,
    this.onSettings,
  });

  @override
  ConsumerState<WorkspaceDrawer> createState() => _WorkspaceDrawerState();
}

class _WorkspaceDrawerState extends ConsumerState<WorkspaceDrawer> {
  String _searchQuery = '';

  List<Workspace> get _filteredWorkspaces {
    if (_searchQuery.isEmpty) return widget.workspaces;
    final query = _searchQuery.toLowerCase();
    return widget.workspaces
        .where((ws) => ws.title.toLowerCase().contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final themeMode = ref.watch(themeModeProvider);

    return Drawer(
      backgroundColor: Colors.transparent,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Container(
            color: c.drawerBg,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: Text(
                      'WORKSPACES',
                      style: AppTheme.sectionHeader(c),
                    ),
                  ),

                  // Search bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _SearchBar(
                      colors: c,
                      onChanged: (value) {
                        setState(() => _searchQuery = value);
                      },
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Scrollable workspace list
                  Expanded(
                    child: _filteredWorkspaces.isEmpty
                        ? Center(
                            child: Text(
                              _searchQuery.isEmpty
                                  ? 'No workspaces'
                                  : 'No matches',
                              style: TextStyle(
                                color: c.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.only(top: 4),
                            itemCount: _filteredWorkspaces.length,
                            itemBuilder: (context, index) {
                              final ws = _filteredWorkspaces[index];
                              return WorkspaceTile(
                                workspace: ws,
                                isActive:
                                    ws.id == widget.activeWorkspaceId,
                                onTap: () =>
                                    widget.onWorkspaceSelected(ws.id),
                              );
                            },
                          ),
                  ),

                  // Bottom section — pinned, not scrollable
                  const Divider(height: 1),

                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    child: _AppearanceToggle(
                      colors: c,
                      isDark: themeMode == ThemeMode.dark,
                      onToggle: (isDark) {
                        ref.read(themeModeProvider.notifier).state =
                            isDark ? ThemeMode.dark : ThemeMode.light;
                      },
                    ),
                  ),

                  if (widget.onSettings != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: _SettingsButton(
                        colors: c,
                        onTap: widget.onSettings!,
                      ),
                    ),

                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    child: _NewWorkspaceButton(colors: c),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Search bar with magnifier icon and placeholder text.
class _SearchBar extends StatelessWidget {
  final AppColorScheme colors;
  final ValueChanged<String> onChanged;

  const _SearchBar({required this.colors, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: TextField(
        onChanged: onChanged,
        style: TextStyle(fontSize: 13, color: colors.textPrimary),
        decoration: InputDecoration(
          hintText: 'Search workspaces...',
          hintStyle: TextStyle(fontSize: 13, color: colors.textMuted),
          prefixIcon: Icon(
            Icons.search,
            size: 16,
            color: colors.textMuted,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 0,
          ),
          filled: true,
          fillColor: colors.bgSurface,
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            borderSide: BorderSide(color: colors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            borderSide: BorderSide(color: colors.borderStrong),
          ),
        ),
      ),
    );
  }
}

/// Segmented toggle between "Dark" and "Light" appearance modes.
class _AppearanceToggle extends StatelessWidget {
  final AppColorScheme colors;
  final bool isDark;
  final ValueChanged<bool> onToggle;

  const _AppearanceToggle({
    required this.colors,
    required this.isDark,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: colors.bgActive,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
      ),
      child: Row(
        children: [
          _SegmentButton(
            label: 'Dark',
            isActive: isDark,
            colors: colors,
            onTap: () => onToggle(true),
          ),
          _SegmentButton(
            label: 'Light',
            isActive: !isDark,
            colors: colors,
            onTap: () => onToggle(false),
          ),
        ],
      ),
    );
  }
}

/// A single segment within the appearance toggle.
class _SegmentButton extends StatelessWidget {
  final String label;
  final bool isActive;
  final AppColorScheme colors;
  final VoidCallback onTap;

  const _SegmentButton({
    required this.label,
    required this.isActive,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: isActive ? colors.bgSurface : Colors.transparent,
            borderRadius: BorderRadius.circular(AppColors.radiusMd - 2),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isActive ? colors.textPrimary : colors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings row with gear icon.
class _SettingsButton extends StatelessWidget {
  final AppColorScheme colors;
  final VoidCallback onTap;

  const _SettingsButton({required this.colors, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              Icons.settings_outlined,
              size: 16,
              color: colors.textMuted,
            ),
            const SizedBox(width: 8),
            Text(
              'Settings',
              style: TextStyle(
                fontSize: 13,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dashed-border button for creating a new workspace.
class _NewWorkspaceButton extends StatelessWidget {
  final AppColorScheme colors;

  const _NewWorkspaceButton({required this.colors});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        // Placeholder — workspace creation will be wired to the bridge API.
      },
      child: Container(
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
          border: Border.all(
            color: colors.border,
            // Solid border as a dashed-border approximation; true dashed
            // borders require a custom painter or external package, which
            // is not worth the dependency for a subtle visual hint.
          ),
        ),
        child: Text(
          '+ New Workspace',
          style: TextStyle(
            fontSize: 12,
            color: colors.textMuted,
          ),
        ),
      ),
    );
  }
}
