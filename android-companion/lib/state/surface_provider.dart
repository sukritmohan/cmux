/// Riverpod notifier for surface (tab) state within the active workspace.
///
/// Tracks which surfaces exist in the current workspace and which one
/// is focused. Reacts to bridge events for surface focus/close/title changes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../native/ghostty_vt.dart';

/// Snapshot of a surface's last known cell state for pre-rendering during swipe.
///
/// Stored by [SurfaceNotifier] whenever a new cell frame arrives so that the
/// adjacent terminal can be painted while the user drags between tabs.
class CellSnapshot {
  final List<CellData> cells;
  final int cols;
  final int rows;

  const CellSnapshot({
    required this.cells,
    required this.cols,
    required this.rows,
  });
}

/// A terminal surface within a workspace.
class Surface {
  final String id;
  final String title;
  final String workspaceId;
  final bool hasRunningProcess;
  final bool hasUnreadNotification;

  const Surface({
    required this.id,
    required this.title,
    required this.workspaceId,
    this.hasRunningProcess = false,
    this.hasUnreadNotification = false,
  });

  Surface copyWith({
    String? id,
    String? title,
    String? workspaceId,
    bool? hasRunningProcess,
    bool? hasUnreadNotification,
  }) {
    return Surface(
      id: id ?? this.id,
      title: title ?? this.title,
      workspaceId: workspaceId ?? this.workspaceId,
      hasRunningProcess: hasRunningProcess ?? this.hasRunningProcess,
      hasUnreadNotification: hasUnreadNotification ?? this.hasUnreadNotification,
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

  /// Zero-based index of the focused surface in [surfaces], or 0 if not found.
  int get focusedIndex {
    if (focusedSurfaceId == null) return 0;
    final index = surfaces.indexWhere((s) => s.id == focusedSurfaceId);
    return index == -1 ? 0 : index;
  }

  /// Whether more than one surface exists, enabling previous/next navigation.
  bool get hasMultipleSurfaces => surfaces.length > 1;

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

  /// Whether the Android app is currently backgrounded (paused/hidden).
  ///
  /// When true, all incoming attention events generate notification dots
  /// regardless of which surface is focused — the user cannot see the terminal.
  bool _isAppBackgrounded = false;

  /// Latest known cell state per surface, keyed by surface ID.
  ///
  /// Populated on every incoming cell frame so the adjacent terminal can be
  /// pre-rendered during a swipe gesture without subscribing to its stream.
  final Map<String, CellSnapshot> _cellSnapshots = {};

  /// Records the latest cell snapshot for [surfaceId].
  ///
  /// Called by [TerminalView] on every parsed cell frame so the snapshot is
  /// always current. The previous snapshot is silently replaced.
  void updateSnapshot(String surfaceId, List<CellData> cells, int cols, int rows) {
    _cellSnapshots[surfaceId] = CellSnapshot(cells: cells, cols: cols, rows: rows);
  }

  /// Returns the most recently stored [CellSnapshot] for [surfaceId], or null
  /// if no frame has arrived yet for that surface.
  CellSnapshot? getSnapshot(String surfaceId) => _cellSnapshots[surfaceId];

  /// Mark the app as backgrounded so all attention events produce dots.
  void setAppBackgrounded() {
    _isAppBackgrounded = true;
  }

  /// Mark the app as resumed (foregrounded).
  void setAppResumed() {
    _isAppBackgrounded = false;
  }

  /// Handle a surface.attention event by setting the notification dot.
  ///
  /// Suppresses the dot if the surface is already focused and the app is in
  /// the foreground — the user is already looking at that terminal.
  void onSurfaceAttention(Map<String, dynamic> data) {
    final surfaceId = data['surface_id'] as String?;
    if (surfaceId == null) return;

    // Don't show a dot for the surface the user is already viewing.
    if (surfaceId == state.focusedSurfaceId && !_isAppBackgrounded) return;

    final updated = state.surfaces.map((s) {
      if (s.id == surfaceId) return s.copyWith(hasUnreadNotification: true);
      return s;
    }).toList();

    state = state.copyWith(surfaces: updated);
  }

  /// Clear the notification dot on the currently focused surface.
  ///
  /// Called when the app resumes from background so the user does not see a
  /// stale dot on the tab they are already viewing.
  void clearNotificationForFocusedSurface() {
    final focusedId = state.focusedSurfaceId;
    if (focusedId == null) return;

    final updated = state.surfaces.map((s) {
      if (s.id == focusedId) return s.copyWith(hasUnreadNotification: false);
      return s;
    }).toList();

    state = state.copyWith(surfaces: updated);
  }

  /// Replace all surfaces (e.g. after fetching workspace panels).
  ///
  /// Preserves [hasUnreadNotification] from the previous state by matching
  /// on surface ID so notification dots survive a workspace refresh.
  void setSurfaces(List<Surface> surfaces, {String? focusedId}) {
    // Build a lookup of previous notification state.
    final previousNotifications = <String, bool>{
      for (final s in state.surfaces)
        if (s.hasUnreadNotification) s.id: true,
    };

    final merged = surfaces.map((s) {
      if (previousNotifications.containsKey(s.id)) {
        return s.copyWith(hasUnreadNotification: true);
      }
      return s;
    }).toList();

    state = SurfaceState(
      surfaces: merged,
      focusedSurfaceId: focusedId ?? surfaces.firstOrNull?.id,
    );
  }

  /// Handle surface.focused event.
  ///
  /// Also clears any notification dot on the newly focused surface since the
  /// user is now viewing it.
  void onSurfaceFocused(Map<String, dynamic> data) {
    final surfaceId = data['surface_id'] as String?;
    if (surfaceId == null) return;

    final updated = state.surfaces.map((s) {
      if (s.id == surfaceId) return s.copyWith(hasUnreadNotification: false);
      return s;
    }).toList();

    state = SurfaceState(
      surfaces: updated,
      focusedSurfaceId: surfaceId,
    );
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

    // Release the cached cell snapshot so the closed surface's render data
    // does not linger in memory indefinitely.
    _cellSnapshots.remove(surfaceId);
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
  ///
  /// Also clears any notification dot on the focused surface since the user
  /// is now viewing it.
  void focusSurface(String surfaceId) {
    final updated = state.surfaces.map((s) {
      if (s.id == surfaceId) return s.copyWith(hasUnreadNotification: false);
      return s;
    }).toList();

    state = SurfaceState(
      surfaces: updated,
      focusedSurfaceId: surfaceId,
    );
  }

  /// Returns the surface ID immediately after the focused surface in the list,
  /// or null if the focused surface is already the last one.
  String? nextSurfaceId() {
    final surfaces = state.surfaces;
    final currentIndex = state.focusedIndex;
    final isAtEnd = currentIndex >= surfaces.length - 1;
    if (isAtEnd) return null;
    return surfaces[currentIndex + 1].id;
  }

  /// Returns the surface ID immediately before the focused surface in the list,
  /// or null if the focused surface is already the first one.
  String? previousSurfaceId() {
    final currentIndex = state.focusedIndex;
    final isAtStart = currentIndex <= 0;
    if (isAtStart) return null;
    return state.surfaces[currentIndex - 1].id;
  }
}

final surfaceProvider =
    StateNotifierProvider<SurfaceNotifier, SurfaceState>((ref) {
  return SurfaceNotifier();
});
