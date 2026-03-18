/// Dispatches incoming bridge events to the appropriate state notifiers.
///
/// Listens to [ConnectionManager.eventStream] and routes each event
/// type to the corresponding [WorkspaceNotifier], [SurfaceNotifier],
/// or [PaneNotifier] method.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../connection/message_protocol.dart';
import 'pane_provider.dart';
import 'surface_provider.dart';
import 'workspace_provider.dart';

/// Routes bridge events to the correct state notifier.
///
/// Create via [eventHandlerProvider] — it auto-subscribes on construction
/// and cancels on dispose.
class EventHandler {
  final Ref _ref;
  StreamSubscription<BridgeEvent>? _subscription;

  EventHandler(this._ref) {
    _subscribe();
  }

  void _subscribe() {
    final manager = _ref.read(connectionManagerProvider);
    _subscription = manager.eventStream.listen(_onEvent);
  }

  void _onEvent(BridgeEvent event) {
    final data = event.data;

    switch (event.event) {
      // Workspace events
      case 'workspace.created':
        _ref.read(workspaceProvider.notifier).onWorkspaceCreated(data);

      case 'workspace.closed':
        _ref.read(workspaceProvider.notifier).onWorkspaceClosed(data);

      case 'workspace.title_changed':
        _ref.read(workspaceProvider.notifier).onWorkspaceTitleChanged(data);

      case 'workspace.selected':
        _ref.read(workspaceProvider.notifier).onWorkspaceSelected(data);

      // Surface events
      case 'surface.focused':
        _ref.read(surfaceProvider.notifier).onSurfaceFocused(data);

      case 'surface.closed':
        _ref.read(surfaceProvider.notifier).onSurfaceClosed(data);

      case 'surface.title_changed':
        _ref.read(surfaceProvider.notifier).onSurfaceTitleChanged(data);

      case 'surface.moved':
      case 'surface.reordered':
        _ref.read(surfaceProvider.notifier).onSurfaceMoved(data);

      // Pane events
      case 'pane.focused':
        _ref.read(paneProvider.notifier).onPaneFocused(data);

      case 'pane.split':
        _ref.read(paneProvider.notifier).onPaneSplit(data);

      case 'pane.closed':
        _ref.read(paneProvider.notifier).onPaneClosed(data);

      default:
        debugPrint('[EventHandler] Unhandled event: ${event.event}');
    }
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}

final eventHandlerProvider = Provider<EventHandler>((ref) {
  final handler = EventHandler(ref);
  ref.onDispose(() => handler.dispose());
  return handler;
});
