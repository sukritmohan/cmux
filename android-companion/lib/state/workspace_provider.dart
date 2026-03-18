/// Riverpod notifier for workspace state.
///
/// Fetches the workspace list via `workspace.list`, tracks the current
/// (active) workspace, and reacts to bridge events for create/close/rename.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';

/// A single workspace as returned by the bridge API.
class Workspace {
  final String id;
  final String title;
  final List<WorkspacePanel> panels;
  final String? focusedPanelId;

  /// Git branch name associated with this workspace, if any.
  final String? branch;

  /// Number of unread notifications for this workspace.
  final int notificationCount;

  const Workspace({
    required this.id,
    required this.title,
    this.panels = const [],
    this.focusedPanelId,
    this.branch,
    this.notificationCount = 0,
  });

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final panelList = (json['panels'] as List?)
            ?.map((p) => WorkspacePanel.fromJson(p as Map<String, dynamic>))
            .toList() ??
        const [];

    return Workspace(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      panels: panelList,
      focusedPanelId: json['focused_panel_id'] as String?,
      branch: json['branch'] as String?,
      notificationCount: json['notification_count'] as int? ?? 0,
    );
  }

  /// The first terminal panel's surface ID, or fallback to focusedPanelId.
  String? get primarySurfaceId {
    final terminal = panels.where((p) => p.type == 'terminal').firstOrNull;
    return terminal?.id ?? focusedPanelId;
  }

  Workspace copyWith({
    String? id,
    String? title,
    List<WorkspacePanel>? panels,
    String? focusedPanelId,
    String? branch,
    int? notificationCount,
  }) {
    return Workspace(
      id: id ?? this.id,
      title: title ?? this.title,
      panels: panels ?? this.panels,
      focusedPanelId: focusedPanelId ?? this.focusedPanelId,
      branch: branch ?? this.branch,
      notificationCount: notificationCount ?? this.notificationCount,
    );
  }
}

/// A panel within a workspace (terminal, browser, files, shell).
class WorkspacePanel {
  final String id;
  final String type;
  final String? title;

  const WorkspacePanel({
    required this.id,
    required this.type,
    this.title,
  });

  factory WorkspacePanel.fromJson(Map<String, dynamic> json) {
    return WorkspacePanel(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'terminal',
      title: json['title'] as String?,
    );
  }
}

/// State held by [WorkspaceNotifier].
class WorkspaceState {
  final List<Workspace> workspaces;
  final String? activeWorkspaceId;
  final bool loading;

  const WorkspaceState({
    this.workspaces = const [],
    this.activeWorkspaceId,
    this.loading = false,
  });

  Workspace? get activeWorkspace {
    if (activeWorkspaceId == null) return workspaces.firstOrNull;
    return workspaces
        .where((w) => w.id == activeWorkspaceId)
        .firstOrNull ?? workspaces.firstOrNull;
  }

  WorkspaceState copyWith({
    List<Workspace>? workspaces,
    String? activeWorkspaceId,
    bool? loading,
  }) {
    return WorkspaceState(
      workspaces: workspaces ?? this.workspaces,
      activeWorkspaceId: activeWorkspaceId ?? this.activeWorkspaceId,
      loading: loading ?? this.loading,
    );
  }
}

class WorkspaceNotifier extends StateNotifier<WorkspaceState> {
  final Ref _ref;

  WorkspaceNotifier(this._ref) : super(const WorkspaceState());

  /// Fetch the workspace list from the bridge.
  Future<void> fetchWorkspaces() async {
    state = state.copyWith(loading: true);

    try {
      final manager = _ref.read(connectionManagerProvider);
      final response = await manager.sendRequest('workspace.list');

      if (response.ok && response.result != null) {
        final list = response.result!['workspaces'];
        if (list is List) {
          final workspaces = list
              .cast<Map<String, dynamic>>()
              .map(Workspace.fromJson)
              .toList();

          state = state.copyWith(
            workspaces: workspaces,
            loading: false,
            // Preserve active workspace if it still exists, otherwise use first.
            activeWorkspaceId: _resolveActiveId(workspaces),
          );
          return;
        }
      }
    } catch (_) {
      // Connection not ready or request failed.
    }

    state = state.copyWith(loading: false);
  }

  /// Select a workspace as active.
  void selectWorkspace(String workspaceId) {
    state = state.copyWith(activeWorkspaceId: workspaceId);
  }

  /// Handle a workspace.created event.
  void onWorkspaceCreated(Map<String, dynamic> data) {
    final ws = Workspace.fromJson(data);
    if (ws.id.isEmpty) return;

    final updated = [...state.workspaces, ws];
    state = state.copyWith(workspaces: updated);
  }

  /// Handle a workspace.closed event.
  void onWorkspaceClosed(Map<String, dynamic> data) {
    final closedId = data['workspace_id'] as String?;
    if (closedId == null) return;

    final updated = state.workspaces.where((w) => w.id != closedId).toList();
    state = state.copyWith(
      workspaces: updated,
      activeWorkspaceId: state.activeWorkspaceId == closedId
          ? updated.firstOrNull?.id
          : state.activeWorkspaceId,
    );
  }

  /// Handle a workspace.title_changed event.
  void onWorkspaceTitleChanged(Map<String, dynamic> data) {
    final wsId = data['workspace_id'] as String?;
    final newTitle = data['title'] as String?;
    if (wsId == null || newTitle == null) return;

    final updated = state.workspaces.map((w) {
      if (w.id == wsId) return w.copyWith(title: newTitle);
      return w;
    }).toList();

    state = state.copyWith(workspaces: updated);
  }

  /// Handle a workspace.selected event (focus changed on Mac).
  void onWorkspaceSelected(Map<String, dynamic> data) {
    final wsId = data['workspace_id'] as String?;
    if (wsId == null) return;
    state = state.copyWith(activeWorkspaceId: wsId);
  }

  String? _resolveActiveId(List<Workspace> workspaces) {
    if (state.activeWorkspaceId != null &&
        workspaces.any((w) => w.id == state.activeWorkspaceId)) {
      return state.activeWorkspaceId;
    }
    return workspaces.firstOrNull?.id;
  }
}

final workspaceProvider =
    StateNotifierProvider<WorkspaceNotifier, WorkspaceState>((ref) {
  return WorkspaceNotifier(ref);
});
