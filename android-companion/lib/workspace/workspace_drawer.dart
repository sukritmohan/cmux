/// Workspace drawer shown from the left edge.
///
/// Frosted glass backdrop with blur(40px), project hierarchy tree,
/// dark/light appearance toggle, and settings button.
/// Width 280px (set via theme). Uses Riverpod for theme mode and
/// project hierarchy state.
///
/// The drawer renders a three-level tree: Project > Branch > Workspace.
/// If the desktop does not support `project.list`, falls back to the
/// flat workspace list from [WorkspaceNotifier].
///
/// Search filtering: toggling the search icon reveals a text field that
/// filters across project names, branch names, and workspace titles with
/// 150ms debounce. Matching substrings are highlighted in accent color.
/// When search is active, all matching items are forced expanded.
///
/// Notification badge bubbling: when a project or branch is collapsed,
/// aggregate unread counts from descendant workspaces are shown as a
/// badge on the collapsed row.
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/colors.dart';
import '../app/providers.dart';
import '../app/theme.dart';
import '../state/project_hierarchy_provider.dart';
import '../state/workspace_provider.dart';
import 'branch_row.dart';
import 'directory_browser.dart';
import 'linked_terminal_row.dart';
import 'project_row.dart';
import 'workspace_tile.dart';

class WorkspaceDrawer extends ConsumerStatefulWidget {
  /// Called when the user selects a workspace from the drawer.
  final ValueChanged<String> onWorkspaceSelected;

  /// Called when the user taps a linked terminal entry. The first argument
  /// is the owning workspace ID and the second is the panel ID to focus
  /// after the workspace switch completes.
  final void Function(String workspaceId, String panelId)?
      onLinkedTerminalSelected;

  /// Called when the user taps the settings button.
  final VoidCallback? onSettings;

  const WorkspaceDrawer({
    super.key,
    required this.onWorkspaceSelected,
    this.onLinkedTerminalSelected,
    this.onSettings,
  });

  @override
  ConsumerState<WorkspaceDrawer> createState() => _WorkspaceDrawerState();
}

class _WorkspaceDrawerState extends ConsumerState<WorkspaceDrawer> {
  /// Whether the search field is visible (toggled via the header icon).
  bool _isSearchActive = false;

  /// Current search query after debounce. Empty string means no filtering.
  String _searchQuery = '';

  /// Controller for the search text field.
  final TextEditingController _searchController = TextEditingController();

