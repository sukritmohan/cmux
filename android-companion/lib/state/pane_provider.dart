/// Riverpod notifier for pane layout state.
///
/// Holds the spatial layout of panes within the active workspace,
/// derived from the `workspace.layout` API response. Used by the
/// minimap overlay to render proportional pane rectangles.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';

/// A pane in the workspace layout tree.
class Pane {
  final String id;
  final String? surfaceId;
  final String type; // 'terminal', 'browser', 'files', 'shell'
  final double x; // Proportional 0..1
  final double y;
  final double width;
  final double height;
  final bool focused;

  /// Number of surfaces/tabs stacked in this pane (1 = single surface).
  final int surfaceCount;

  const Pane({
    required this.id,
    this.surfaceId,
    this.type = 'terminal',
    this.x = 0,
    this.y = 0,
    this.width = 1,
    this.height = 1,
    this.focused = false,
    this.surfaceCount = 1,
  });

  factory Pane.fromJson(Map<String, dynamic> json) {
    return Pane(
      id: json['id'] as String? ?? '',
      surfaceId: json['surface_id'] as String?,
      type: json['type'] as String? ?? 'terminal',
      x: (json['x'] as num?)?.toDouble() ?? 0,
      y: (json['y'] as num?)?.toDouble() ?? 0,
      width: (json['width'] as num?)?.toDouble() ?? 1,
      height: (json['height'] as num?)?.toDouble() ?? 1,
      focused: json['focused'] as bool? ?? false,
      surfaceCount: (json['surface_count'] as int?) ?? 1,
    );
  }

  Pane copyWith({bool? focused, int? surfaceCount}) {
    return Pane(
      id: id,
      surfaceId: surfaceId,
      type: type,
      x: x,
      y: y,
      width: width,
      height: height,
      focused: focused ?? this.focused,
      surfaceCount: surfaceCount ?? this.surfaceCount,
    );
  }
}

/// State held by [PaneNotifier].
class PaneState {
  final List<Pane> panes;
  final String? focusedPaneId;

  const PaneState({
    this.panes = const [],
    this.focusedPaneId,
  });

  PaneState copyWith({
    List<Pane>? panes,
    String? focusedPaneId,
  }) {
    return PaneState(
      panes: panes ?? this.panes,
      focusedPaneId: focusedPaneId ?? this.focusedPaneId,
    );
  }
}

class PaneNotifier extends StateNotifier<PaneState> {
  final Ref _ref;

  PaneNotifier(this._ref) : super(const PaneState());

  /// Fetch the pane layout for a workspace.
  Future<void> fetchLayout(String workspaceId) async {
    try {
      final manager = _ref.read(connectionManagerProvider);
      final response = await manager.sendRequest(
        'workspace.layout',
        params: {'workspace_id': workspaceId},
      );

      if (response.ok && response.result != null) {
        final paneList = response.result!['panes'];
        if (paneList is List) {
          final panes = paneList
              .cast<Map<String, dynamic>>()
              .map(Pane.fromJson)
              .toList();

          final focusedId = response.result!['focused_pane_id'] as String?;
          state = PaneState(panes: panes, focusedPaneId: focusedId);
          return;
        }
      }
    } catch (_) {
      // Layout not available yet.
    }
  }

  /// Handle pane.focused event.
  void onPaneFocused(Map<String, dynamic> data) {
    final paneId = data['pane_id'] as String?;
    if (paneId == null) return;

    final updated = state.panes.map((p) {
      return p.copyWith(focused: p.id == paneId);
    }).toList();

    state = PaneState(panes: updated, focusedPaneId: paneId);
  }

  /// Handle pane.split event — refetch layout since proportions change.
  void onPaneSplit(Map<String, dynamic> data) {
    final wsId = data['workspace_id'] as String?;
    if (wsId != null) fetchLayout(wsId);
  }

  /// Handle pane.closed event — refetch layout since proportions change.
  void onPaneClosed(Map<String, dynamic> data) {
    final wsId = data['workspace_id'] as String?;
    if (wsId != null) fetchLayout(wsId);
  }
}

final paneProvider = StateNotifierProvider<PaneNotifier, PaneState>((ref) {
  return PaneNotifier(ref);
});
