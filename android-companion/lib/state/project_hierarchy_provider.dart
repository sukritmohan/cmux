/// Riverpod notifier for the project hierarchy sidebar state.
///
/// Fetches the project tree via `project.list`, tracks expand/collapse
/// overrides locally, and reacts to `project.updated` bridge events.
/// The hierarchy is three levels deep: Project > Branch > Workspace.
/// Linked terminals are included at the branch level for desktop parity.
///
/// This provider drives the drawer UI only. Active workspace tracking
/// and PTY/panel management remain in [WorkspaceNotifier].
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'workspace_provider.dart';

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// A project section in the sidebar hierarchy.
///
/// Each project corresponds to a git repository (or the synthetic "Other"
/// section for non-git workspaces). Contains one or more [SidebarBranch]
/// entries, each holding [Workspace] and [LinkedTerminalEntry] lists.
class SidebarProject {
  final String id;
  final String name;
  final String repoPath;

  /// Whether the desktop sidebar has this project expanded.
  /// Used as the initial value — the notifier's local override takes
  /// precedence once the user interacts on mobile.
  final bool desktopIsExpanded;

  final bool isAutoCreated;
  final int order;
  final List<SidebarBranch> branches;

  /// True for the synthetic "Other" section that holds non-git workspaces.
  final bool isOtherSection;

  const SidebarProject({
    required this.id,
    required this.name,
    this.repoPath = '',
    this.desktopIsExpanded = true,
    this.isAutoCreated = false,
    this.order = 0,
    this.branches = const [],
    this.isOtherSection = false,
  });

  factory SidebarProject.fromJson(Map<String, dynamic> json) {
    final branchList = (json['branches'] as List?)
            ?.map((b) => SidebarBranch.fromJson(b as Map<String, dynamic>))
            .toList() ??
        const [];

    return SidebarProject(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      repoPath: json['repo_path'] as String? ?? '',
      desktopIsExpanded: json['is_expanded'] as bool? ?? true,
      isAutoCreated: json['is_auto_created'] as bool? ?? false,
      order: json['order'] as int? ?? 0,
      branches: branchList,
      isOtherSection: json['is_other_section'] as bool? ?? false,
    );
  }

  /// Total unread notification count across all branches and workspaces.
  int get totalNotificationCount {
    int total = 0;
    for (final branch in branches) {
      total += branch.totalNotificationCount;
    }
    return total;
  }
}

/// A git branch within a [SidebarProject].
///
/// For the "Other" section, the branch name is an empty string and the
/// drawer should skip rendering the branch row, showing workspaces
/// directly under the project header.
class SidebarBranch {
  final String name;
  final bool isDirty;

  /// Whether the desktop sidebar has this branch expanded.
  /// Used as the initial value — the notifier's local override takes
  /// precedence once the user interacts on mobile.
  final bool desktopIsExpanded;

  /// Workspaces on this branch. Reuses [Workspace] from workspace_provider.
  final List<Workspace> workspaces;

  /// Terminals shared from other projects that appear under this branch.
  final List<LinkedTerminalEntry> linkedTerminals;

  const SidebarBranch({
    required this.name,
    this.isDirty = false,
    this.desktopIsExpanded = true,
    this.workspaces = const [],
    this.linkedTerminals = const [],
  });

  factory SidebarBranch.fromJson(Map<String, dynamic> json) {
    final workspaceList = (json['workspaces'] as List?)
            ?.map((w) => Workspace.fromJson(w as Map<String, dynamic>))
            .toList() ??
        const [];

    final linkedList = (json['linked_terminals'] as List?)
            ?.map(
                (lt) => LinkedTerminalEntry.fromJson(lt as Map<String, dynamic>))
            .toList() ??
        const [];

    return SidebarBranch(
      name: json['name'] as String? ?? '',
      isDirty: json['is_dirty'] as bool? ?? false,
      desktopIsExpanded: json['is_expanded'] as bool? ?? true,
      workspaces: workspaceList,
      linkedTerminals: linkedList,
    );
  }

  /// Total unread notification count across all workspaces on this branch.
  int get totalNotificationCount {
    int total = 0;
    for (final ws in workspaces) {
      total += ws.notificationCount;
    }
    return total;
  }
}

/// A terminal panel shared from another project/workspace.
///
/// Rendered as an italic sub-row under the branch, with a link icon and
/// "shared from {owningProjectName}/{owningWorkspaceName}" text.
class LinkedTerminalEntry {
  final String id;
  final String owningWorkspaceId;
  final String owningProjectName;
  final String owningWorkspaceName;
  final String panelId;

  const LinkedTerminalEntry({
    required this.id,
    required this.owningWorkspaceId,
    required this.owningProjectName,
    required this.owningWorkspaceName,
    required this.panelId,
  });

