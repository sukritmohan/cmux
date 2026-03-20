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
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

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
import 'attachment_service.dart';
import 'attachment_strip.dart';
import 'terminal_snapshot_painter.dart';
import 'clipboard_history.dart';
import 'modifier_bar.dart';
import 'terminal_view.dart';
import 'top_bar.dart';
import 'voice_protocol.dart';
import 'voice_service.dart';
import 'voice_strip.dart';

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with TickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  StreamSubscription? _statusSub;
  bool _showMinimap = false;
  PaneType _activePaneType = PaneType.terminal;

  /// Fractional scroll remainder for smooth sub-line accumulation.
  double _scrollRemainder = 0.0;

  // ── Swipe-to-switch-tab animation state ──────────────────────────────────

  /// Drives commit/cancel/rubber-band spring animations for tab swiping.
  late AnimationController _swipeAnimController;

  /// Current horizontal pixel offset: 0 = rest, negative = left, positive = right.
  final _swipeOffset = ValueNotifier<double>(0.0);

  /// The surface being swiped toward (null when no swipe in progress).
  String? _swipeTargetSurfaceId;

  /// True while a spring animation is in flight so a new touch can snap it.
  bool _isSwipeAnimating = false;

  /// Tracks whether the current swipe has crossed the 35% commit threshold.
  ///
  /// Reset to false at the start of each swipe gesture. Flipped to true (with
  /// a light haptic) the first time displacement exceeds the threshold. Reset
  /// to false (silently) if the finger retreats back below the threshold so
  /// that the light haptic can fire again if the user re-crosses.
  bool _hasPassedCommitThreshold = false;

  /// Notifier incremented on scroll to tell TerminalView to clear selection.
  final _scrollNotifier = ValueNotifier<int>(0);

  /// Ctrl modifier state from the modifier bar, shared with terminal view
  /// so soft keyboard input can be intercepted (e.g., Ctrl+C → \x03).
  final _ctrlActiveNotifier = ValueNotifier<bool>(false);

  /// Autocomplete/suggestion toggle state. Default ON so swipe typing works
  /// out of the box. Resets to ON each app launch (no persistence).
  final _autocompleteActiveNotifier = ValueNotifier<bool>(true);

  /// Focus node shared between keyboard button and terminal view for
  /// programmatic soft keyboard toggle.
  final _keyboardFocusNode = FocusNode();

  // ── Snapshot cell-sizing constants ──────────────────────────────────────
  // Mirror the values from terminal_view.dart (_targetFontSize, _lineHeightFactor,
  // _monoAdvanceRatio, _termPadH, _termPadV) so the snapshot painter produces
  // the same grid geometry as the live TerminalPainter.

  static const _snapshotFontSize = 11.5;
  static const _snapshotCellWidth = _snapshotFontSize * 0.6;   // 6.9
  static const _snapshotCellHeight = _snapshotFontSize * 1.55; // 17.825
  static const _snapshotPaddingH = 14.0;
  static const _snapshotPaddingV = 12.0;

  @override
  void initState() {
    super.initState();
    _swipeAnimController = AnimationController(
      vsync: this,
      // Duration is driven by SpringSimulation, but a ceiling prevents runaway.
      duration: const Duration(milliseconds: 600),
    );
    _initConnection();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _swipeAnimController.dispose();
    _swipeOffset.dispose();
    _scrollNotifier.dispose();
    _keyboardFocusNode.dispose();
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

    // Load clipboard history for this connection.
    ref.read(clipboardHistoryProvider.notifier).load();

    // Initialize event handler to start routing bridge events.
    ref.read(eventHandlerProvider);

    // Listen for connected status to fetch initial workspace data.
    // Resync state on every (re)connect — fetchWorkspaces replaces state
    // atomically so this is idempotent.
    _statusSub = manager.statusStream.listen((status) {
      if (status == ConnectionStatus.connected) {
        _fetchInitialData();
      }
    });

    // Connect if not already connected.
    if (manager.status == ConnectionStatus.disconnected) {
      await manager.connect();
    } else if (manager.status == ConnectionStatus.connected) {
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
    final hadFocus = _keyboardFocusNode.hasFocus;
    ref.read(surfaceProvider.notifier).focusSurface(surfaceId);
    if (hadFocus) {
      // Re-request focus after the new TerminalView builds with the shared node.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _keyboardFocusNode.requestFocus();
      });
    }
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
    if (surfaceId == null) {
      debugPrint('[TerminalScreen] _sendInput: no focused surface, dropping: "$data"');
      return;
    }

    try {
      final manager = ref.read(connectionManagerProvider);
      debugPrint('[TerminalScreen] _sendInput: writing to surface $surfaceId: "$data"');
      await manager.sendRequest(
        'surface.pty.write',
        params: {'surface_id': surfaceId, 'data': data},
      );
    } catch (e) {
      debugPrint('[TerminalScreen] Write error: $e');
    }
  }

  /// Pastes text into the terminal using bracketed paste mode for safety.
  void _onPaste(String text) {
    _sendInput('\x1b[200~$text\x1b[201~');
  }

  /// Central submit handler — intercepts RETURN when attachments are staged.
  ///
  /// If no attachments are pending, sends '\r' as normal. Otherwise, uploads
  /// all attachments, collects inbox paths, pastes them into the terminal via
  /// bracketed paste, then sends '\r' to submit the line.
  Future<void> _onSubmit() async {
    final attachState = ref.read(attachmentProvider);
    if (!attachState.isNotEmpty) {
      _sendInput('\r');
      return;
    }

    final notifier = ref.read(attachmentProvider.notifier);

    // Clear any previous errors before retrying.
    if (attachState.hasErrors) {
      notifier.clearErrors();
    }

    // Upload all staged files via RPC to the desktop.
    final manager = ref.read(connectionManagerProvider);
    final successPaths = await notifier.uploadAll(manager);

    // Check for failures — if any item still has errors, don't paste.
    final postUploadState = ref.read(attachmentProvider);
    if (postUploadState.hasErrors) {
      // Remove successful items, keep failed ones.
      notifier.removeSuccessful(successPaths.keys.toSet());
      if (mounted) {
        final failedNames = postUploadState.errorItems
            .map((e) => e.filename)
            .join(', ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send $failedNames'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // All succeeded — paste paths into terminal and submit.
    if (successPaths.isNotEmpty) {
      final pathPayload = successPaths.values.join(' ');
      _onPaste(' $pathPayload');
    }

    // Send Enter to submit the line (user's typed text is already in the
    // terminal's line buffer on the desktop side).
    _sendInput('\r');

    // Clear all attachments.
    notifier.clear();
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

  /// Converts pixel delta from touch scroll into discrete line scroll commands.
  ///
  /// Cell height is 17.825px (fontSize 11.5 * lineHeight 1.55). Positive
  /// deltaY = finger moved down = scroll up into history (positive delta_y
  /// sent to Mac).
  void _onScroll(double deltaY) {
    const cellHeight = 17.825;
    _scrollRemainder += deltaY;
    final lines = (_scrollRemainder / cellHeight).truncate();
    if (lines == 0) return;
    _scrollRemainder -= lines * cellHeight;

    final surfaceId = ref.read(surfaceProvider).focusedSurfaceId;
    if (surfaceId == null) return;

    // Notify TerminalView to clear any active text selection.
    _scrollNotifier.value++;

    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest(
      'surface.scroll',
      params: {'surface_id': surfaceId, 'delta_y': lines.toDouble()},
    );
  }

  /// Creates a new pane by splitting right from the focused pane on desktop.
  Future<void> _onNewTab() async {
    final manager = ref.read(connectionManagerProvider);
    try {
      final result = await manager.sendRequest(
        'pane.create',
        params: {'direction': 'right'},
      );
      final surfaceId = result.result?['surface_id'] as String?;
      final wsState = ref.read(workspaceProvider);
      final activeWs = wsState.activeWorkspace;
      if (surfaceId != null && activeWs != null) {
        ref.read(surfaceProvider.notifier).addSurface(
          Surface(
            id: surfaceId,
            title: 'Terminal',
            workspaceId: activeWs.id,
          ),
        );
      }
      // Re-sync to pick up any server-side state changes.
      await ref.read(workspaceProvider.notifier).fetchWorkspaces();
      _syncSurfacesFromWorkspace();
    } catch (e) {
      debugPrint('[TerminalScreen] pane.create error: $e');
    }
  }

  void _onPaneTypeChanged(PaneType type) {
    if (type == PaneType.overview) {
      _openMinimap();
      return;
    }
    setState(() => _activePaneType = type);
  }

  // ── Spring constants ─────────────────────────────────────────────────────

  /// Commit spring: ~300ms with slight overshoot for a satisfying completion feel.
  static const _commitSpring = SpringDescription(mass: 1, stiffness: 500, damping: 30);

  /// Cancel spring: snappier return so the snap-back feels immediate.
  static const _cancelSpring = SpringDescription(mass: 1, stiffness: 600, damping: 35);

  /// Rubber-band spring: tight bounce-back from an edge with no adjacent tab.
  static const _rubberBandSpring = SpringDescription(mass: 1, stiffness: 700, damping: 40);

  // ── Tab-swipe handlers ───────────────────────────────────────────────────

  /// Called when a horizontal swipe gesture begins.
  ///
  /// If a spring animation is already in flight, the in-flight state is
  /// resolved immediately so the new gesture starts from a clean position:
  ///
  ///   - Commit animation in flight (animating to ±terminalWidth with a
  ///     non-null [_swipeTargetSurfaceId]): apply the tab switch immediately
  ///     via [_commitTabSwitch] so the surface change is not lost, then the
  ///     new gesture can start from offset 0.
  ///   - Cancel animation in flight (animating back to 0): snap offset to 0
  ///     and clear the target; the new gesture starts clean.
  ///
  /// Also increments [_scrollNotifier] to clear any active text selection
  /// before the swipe begins (TerminalView listens to [_scrollNotifier] and
  /// dismisses its selection on any increment).
  void _onTabSwipeStart() {
    if (_isSwipeAnimating) {
      _swipeAnimController.stop();
      _isSwipeAnimating = false;

      if (_swipeTargetSurfaceId != null) {
        // A commit animation was interrupted: finalise the tab switch now so
        // the surface change is not silently dropped.
        _commitTabSwitch();
      } else {
        // A cancel animation was interrupted: snap to rest and clear state.
        _swipeOffset.value = 0.0;
      }
    }

    // Clear any active text selection in the terminal before the swipe starts,
    // reusing the same notifier that scroll events use.
    _scrollNotifier.value++;

    // Always reset the threshold tracker at gesture start so the light haptic
    // can fire fresh on each new swipe.
    _hasPassedCommitThreshold = false;
  }

  /// Called on every pan update with the cumulative horizontal [displacement].
  ///
  /// Negative displacement = swiping left (toward next tab).
  /// Positive displacement = swiping right (toward previous tab).
  void _onTabSwipeUpdate(double displacement) {
    final surfaceNotifier = ref.read(surfaceProvider.notifier);

    // Determine which adjacent surface we are moving toward.
    final String? adjacentId = displacement < 0
        ? surfaceNotifier.nextSurfaceId()      // swipe left → show next tab
        : surfaceNotifier.previousSurfaceId(); // swipe right → show previous tab

    if (adjacentId == null) {
      // No surface in this direction: apply rubber-band dampening so the
      // terminal feels elastically tethered rather than freely dragging.
      _swipeTargetSurfaceId = null;
      _swipeOffset.value = displacement * 0.3;
    } else {
      // Valid target: 1:1 finger-to-screen tracking.
      _swipeTargetSurfaceId = adjacentId;
      _swipeOffset.value = displacement;
    }

    // Fire a light haptic exactly once when the finger crosses the 35% commit
    // threshold (and a valid target exists). Silently reset when retreating
    // below the threshold so re-crossing fires the haptic again.
    final terminalWidth = context.size?.width;
    if (terminalWidth != null && terminalWidth > 0) {
      final commitThreshold = terminalWidth * 0.35;
      final isAboveThreshold =
          _swipeTargetSurfaceId != null && displacement.abs() > commitThreshold;

      if (isAboveThreshold && !_hasPassedCommitThreshold) {
        _hasPassedCommitThreshold = true;
        HapticFeedback.lightImpact();
      } else if (!isAboveThreshold && _hasPassedCommitThreshold) {
        // Finger retreated — reset so light haptic can fire again if re-crossed.
        _hasPassedCommitThreshold = false;
      }
    }
  }

  /// Called when the swipe gesture ends with cumulative [displacement] (px)
  /// and a fling [velocity] (px/s, positive = moving right).
  ///
  /// Commits the tab switch when:
  ///   - |displacement| > 35 % of the terminal width, OR
  ///   - |velocity| > 800 px/s
  /// Otherwise cancels by snapping the offset back to 0.
  void _onTabSwipeEnd(double displacement, double velocity) {
    final terminalWidth =
        context.size?.width ?? MediaQuery.of(context).size.width;
    final commitThreshold = terminalWidth * 0.35;

    final shouldCommit = _swipeTargetSurfaceId != null &&
        (displacement.abs() > commitThreshold || velocity.abs() > 800);

    if (shouldCommit) {
      // Animate to ± terminalWidth to slide the view fully off-screen, then
      // commit the tab switch once the spring settles.
      final targetOffset = displacement < 0 ? -terminalWidth : terminalWidth;
      _runSpringAnimation(
        from: _swipeOffset.value,
        to: targetOffset,
        spring: _commitSpring,
        onComplete: _commitTabSwitch,
      );
    } else if (_swipeTargetSurfaceId == null) {
      // Rubber-band cancel: no adjacent tab in this direction; bounce back
      // with a tight spring so the edge resistance feels immediate.
      _runSpringAnimation(
        from: _swipeOffset.value,
        to: 0.0,
        spring: _rubberBandSpring,
        onComplete: () {
          _swipeTargetSurfaceId = null;
        },
      );
    } else {
      // Cancel: spring back to the rest position.
      _runSpringAnimation(
        from: _swipeOffset.value,
        to: 0.0,
        spring: _cancelSpring,
        onComplete: () {
          _swipeTargetSurfaceId = null;
        },
      );
    }
  }

  /// Runs a spring animation on [_swipeOffset] from [from] to [to].
  ///
  /// [spring] controls the feel of the animation; callers should pass one of
  /// [_commitSpring], [_cancelSpring], or [_rubberBandSpring] depending on
  /// the gesture outcome. [_swipeOffset] is updated on every tick so the
  /// terminal view moves smoothly. [onComplete] fires once the spring settles.
  void _runSpringAnimation({
    required double from,
    required double to,
    required SpringDescription spring,
    required VoidCallback onComplete,
  }) {
    _isSwipeAnimating = true;

    // Remove any previous per-animation listener before adding a fresh one.
    _swipeAnimController
      ..stop()
      ..reset();

    // When driven by animateWith(), the controller's value IS the simulation's
    // raw pixel output — not a normalised [0..1] ratio. Pass it straight through.
    void tickListener() {
      _swipeOffset.value = _swipeAnimController.value;
    }

    _swipeAnimController.addListener(tickListener);

    // Velocity 0: the spring itself provides acceleration from the from→to
    // displacement. Fling commits feel instant because the spring starts
    // close to the edge (large `from`).
    final simulation = SpringSimulation(spring, from, to, 0.0);

    _swipeAnimController.animateWith(simulation).then((_) {
      _swipeAnimController.removeListener(tickListener);
      if (!mounted) return;
      // Snap to exact final value to avoid floating-point drift.
      _swipeOffset.value = to;
      _isSwipeAnimating = false;
      onComplete();
    });
  }

  /// Finalises a committed tab switch after the slide-out animation completes.
  ///
  /// Focuses the target surface locally, sends the RPC to the desktop, and
  /// resets all swipe/scroll state so the new surface starts fresh.
  void _commitTabSwitch() {
    final targetId = _swipeTargetSurfaceId;
    if (targetId == null) return;

    // Confirm the switch with a medium haptic, giving tactile weight to the
    // moment the tab actually changes (heavier than the threshold-crossing tap).
    HapticFeedback.mediumImpact();

    // Capture keyboard state before the rebuild so we can restore it.
    final hadFocus = _keyboardFocusNode.hasFocus;

    // Update local surface focus.
    ref.read(surfaceProvider.notifier).focusSurface(targetId);

    if (hadFocus) {
      // Re-request focus after the new TerminalView builds with the shared node.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _keyboardFocusNode.requestFocus();
      });
    }

    // Notify desktop to mirror the focus change.
    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest(
      'surface.focus',
      params: {'surface_id': targetId},
    );

    // Reset all swipe state so the new surface renders at rest.
    _swipeOffset.value = 0.0;
    _swipeTargetSurfaceId = null;
    _scrollRemainder = 0.0;
  }

  /// Whether the modifier bar should be shown for the current pane type.
  bool get _showModifierBar =>
      _activePaneType == PaneType.terminal || _activePaneType == PaneType.browser;

  /// Builds the content area for the current pane type.
  Widget _buildPaneContent(String? focusedSurfaceId, String? activeWorkspaceId) {
    final c = AppColors.of(context);

    switch (_activePaneType) {
      case PaneType.terminal:
        final surfaceState = ref.read(surfaceProvider);
        return GestureLayer(
          canSwipeTabs: surfaceState.hasMultipleSurfaces,
          callbacks: GestureCallbacks(
            onOpenDrawer: _openDrawer,
            onOpenMinimap: _openMinimap,
            onScroll: _onScroll,
            onTabSwipeStart: _onTabSwipeStart,
            onTabSwipeUpdate: _onTabSwipeUpdate,
            onTabSwipeEnd: _onTabSwipeEnd,
          ),
          // Wrap the terminal content in a translation transform driven by the
          // swipe offset so the view tracks the user's finger 1:1 during a
          // horizontal swipe and springs back (or forward) on release.
          //
          // When a swipe target is active and offset is non-zero, also renders
          // a static snapshot of the adjacent terminal beside the current one
          // so the user sees real content rather than empty space.
          child: ValueListenableBuilder<double>(
            valueListenable: _swipeOffset,
            builder: (context, offset, child) {
              // Determine whether to show an adjacent snapshot.
              final targetId = _swipeTargetSurfaceId;
              final showSnapshot = targetId != null && offset != 0.0;

              if (!showSnapshot) {
                // No swipe in progress — plain translate, no snapshot overhead.
                return Transform.translate(
                  offset: Offset(offset, 0),
                  child: child,
                );
              }

              // Swipe in progress: render current terminal + adjacent snapshot
              // side-by-side, clipped to the visible viewport.
              return LayoutBuilder(
                builder: (context, constraints) {
                  final terminalWidth = constraints.maxWidth;

                  // Adjacent snapshot position:
                  //   swiping left  (offset < 0, going to next tab)   → snapshot starts at +terminalWidth
                  //   swiping right (offset > 0, going to previous tab) → snapshot starts at -terminalWidth
                  final snapshotBaseX =
                      offset < 0 ? terminalWidth : -terminalWidth;

                  final snapshot =
                      ref.read(surfaceProvider.notifier).getSnapshot(targetId);

                  return ClipRect(
                    child: Stack(
                      children: [
                        // Current terminal translated by swipe offset.
                        Transform.translate(
                          offset: Offset(offset, 0),
                          child: SizedBox(
                            width: terminalWidth,
                            height: constraints.maxHeight,
                            child: child,
                          ),
                        ),

                        // Adjacent terminal snapshot, positioned just off-screen
                        // in the swipe direction and translated in tandem.
                        if (snapshot != null)
                          Transform.translate(
                            offset: Offset(snapshotBaseX + offset, 0),
                            child: SizedBox(
                              width: terminalWidth,
                              height: constraints.maxHeight,
                              child: CustomPaint(
                                size: Size(terminalWidth, constraints.maxHeight),
                                painter: TerminalSnapshotPainter(
                                  cells: snapshot.cells,
                                  cols: snapshot.cols,
                                  rows: snapshot.rows,
                                  cellWidth: _snapshotCellWidth,
                                  cellHeight: _snapshotCellHeight,
                                  fontSize: _snapshotFontSize,
                                  paddingH: _snapshotPaddingH,
                                  paddingV: _snapshotPaddingV,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
            child: focusedSurfaceId != null
                ? TerminalView(
                    key: ValueKey(focusedSurfaceId),
                    surfaceId: focusedSurfaceId,
                    workspaceId: activeWorkspaceId,
                    scrollNotifier: _scrollNotifier,
                    ctrlActiveNotifier: _ctrlActiveNotifier,
                    externalFocusNode: _keyboardFocusNode,
                    autocompleteActiveNotifier: _autocompleteActiveNotifier,
                    onCopy: (text) =>
                        ref.read(clipboardHistoryProvider.notifier).add(text),
                    onSubmitOverride:
                        ref.watch(attachmentProvider).isNotEmpty ? _onSubmit : null,
                  )
                : Center(
                    child: Text(
                      'No terminal surfaces',
                      style: TextStyle(color: c.textSecondary),
                    ),
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

    // Re-sync surfaces whenever workspace panels change (e.g. desktop
    // pane split/close triggers fetchWorkspaces → panels list updates).
    ref.listen<WorkspaceState>(workspaceProvider, (previous, next) {
      final prevPanels = previous?.activeWorkspace?.panels;
      final nextPanels = next.activeWorkspace?.panels;
      if (prevPanels != nextPanels) {
        _syncSurfacesFromWorkspace();
      }
    });

    // When a voice chip transitions to "committing", send its text to the
    // terminal and mark it committed. This mirrors how attachment upload sends
    // file paths to the pty.
    ref.listen<VoiceState>(voiceProvider, (previous, next) {
      for (final chip in next.chips) {
        if (chip.status != ChipStatus.committing) continue;

        // Check the chip was not already committing in the previous state to
        // avoid re-sending on rebuilds.
        final prevChip = previous?.chips
            .where((c) => c.segmentId == chip.segmentId)
            .firstOrNull;
        if (prevChip?.status == ChipStatus.committing) continue;

        // Send the chip text to the terminal pty.
        debugPrint('[VoiceCommit] Sending chip ${chip.segmentId} to terminal: "${chip.commitText}"');
        final surfaceId = ref.read(surfaceProvider).focusedSurfaceId;
        debugPrint('[VoiceCommit] focusedSurfaceId=$surfaceId');
        _sendInput(chip.commitText);

        // Mark the chip as committed so it fades out.
        ref.read(voiceProvider.notifier).markCommitted(chip.segmentId);
      }
    });

    final focusedSurfaceId = surfaceState.focusedSurfaceId;
    final attachState = ref.watch(attachmentProvider);
    final voiceState = ref.watch(voiceProvider);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.bgDeep,
      drawer: WorkspaceDrawer(
        workspaces: wsState.workspaces,
        activeWorkspaceId: wsState.activeWorkspaceId,
        onWorkspaceSelected: _onWorkspaceSelected,
        onSettings: () {
          _scaffoldKey.currentState?.closeDrawer();
          context.go('/pair?rescan=true');
        },
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // Main content column
            Column(
              children: [
                // Top bar: tab strip + pane type icon.
                // Wrapped in a ValueListenableBuilder so swipe progress is
                // forwarded to TabBarStrip on every frame without rebuilding
                // the whole screen.
                ValueListenableBuilder<double>(
                  valueListenable: _swipeOffset,
                  builder: (context, swipeOffset, _) {
                    final terminalWidth =
                        MediaQuery.of(context).size.width;

                    // Normalise pixel offset to [-1.0, 1.0]. Negative means
                    // swiping toward the next tab, positive toward the previous.
                    final double swipeProgress = terminalWidth > 0
                        ? (swipeOffset / terminalWidth).clamp(-1.0, 1.0)
                        : 0.0;

                    // Map the target surface ID to its index in the surface list.
                    final swipeTargetId = _swipeTargetSurfaceId;
                    int? swipeTargetIndex;
                    if (swipeTargetId != null) {
                      final idx = surfaceState.surfaces
                          .indexWhere((s) => s.id == swipeTargetId);
                      if (idx >= 0) swipeTargetIndex = idx;
                    }

                    return TopBar(
                      surfaces: surfaceState.surfaces,
                      focusedSurfaceId: focusedSurfaceId,
                      onSurfaceSelected: _onSurfaceSelected,
                      onMenuTap: _openDrawer,
                      activePaneType: _activePaneType,
                      onPaneTypeChanged: _onPaneTypeChanged,
                      onNewTab: _onNewTab,
                      // Pass null when not actively swiping to keep strip in
                      // normal (non-crossfade) rendering mode.
                      swipeProgress: swipeProgress != 0.0 ? swipeProgress : null,
                      swipeTargetIndex: swipeTargetIndex,
                    );
                  },
                ),

                // Content area — switches by pane type
                Expanded(
                  child: _buildPaneContent(
                    focusedSurfaceId,
                    wsState.activeWorkspaceId,
                  ),
                ),

                // Attachment strip (only when attachments are staged)
                if (_showModifierBar && attachState.isNotEmpty)
                  AttachmentStrip(
                    state: attachState,
                    onRemove: (id) =>
                        ref.read(attachmentProvider.notifier).remove(id),
                  ),

                // Voice transcription strip (slides in during recording
                // or when transcription chips are active)
                if (_showModifierBar)
                  VoiceStrip(
                    state: voiceState,
                    onDismiss: (segmentId) =>
                        ref.read(voiceProvider.notifier).dismissChip(segmentId),
                  ),

                // Modifier bar (only for terminal + browser)
                if (_showModifierBar) ModifierBar(
                  onInput: _sendInput,
                  onSubmit: _onSubmit,
                  isUploading: attachState.isUploading,
                  attachmentState: attachState,
                  ctrlActiveNotifier: _ctrlActiveNotifier,
                  clipboardHistoryState: ref.watch(clipboardHistoryProvider),
                  clipboardHistoryNotifier:
                      ref.read(clipboardHistoryProvider.notifier),
                  keyboardFocusNode: _keyboardFocusNode,
                  autocompleteActiveNotifier: _autocompleteActiveNotifier,
                  onPaste: _onPaste,
                ),
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
                onRepair: () => context.go('/pair?rescan=true'),
              ),
          ],
        ),
      ),
    );
  }
}
