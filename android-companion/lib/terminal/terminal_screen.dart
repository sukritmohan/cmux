/// Top-level terminal screen that orchestrates the full terminal experience.
///
/// Layout:
/// ```
/// ┌─────────────────────────────┐
/// │ [Tab Bar         ][Type ▼]  │  42px — TopBar
/// ├─────────────────────────────┤
/// │                             │
/// │  Pane Content (per type)    │  flex:1 — Terminal/Browser/Files
/// │                             │
/// ├─────────────────────────────┤
/// │ [Esc][Ctrl][Alt]  [←↓↑→]   │  44px — ModifierBar (terminal+browser)
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
import '../browser/browser_view.dart';
import '../connection/connection_state.dart';
import '../files/file_explorer_view.dart';
import '../minimap/minimap_view.dart';
import '../shared/connection_overlay.dart';
import '../shared/gesture_layer.dart';
import '../shared/pane_type_dropdown.dart';
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
  PaneType _activePaneType = PaneType.terminal;

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

  void _onSurfaceSelected(String surfaceId) {
    ref.read(surfaceProvider.notifier).focusSurface(surfaceId);
  }

  void _onWorkspaceSelected(String workspaceId) {
    ref.read(workspaceProvider.notifier).selectWorkspace(workspaceId);

    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest(
      'workspace.select',
      params: {'workspace_id': workspaceId},
    ).then((_) => _syncSurfacesFromWorkspace());

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
    final wsState = ref.read(workspaceProvider);
    final activeWsId = wsState.activeWorkspaceId;
    if (activeWsId != null) {
      ref.read(paneProvider.notifier).fetchLayout(activeWsId);
    }
    setState(() => _showMinimap = true);
  }

  void _onMinimapPaneTapped(String paneId) {
    setState(() => _showMinimap = false);

    final paneState = ref.read(paneProvider);
    final pane = paneState.panes.where((p) => p.id == paneId).firstOrNull;
    if (pane?.surfaceId != null) {
      _onSurfaceSelected(pane!.surfaceId!);
    }
  }

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

  void _onPaneTypeChanged(PaneType type) {
    if (type == PaneType.overview) {
      _openMinimap();
      return;
    }
    setState(() => _activePaneType = type);
  }

  /// Whether the modifier bar should be shown for the current pane type.
  bool get _showModifierBar =>
      _activePaneType == PaneType.terminal || _activePaneType == PaneType.browser;

  /// Builds the content area for the current pane type.
  Widget _buildPaneContent(String? focusedSurfaceId, String? activeWorkspaceId) {
    final c = AppColors.of(context);

    switch (_activePaneType) {
      case PaneType.terminal:
        return GestureLayer(
          callbacks: GestureCallbacks(
            onOpenDrawer: _openDrawer,
            onOpenMinimap: _openMinimap,
            onArrowSwipe: _onArrowSwipe,
          ),
          child: focusedSurfaceId != null
              ? TerminalView(
                  key: ValueKey(focusedSurfaceId),
                  surfaceId: focusedSurfaceId,
                  workspaceId: activeWorkspaceId,
                )
              : Center(
                  child: Text(
                    'No terminal surfaces',
                    style: TextStyle(color: c.textSecondary),
                  ),
                ),
        );

      case PaneType.browser:
        return const BrowserView();

      case PaneType.files:
        return const FileExplorerView();

      case PaneType.overview:
        // Overview is handled by minimap overlay, not inline content.
        // Shouldn't reach here because _onPaneTypeChanged opens minimap.
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final connectionStatus =
        ref.watch(connectionStatusProvider).valueOrNull ??
            ConnectionStatus.disconnected;
    final surfaceState = ref.watch(surfaceProvider);
    final wsState = ref.watch(workspaceProvider);

    final focusedSurfaceId = surfaceState.focusedSurfaceId;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.bgDeep,
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
                // Top bar: tab strip + pane type icon
                TopBar(
                  surfaces: surfaceState.surfaces,
                  focusedSurfaceId: focusedSurfaceId,
                  onSurfaceSelected: _onSurfaceSelected,
                  onMenuTap: _openDrawer,
                  activePaneType: _activePaneType,
                  onPaneTypeChanged: _onPaneTypeChanged,
                ),

                // Content area — switches by pane type
                Expanded(
                  child: _buildPaneContent(
                    focusedSurfaceId,
                    wsState.activeWorkspaceId,
                  ),
                ),

                // Modifier bar (only for terminal + browser)
                if (_showModifierBar) ModifierBar(onInput: _sendInput),
              ],
            ),

            // Minimap overlay
            if (_showMinimap)
              MinimapView(
                panes: ref.watch(paneProvider).panes,
                focusedPaneId: ref.watch(paneProvider).focusedPaneId,
                onPaneTapped: _onMinimapPaneTapped,
                onDismiss: () => setState(() => _showMinimap = false),
                workspaceName: wsState.activeWorkspace?.title,
                workspaceBranch: wsState.activeWorkspace?.branch,
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