  factory LinkedTerminalEntry.fromJson(Map<String, dynamic> json) {
    return LinkedTerminalEntry(
      id: json['id'] as String? ?? '',
      owningWorkspaceId: json['owning_workspace_id'] as String? ?? '',
      owningProjectName: json['owning_project_name'] as String? ?? '',
      owningWorkspaceName: json['owning_workspace_name'] as String? ?? '',
      panelId: json['panel_id'] as String? ?? '',
    );
  }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Immutable state snapshot for [ProjectHierarchyNotifier].
class ProjectHierarchyState {
  /// Ordered list of project sections (excludes the "Other" section).
  final List<SidebarProject> projects;

  /// The synthetic "Other" section for non-git workspaces. Null when all
  /// workspaces belong to a git repo.
  final SidebarProject? otherProject;

  /// ID of the workspace currently active on the desktop.
  final String? activeWorkspaceId;

  /// True while a `project.list` request is in flight.
  final bool loading;

  /// True after the first successful `project.list` response has been applied.
  final bool hasLoaded;

  /// Whether the desktop supports `project.list`. False means the drawer
  /// should fall back to the flat workspace list from [WorkspaceNotifier].
  final bool isSupported;

  const ProjectHierarchyState({
    this.projects = const [],
    this.otherProject,
    this.activeWorkspaceId,
    this.loading = false,
    this.hasLoaded = false,
    this.isSupported = true,
  });