  /// Debounce timer for search input — 150ms delay before applying the
  /// query to avoid excessive rebuilds during fast typing.
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    // Kick off the project hierarchy fetch if not already loaded.
    final state = ref.read(projectHierarchyProvider);
    if (!state.hasLoaded && !state.loading) {
      // Schedule after the first frame so ref is fully available.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(projectHierarchyProvider.notifier).fetchProjectHierarchy();
      });
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Called on every keystroke in the search field. Debounces the query
  /// update by 150ms so we don't rebuild the tree on every character.
  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        setState(() => _searchQuery = value.trim());
      }
    });
  }

  /// Toggle search visibility. When hiding, clear the query and text field.
  void _toggleSearch() {
    setState(() {
      _isSearchActive = !_isSearchActive;
      if (!_isSearchActive) {
        _searchQuery = '';
        _searchController.clear();
        _debounceTimer?.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final themeMode = ref.watch(themeModeProvider);
    final hierarchyState = ref.watch(projectHierarchyProvider);
    final wsState = ref.watch(workspaceProvider);

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
                  // Header: "PROJECTS" + search toggle icon
                  _buildHeader(c),

                  // Animated search field that slides in when toggled.
                  _buildAnimatedSearchField(c),

                  const SizedBox(height: 8),

                  // Scrollable project hierarchy tree
                  Expanded(
                    child: _buildContent(c, hierarchyState, wsState),
                  ),

                  // Bottom section — pinned, not scrollable
                  const Divider(height: 1),

                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    child: _AppearanceToggle(
                      colors: c,
                      isDark: themeMode == ThemeMode.dark,
                      onToggle: (isDark) {
                        ref.read(themeModeProvider.notifier).setThemeMode(
                            isDark ? ThemeMode.dark : ThemeMode.light);
                      },
                    ),
                  ),

                  if (widget.onSettings != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                      child: _SettingsButton(
                        colors: c,
                        onTap: widget.onSettings!,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  /// "PROJECTS" label with add-project and search toggle buttons on the right.
  Widget _buildHeader(AppColorScheme c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
      child: Row(
        children: [
          Text('PROJECTS', style: AppTheme.sectionHeader(c)),
          const Spacer(),
          GestureDetector(
            onTap: _openProject,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(AppColors.radiusXs),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.add,
                size: 16,
                color: c.textMuted,
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: _toggleSearch,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _isSearchActive
                    ? const Color(0x26E0A030) // rgba(224,160,48,0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppColors.radiusXs),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.search,
                size: 16,
                color: _isSearchActive ? c.accent : c.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Animated search field that slides in/out below the header.
  ///
  /// Uses [AnimatedCrossFade] for a smooth height transition between
  /// visible and hidden states.
  Widget _buildAnimatedSearchField(AppColorScheme c) {
    return AnimatedCrossFade(
      firstChild: const SizedBox.shrink(),
      secondChild: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: SizedBox(
          height: 32,
          child: TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            autofocus: true,
            style: TextStyle(fontSize: 13, color: c.textPrimary),
            decoration: InputDecoration(
              hintText: 'Search projects...',
              hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
              prefixIcon: Icon(
                Icons.search,
                size: 14,
                color: c.textMuted,
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 0,
              ),
              filled: true,
              fillColor: c.bgSurface,
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.radiusSm),
                borderSide: BorderSide(color: c.borderStrong),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.radiusSm),
                borderSide: BorderSide(color: c.borderStrong),
              ),
            ),
          ),
        ),
      ),
      crossFadeState: _isSearchActive
          ? CrossFadeState.showSecond
          : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 200),
    );
  }

  // ---------------------------------------------------------------------------
  // Content area
  // ---------------------------------------------------------------------------

  /// Builds the main scrollable content based on the hierarchy state.
  ///
  /// Three modes:
  /// 1. Loading shimmer — while the first `project.list` response is pending.
  /// 2. Flat fallback — when the desktop does not support `project.list`.
  /// 3. Hierarchy tree — the normal three-level tree.
  Widget _buildContent(
    AppColorScheme c,
    ProjectHierarchyState hierarchyState,
    WorkspaceState wsState,
  ) {
    // Mode 1: desktop does not support project.list — flat fallback.
    // Check this BEFORE hasLoaded because a failed project.list sets
    // isSupported=false while hasLoaded stays false.
    if (!hierarchyState.isSupported) {
      return _buildFlatFallback(c, wsState);
    }

    // Mode 2: loading shimmer before the first successful response.
    if (!hierarchyState.hasLoaded) {
      return _buildSkeleton(c);
    }

    // Mode 3: project hierarchy tree.
    return _buildHierarchyTree(c, hierarchyState, wsState);
  }

  /// Shimmer skeleton shown while waiting for the first `project.list`.
  /// Three rows at different indent levels to hint at the tree structure.
  Widget _buildSkeleton(AppColorScheme c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SkeletonRow(indent: 8, width: 120, height: 14, color: c.bgSurface),
          const SizedBox(height: 10),
          _SkeletonRow(
              indent: 24, width: 80, height: 12, color: c.bgSurface),
          const SizedBox(height: 8),
          _SkeletonRow(
              indent: 42, width: 100, height: 13, color: c.bgSurface),
        ],
      ),
    );
  }

  /// Flat workspace list — used when the desktop does not support
  /// `project.list`. Mirrors the pre-hierarchy drawer layout.
  Widget _buildFlatFallback(AppColorScheme c, WorkspaceState wsState) {
    if (wsState.workspaces.isEmpty) {
      return Center(
        child: Text(
          'No workspaces',
          style: TextStyle(color: c.textMuted, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 4),
      itemCount: wsState.workspaces.length,
      itemBuilder: (context, index) {
        final ws = wsState.workspaces[index];
        return WorkspaceTile(
          workspace: ws,
          isActive: ws.id == wsState.activeWorkspaceId,
          onTap: () => widget.onWorkspaceSelected(ws.id),
        );
      },
    );
  }

  /// Builds the full project > branch > workspace hierarchy tree.
  ///
  /// When search is active, the tree is filtered to show only matching
  /// items and all matches are forced expanded. When search is inactive,
  /// the normal expand/collapse state from the notifier is used.
  Widget _buildHierarchyTree(
    AppColorScheme c,
    ProjectHierarchyState hierarchyState,
    WorkspaceState wsState,
  ) {
    final notifier = ref.read(projectHierarchyProvider.notifier);
    final allProjects = <SidebarProject>[
      ...hierarchyState.projects,
      if (hierarchyState.otherProject != null) hierarchyState.otherProject!,
    ];

    if (allProjects.isEmpty) {
      return Center(
        child: Text(
          'No projects',
          style: TextStyle(color: c.textMuted, fontSize: 13),
        ),
      );
    }

    // Apply search filtering when a query is active.
    final isSearching = _searchQuery.isNotEmpty;
    final displayProjects =
        isSearching ? _filterProjects(allProjects, _searchQuery) : allProjects;

    if (isSearching && displayProjects.isEmpty) {
      return Center(
        child: Text(
          'No results',
          style: TextStyle(color: c.textMuted, fontSize: 13),
        ),
      );
    }

    // The query string to pass for highlight rendering. Empty when not
    // searching so widgets skip the RichText path.
    final highlightQuery = isSearching ? _searchQuery : null;

    // Build a flat widget list from the nested tree so ListView can
    // efficiently render only visible items.
    final widgets = <Widget>[];

    for (var i = 0; i < displayProjects.length; i++) {
      final project = displayProjects[i];

      // When searching, force all items expanded to show matches.
      // When not searching, use the notifier's expand/collapse state.
      final projectExpanded =
          isSearching || notifier.isProjectExpanded(project.id);

      // Aggregate notification count for badge bubbling on collapsed rows.
      final projectNotifications = project.totalNotificationCount;

      // Project header row.
      widgets.add(
        ProjectRow(
          project: project,
          isExpanded: projectExpanded,
          isFirst: i == 0,
          onTap: isSearching
              ? () {} // Disable collapse toggle during search.
              : () => notifier.toggleProjectExpanded(project.id),
          highlightQuery: highlightQuery,
          aggregateNotificationCount:
              projectExpanded ? 0 : projectNotifications,
        ),
      );

      if (!projectExpanded) continue;

      // Iterate branches within the expanded project.
      for (final branch in project.branches) {
        final branchExpanded = isSearching ||
            notifier.isBranchExpanded(project.id, branch.name);

        // For the "Other" section, the branch name is empty — skip the
        // branch row and render workspaces directly under the project.
        final skipBranchRow =
            project.isOtherSection && branch.name.isEmpty;

        // Aggregate notification count for this branch.
        final branchNotifications = branch.totalNotificationCount;

        if (!skipBranchRow) {
          widgets.add(
            BranchRow(
              branch: branch,
              isExpanded: branchExpanded,
              onTap: isSearching
                  ? () {} // Disable collapse toggle during search.
                  : () =>
                      notifier.toggleBranchExpanded(project.id, branch.name),
              onAddWorkspace: () => _createWorkspace(project.repoPath),
              highlightQuery: highlightQuery,
              aggregateNotificationCount:
                  branchExpanded ? 0 : branchNotifications,
            ),
          );
        }

        // Show children when the branch is expanded, or when we skipped
        // the branch row entirely (Other section — always show workspaces).
        if (!branchExpanded && !skipBranchRow) continue;

        // Workspace rows.
        final activeId =
            hierarchyState.activeWorkspaceId ?? wsState.activeWorkspaceId;

        for (final ws in branch.workspaces) {
          widgets.add(
            WorkspaceTile(
              workspace: ws,
              isActive: ws.id == activeId,
              onTap: () => widget.onWorkspaceSelected(ws.id),
              onLongPress: () => _showWorkspaceRenameDialog(ws),
              highlightQuery: highlightQuery,
            ),
          );
        }

        // Linked terminal rows — italic entries showing terminals shared
        // from other projects. Tapping navigates to the owning workspace.
        for (final lt in branch.linkedTerminals) {
          widgets.add(
            LinkedTerminalRow(
              entry: lt,
              onTap: () {
                if (widget.onLinkedTerminalSelected != null &&
                    lt.panelId.isNotEmpty) {
                  widget.onLinkedTerminalSelected!(
                      lt.owningWorkspaceId, lt.panelId);
                } else {
                  widget.onWorkspaceSelected(lt.owningWorkspaceId);
                }
              },
            ),
          );
        }
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
      children: widgets,
    );
  }

  // ---------------------------------------------------------------------------
  // Search filtering
  // ---------------------------------------------------------------------------

  /// Filters the project list to only include items that match [query].
  ///
  /// Matching rules (case-insensitive substring):
  /// - Project name matches: all its branches and workspaces are included.
  /// - Branch name matches: all its workspaces are included, parent project
  ///   is shown.
  /// - Workspace title matches: parent branch and project are shown, but
  ///   only the matching workspace(s) within that branch.
  ///
  /// Returns a new list of [SidebarProject] with only matching subtrees.
  /// Non-matching projects are excluded entirely.
  List<SidebarProject> _filterProjects(
    List<SidebarProject> projects,
    String query,
  ) {
    final lowerQuery = query.toLowerCase();
    final result = <SidebarProject>[];

    for (final project in projects) {
      final projectMatches = project.name.toLowerCase().contains(lowerQuery);

      if (projectMatches) {
        // Project name matches — include all branches and workspaces.
        result.add(project);
        continue;
      }

      // Check branches and workspaces within this project.
      final filteredBranches = <SidebarBranch>[];

      for (final branch in project.branches) {
        final branchMatches = branch.name.toLowerCase().contains(lowerQuery);

        if (branchMatches) {
          // Branch name matches — include all its workspaces.
          filteredBranches.add(branch);
          continue;
        }

        // Check individual workspaces.
        final matchingWorkspaces = branch.workspaces
            .where((ws) => ws.title.toLowerCase().contains(lowerQuery))
            .toList();

        if (matchingWorkspaces.isNotEmpty) {
          // Some workspaces match — include only those workspaces
          // under this branch.
          filteredBranches.add(SidebarBranch(
            name: branch.name,
            isDirty: branch.isDirty,
            desktopIsExpanded: branch.desktopIsExpanded,
            workspaces: matchingWorkspaces,
            linkedTerminals: branch.linkedTerminals,
          ));
        }
      }

      if (filteredBranches.isNotEmpty) {
        result.add(SidebarProject(
          id: project.id,
          name: project.name,
          repoPath: project.repoPath,
          desktopIsExpanded: project.desktopIsExpanded,
          isAutoCreated: project.isAutoCreated,
          order: project.order,
          branches: filteredBranches,
          isOtherSection: project.isOtherSection,
        ));
      }
    }

    return result;
  }

  /// Shows a rename dialog for a workspace when long-pressed in the sidebar.
  void _showWorkspaceRenameDialog(Workspace ws) {
    final controller = TextEditingController(text: ws.title);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Workspace'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Workspace name'),
          onSubmitted: (_) {
            Navigator.pop(ctx);
            final newTitle = controller.text.trim();
            if (newTitle.isNotEmpty && newTitle != ws.title) {
              _renameWorkspace(ws.id, newTitle);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              final newTitle = controller.text.trim();
              if (newTitle.isNotEmpty && newTitle != ws.title) {
                _renameWorkspace(ws.id, newTitle);
              }
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  /// Sends a workspace rename command to the desktop via the bridge and
  /// optimistically updates local state so the sidebar reflects the new
  /// name immediately.
  void _renameWorkspace(String workspaceId, String title) {
    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest('workspace.rename', params: {
      'workspace_id': workspaceId,
      'title': title,
    });
    // Optimistically update both providers so the UI reflects the rename
    // without waiting for the desktop event round-trip.
    ref.read(workspaceProvider.notifier).onWorkspaceTitleChanged({
      'workspace_id': workspaceId,
      'title': title,
    });
    ref.read(projectHierarchyProvider.notifier).fetchProjectHierarchy();
  }

  /// Opens the directory browser to let the user pick a project folder
  /// on the desktop filesystem.
  void _openProject() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const DirectoryBrowser(),
      ),
    );
  }

  /// Creates a new workspace via the bridge, scoped to [repoPath].
  void _createWorkspace(String repoPath) {
    final manager = ref.read(connectionManagerProvider);
    final params = <String, dynamic>{};
    if (repoPath.isNotEmpty) {
      params['cwd'] = repoPath;
    }
    manager.sendRequest('workspace.create', params: params);
  }
}

// =============================================================================
// Private helper widgets
// =============================================================================

/// A single skeleton shimmer row used during loading state.
class _SkeletonRow extends StatelessWidget {
  final double indent;
  final double width;
  final double height;
  final Color color;

  const _SkeletonRow({
    required this.indent,
    required this.width,
    required this.height,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
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
