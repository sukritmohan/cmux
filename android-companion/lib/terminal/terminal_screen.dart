/// Top-level terminal screen that orchestrates the full terminal experience.
///
/// Layout:
/// ```
/// ┌─────────────────────────────┐
/// │ [Tab Bar         ][Type ▼]  │  40px — TopBar
/// ├─────────────────────────────┤
/// │                             │
/// │  Terminal Content           │  flex:1 — TerminalView (pure renderer)
/// │                             │
/// ├─────────────────────────────┤
/// │ [Esc][Ctrl][Alt]  [←↓↑→]   │  52px — ModifierBar
/// └─────────────────────────────┘
/// ```
///
/// Also hosts: workspace drawer (left), minimap overlay, connection overlay.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/colors.dart';
import '../app/providers.dart';
import '../connection/connection_state.dart';
import '../minimap/minimap_view.dart';
import '../shared/connection_overlay.dart';
import '../shared/gesture_layer.dart';
import '../state/event_handler.dart';
import '../state/pane_provider.dart';
import '../state/surface_provider.dart';
import '../state/workspace_provider.dart';
import '../workspace/workspace_drawer.dart';
import 'modifier_bar.dart';
import 'terminal_view.dart';
import 'top_bar.dart';

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  StreamSubscription? _statusSub;
  bool _initialFetchDone = false;
  bool _showMinimap = false;

  @override
  void initState() {
    super.initState();
    _initConnection();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _initConnection() async {
    final manager = ref.read(connectionManagerProvider);
    final pairing = ref.read(pairingServiceProvider);

    final credentials = await pairing.loadCredentials();
    if (credentials == null) return;

    manager.setCredentials(
      host: credentials.host,
      port: credentials.port,
      token: credentials.token,
    );

    // Initialize event handler to start routing bridge events.
    ref.read(eventHandlerProvider);

    // Listen for connected status to fetch initial workspace data.
    _statusSub = manager.statusStream.listen((status) {
      if (status == ConnectionStatus.connected && !_initialFetchDone) {
        _initialFetchDone = true;
        _fetchInitialData();
      }
    });

    // Connect if not already connected.
    if (manager.status == ConnectionStatus.disconnected) {
      await manager.connect();
    } else if (manager.status == ConnectionStatus.connected) {
      _initialFetchDone = true;
      _fetchInitialData();
    }
  }

  Future<void> _fetchInitialData() async {
    final wsNotifier = ref.read(workspaceProvider.notifier);
    await wsNotifier.fetchWorkspaces();

    // Populate surfaces from the active workspace's panels.
    _syncSurfacesFromWorkspace();
  }

  /// Syncs the surface list from the active workspace's panels.
  void _syncSurfacesFromWorkspace() {
    final wsState = ref.read(workspaceProvider);
    final activeWs = wsState.activeWorkspace;
    if (activeWs == null) return;

    final surfaces = activeWs.panels
        .where((p) => p.type == 'terminal')
        .map((p) => Surface(
              id: p.id,
              title: p.title ?? 'Terminal',
              workspaceId: activeWs.id,
            ))
        .toList();

    ref.read(surfaceProvider.notifier).setSurfaces(
      surfaces,
      focusedId: activeWs.focusedPanelId,
    );
  }

  /// Called when a tab is tapped in the top bar.
  void _onSurfaceSelected(String surfaceId) {
    ref.read(surfaceProvider.notifier).focusSurface(surfaceId);
  }

  /// Called when a workspace is selected in the drawer.
  void _onWorkspaceSelected(String workspaceId) {
    ref.read(workspaceProvider.notifier).selectWorkspace(workspaceId);

    // Tell the Mac to switch workspace, then sync surfaces.
    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest(
      'workspace.select',
      params: {'workspace_id': workspaceId},
    ).then((_) => _syncSurfacesFromWorkspace());

    // Close the drawer.
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  /// Sends input to the focused surface's PTY.
  Future<void> _sendInput(String data) async {
    final surfaceState = ref.read(surfaceProvider);
    final surfaceId = surfaceState.focusedSurfaceId;
    if (surfaceId == null) return;

    try {
      final manager = ref.read(connectionManagerProvider);
      await manager.sendRequest(
        'surface.pty.write',
        params: {'surface_id': surfaceId, 'data': data},
      );
    } catch (e) {
      debugPrint('[TerminalScreen] Write error: $e');
    }
  }

  void _openMinimap() {
    // Fetch fresh layout data, then show the minimap.
    final wsState = ref.read(workspaceProvider);
    final activeWsId = wsState.activeWorkspaceId;
    if (activeWsId != null) {
      ref.read(paneProvider.notifier).fetchLayout(activeWsId);
    }
    setState(() => _showMinimap = true);
  }

  void _onMinimapPaneTapped(String paneId) {
    setState(() => _showMinimap = false);

    // Find the surface associated with this pane and focus it.
    final paneState = ref.read(paneProvider);
    final pane = paneState.panes.where((p) => p.id == paneId).firstOrNull;
    if (pane?.surfaceId != null) {
      _onSurfaceSelected(pane!.surfaceId!);
    }
  }

  /// Handles arrow swipe gestures from the gesture layer.
  void _onArrowSwipe(String direction) {
    final escSeq = switch (direction) {
      'left' => '\x1b[D',
      'right' => '\x1b[C',
      'up' => '\x1b[A',
      'down' => '\x1b[B',
      _ => null,
    };
    if (escSeq != null) _sendInput(escSeq);
  }

  @override
  Widget build(BuildContext context) {
    final connectionStatus =
        ref.watch(connectionStatusProvider).valueOrNull ??
            ConnectionStatus.disconnected;
    final surfaceState = ref.watch(surfaceProvider);
    final wsState = ref.watch(workspaceProvider);

    final focusedSurfaceId = surfaceState.focusedSurfaceId;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.bgPrimary,
      drawer: WorkspaceDrawer(
        workspaces: wsState.workspaces,
        activeWorkspaceId: wsState.activeWorkspaceId,
        onWorkspaceSelected: _onWorkspaceSelected,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // Main content column
            Column(
              children: [
                // Top bar: tab strip + pane type dropdown
                TopBar(
                  surfaces: surfaceState.surfaces,
                  focusedSurfaceId: focusedSurfaceId,
                  onSurfaceSelected: _onSurfaceSelected,
                  onMenuTap: _openDrawer,
                ),

                // Terminal content area with gesture layer
                Expanded(
                  child: GestureLayer(
                    callbacks: GestureCallbacks(
                      onOpenDrawer: _openDrawer,
                      onOpenMinimap: _openMinimap,
                      onArrowSwipe: _onArrowSwipe,
                    ),
                    child: focusedSurfaceId != null
                        ? TerminalView(
                            key: ValueKey(focusedSurfaceId),
                            surfaceId: focusedSurfaceId,
                            workspaceId: wsState.activeWorkspaceId,
                          )
                        : const Center(
                            child: Text(
                              'No terminal surfaces',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          ),
                  ),
                ),

                // Modifier bar
                ModifierBar(onInput: _sendInput),
              ],
            ),

            // Minimap overlay
            if (_showMinimap)
              MinimapView(
                panes: ref.watch(paneProvider).panes,
                focusedPaneId: ref.watch(paneProvider).focusedPaneId,
                onPaneTapped: _onMinimapPaneTapped,
                onDismiss: () => setState(() => _showMinimap = false),
              ),

            // Connection overlay (shown on top when not connected)
            if (connectionStatus != ConnectionStatus.connected)
              ConnectionOverlay(
                status: connectionStatus,
                onReconnect: _initConnection,
              ),
          ],
        ),
      ),
    );
  }
}