  ProjectHierarchyState copyWith({
    List<SidebarProject>? projects,
    SidebarProject? otherProject,
    String? activeWorkspaceId,
    bool? loading,
    bool? hasLoaded,
    bool? isSupported,
    // Sentinel to allow explicitly setting otherProject to null.
    bool clearOtherProject = false,
  }) {
    return ProjectHierarchyState(
      projects: projects ?? this.projects,
      otherProject:
          clearOtherProject ? null : (otherProject ?? this.otherProject),
      activeWorkspaceId: activeWorkspaceId ?? this.activeWorkspaceId,
      loading: loading ?? this.loading,
      hasLoaded: hasLoaded ?? this.hasLoaded,
      isSupported: isSupported ?? this.isSupported,
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

/// Manages the project hierarchy tree for the drawer sidebar.
///
/// Fetches the tree from the desktop via `project.list`, applies updates
/// from `project.updated` events, and tracks local expand/collapse overrides
/// so the mobile user can toggle independently of the desktop state.
class ProjectHierarchyNotifier extends StateNotifier<ProjectHierarchyState> {
  final Ref _ref;

  /// Local expand/collapse overrides for projects, keyed by project ID.
  /// Values override [SidebarProject.desktopIsExpanded].
  final Map<String, bool> _projectExpandOverrides = {};

  /// Local expand/collapse overrides for branches, keyed by
  /// "$projectId:$branchName". Values override
  /// [SidebarBranch.desktopIsExpanded].
  final Map<String, bool> _branchExpandOverrides = {};

  ProjectHierarchyNotifier(this._ref)
      : super(const ProjectHierarchyState());

  /// Fetch the full project hierarchy from the desktop bridge.
  ///
  /// On success, parses the response and updates state. If the desktop
  /// does not support `project.list` (older version), marks [isSupported]
  /// as false so the drawer falls back to the flat workspace list.
  Future<void> fetchProjectHierarchy() async {
    state = state.copyWith(loading: true);

    try {
      final manager = _ref.read(connectionManagerProvider);
      final response = await manager.sendRequest('project.list');
      debugPrint('[ProjectHierarchy] project.list response ok=${response.ok} result keys=${response.result?.keys} error=${response.error}');

      if (response.ok && response.result != null) {
        _applyResponse(response.result!);
        debugPrint('[ProjectHierarchy] applied: ${state.projects.length} projects, other=${state.otherProject != null}, active=${state.activeWorkspaceId}');
        return;
      }
    } catch (e) {
      debugPrint('[ProjectHierarchy] fetchProjectHierarchy error: $e');
    }

    debugPrint('[ProjectHierarchy] marking as unsupported, falling back to flat list');
    state = state.copyWith(loading: false, isSupported: false);
  }

  /// Handle a `project.updated` bridge event.
  ///
  /// If [data] contains the full tree, apply it directly. If empty
  /// (notification-only), re-fetch from the desktop.
  void onProjectUpdated(Map<String, dynamic> data) {
    if (data.isEmpty) {
      fetchProjectHierarchy();
    } else {
      _applyResponse(data);
    }
  }

  /// Whether a project section is expanded in the drawer.
  ///
  /// Returns the local override if the user has toggled it, otherwise
  /// falls back to the desktop's `is_expanded` value from the last fetch.
  bool isProjectExpanded(String projectId) {
    if (_projectExpandOverrides.containsKey(projectId)) {
      return _projectExpandOverrides[projectId]!;
    }

    // Fall back to desktop value from the model.
    for (final project in state.projects) {
      if (project.id == projectId) return project.desktopIsExpanded;
    }
    if (state.otherProject?.id == projectId) {
      return state.otherProject!.desktopIsExpanded;
    }

    // Unknown project — default to expanded.
    return true;
  }

  /// Whether a branch within a project is expanded in the drawer.
  ///
  /// Returns the local override if the user has toggled it, otherwise
  /// falls back to the desktop's `is_expanded` value from the last fetch.
  bool isBranchExpanded(String projectId, String branchName) {
    final key = '$projectId:$branchName';
    if (_branchExpandOverrides.containsKey(key)) {
      return _branchExpandOverrides[key]!;
    }

    // Fall back to desktop value from the model.
    final project = _findProject(projectId);
    if (project != null) {
      for (final branch in project.branches) {
        if (branch.name == branchName) return branch.desktopIsExpanded;
      }
    }

    // Unknown branch — default to expanded.
    return true;
  }

  /// Toggle the expand/collapse state of a project in the drawer.
  void toggleProjectExpanded(String projectId) {
    final current = isProjectExpanded(projectId);
    _projectExpandOverrides[projectId] = !current;
    // Trigger rebuild by emitting a new state reference.
    state = state.copyWith();
  }

  /// Toggle the expand/collapse state of a branch in the drawer.
  void toggleBranchExpanded(String projectId, String branchName) {
    final key = '$projectId:$branchName';
    final current = isBranchExpanded(projectId, branchName);
    _branchExpandOverrides[key] = !current;
    // Trigger rebuild by emitting a new state reference.
    state = state.copyWith();
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Parse a `project.list` response and update state.
  ///
  /// On the first load, initialises expand overrides from the desktop's
  /// `is_expanded` values. On subsequent loads, only initialises overrides
  /// for newly-appearing projects/branches (preserving the user's local
  /// toggles for known entries).
  void _applyResponse(Map<String, dynamic> result) {
    final projectList = (result['projects'] as List?)
            ?.map((p) => SidebarProject.fromJson(p as Map<String, dynamic>))
            .toList() ??
        [];

    final otherRaw = result['other_project'];
    final otherProject = otherRaw != null
        ? SidebarProject.fromJson(otherRaw as Map<String, dynamic>)
        : null;

    final activeId = result['active_workspace_id'] as String?;

    if (!state.hasLoaded) {
      _initExpandOverrides(projectList, otherProject);
    } else {
      _initExpandOverridesForNewEntries(projectList, otherProject);
    }

    state = ProjectHierarchyState(
      projects: projectList,
      otherProject: otherProject,
      activeWorkspaceId: activeId,
      loading: false,
      hasLoaded: true,
      isSupported: true,
    );
  }

  /// Seed expand overrides from the desktop's `is_expanded` values.
  ///
  /// Called once on the first successful fetch so that the mobile drawer
  /// starts with the same expand/collapse state as the desktop.
  void _initExpandOverrides(
    List<SidebarProject> projects,
    SidebarProject? other,
  ) {
    _projectExpandOverrides.clear();
    _branchExpandOverrides.clear();

    for (final project in projects) {
      _projectExpandOverrides[project.id] = project.desktopIsExpanded;
      for (final branch in project.branches) {
        final key = '${project.id}:${branch.name}';
        _branchExpandOverrides[key] = branch.desktopIsExpanded;
      }
    }

    if (other != null) {
      _projectExpandOverrides[other.id] = other.desktopIsExpanded;
      for (final branch in other.branches) {
        final key = '${other.id}:${branch.name}';
        _branchExpandOverrides[key] = branch.desktopIsExpanded;
      }
    }
  }

  /// Seed expand overrides only for projects and branches that are new
  /// (not already present in the override maps).
  ///
  /// Called on subsequent `project.updated` events to preserve the user's
  /// local toggles for known entries while picking up desktop defaults
  /// for newly-appearing projects or branches.
  void _initExpandOverridesForNewEntries(
    List<SidebarProject> projects,
    SidebarProject? other,
  ) {
    void seedIfNew(SidebarProject project) {
      if (!_projectExpandOverrides.containsKey(project.id)) {
        _projectExpandOverrides[project.id] = project.desktopIsExpanded;
      }
      for (final branch in project.branches) {
        final key = '${project.id}:${branch.name}';
        if (!_branchExpandOverrides.containsKey(key)) {
          _branchExpandOverrides[key] = branch.desktopIsExpanded;
        }
      }
    }

    for (final project in projects) {
      seedIfNew(project);
    }
    if (other != null) {
      seedIfNew(other);
    }
  }

  /// Find a project by ID in the current state (including otherProject).
  SidebarProject? _findProject(String projectId) {
    for (final project in state.projects) {
      if (project.id == projectId) return project;
    }
    if (state.otherProject?.id == projectId) return state.otherProject;
    return null;
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Riverpod provider for the project hierarchy sidebar state.
///
/// Used by the drawer to render the Project > Branch > Workspace tree.
/// Subscribe to this provider to rebuild the drawer when the hierarchy
/// changes or expand/collapse state is toggled.
final projectHierarchyProvider =
    StateNotifierProvider<ProjectHierarchyNotifier, ProjectHierarchyState>(
        (ref) {
  return ProjectHierarchyNotifier(ref);
});
