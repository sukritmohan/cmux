/// Riverpod notifier for surface (tab) state within the active workspace.
///
/// Tracks which surfaces exist in the current workspace and which one
/// is focused. Reacts to bridge events for surface focus/close/title changes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A terminal surface within a workspace.
class Surface {
  final String id;
  final String title;
  final String workspaceId;
  final bool hasRunningProcess;

  const Surface({
    required this.id,
    required this.title,
    required this.workspaceId,
    this.hasRunningProcess = false,
  });

  Surface copyWith({
    String? id,
    String? title,
    String? workspaceId,
    bool? hasRunningProcess,
  }) {
    return Surface(
      id: id ?? this.id,
      title: title ?? this.title,
      workspaceId: workspaceId ?? this.workspaceId,
      hasRunningProcess: hasRunningProcess ?? this.hasRunningProcess,
    );
  }
}

/// State held by [SurfaceNotifier].
class SurfaceState {
  final List<Surface> surfaces;
  final String? focusedSurfaceId;

  const SurfaceState({
    this.surfaces = const [],
    this.focusedSurfaceId,
  });

  Surface? get focusedSurface {
    if (focusedSurfaceId == null) return surfaces.firstOrNull;
    return surfaces
        .where((s) => s.id == focusedSurfaceId)
        .firstOrNull ?? surfaces.firstOrNull;
  }

  SurfaceState copyWith({
    List<Surface>? surfaces,
    String? focusedSurfaceId,
  }) {
    return SurfaceState(
      surfaces: surfaces ?? this.surfaces,
      focusedSurfaceId: focusedSurfaceId ?? this.focusedSurfaceId,
    );
  }
}

class SurfaceNotifier extends StateNotifier<SurfaceState> {
  SurfaceNotifier() : super(const SurfaceState());

  /// Replace all surfaces (e.g. after fetching workspace panels).
  void setSurfaces(List<Surface> surfaces, {String? focusedId}) {
    state = SurfaceState(
      surfaces: surfaces,
      focusedSurfaceId: focusedId ?? surfaces.firstOrNull?.id,
    );
  }

  /// Handle surface.focused event.
  void onSurfaceFocused(Map<String, dynamic> data) {
    final surfaceId = data['surface_id'] as String?;
    if (surfaceId == null) return;
    state = state.copyWith(focusedSurfaceId: surfaceId);
  }

  /// Handle surface.closed event.
  void onSurfaceClosed(Map<String, dynamic> data) {
    final surfaceId = data['surface_id'] as String?;
    if (surfaceId == null) return;

    final updated = state.surfaces.where((s) => s.id != surfaceId).toList();
    state = SurfaceState(
      surfaces: updated,
      focusedSurfaceId: state.focusedSurfaceId == surfaceId
          ? updated.firstOrNull?.id
          : state.focusedSurfaceId,
    );
  }

  /// Handle surface.title_changed event.
  void onSurfaceTitleChanged(Map<String, dynamic> data) {
    final surfaceId = data['surface_id'] as String?;
    final newTitle = data['title'] as String?;
    if (surfaceId == null || newTitle == null) return;

    final updated = state.surfaces.map((s) {
      if (s.id == surfaceId) return s.copyWith(title: newTitle);
      return s;
    }).toList();

    state = state.copyWith(surfaces: updated);
  }

  /// Handle surface.moved / surface.reordered events.
  void onSurfaceMoved(Map<String, dynamic> data) {
    // For now, just re-fetch will handle this. The event contains
    // workspace_id and surface_id for filtering if needed later.
  }

  /// Add a new surface and optionally focus it.
  void addSurface(Surface surface, {bool focus = true}) {
    final updated = [...state.surfaces, surface];
    state = SurfaceState(
      surfaces: updated,
      focusedSurfaceId: focus ? surface.id : state.focusedSurfaceId,
    );
  }

  /// Focus a specific surface by ID.
  void focusSurface(String surfaceId) {
    state = state.copyWith(focusedSurfaceId: surfaceId);
  }
}

final surfaceProvider =
    StateNotifierProvider<SurfaceNotifier, SurfaceState>((ref) {
  return SurfaceNotifier();
});
