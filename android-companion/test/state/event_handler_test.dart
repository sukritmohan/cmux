import 'dart:async';

import 'package:cmux_companion/app/providers.dart';
import 'package:cmux_companion/connection/connection_manager.dart';
import 'package:cmux_companion/connection/message_protocol.dart';
import 'package:cmux_companion/state/event_handler.dart';
import 'package:cmux_companion/state/pane_provider.dart';
import 'package:cmux_companion/state/surface_provider.dart';
import 'package:cmux_companion/state/workspace_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EventHandler dispatch', () {
    late ProviderContainer container;
    late StreamController<BridgeEvent> eventController;

    setUp(() {
      eventController = StreamController<BridgeEvent>.broadcast();

      container = ProviderContainer(
        overrides: [
          connectionManagerProvider.overrideWithValue(
            _FakeConnectionManager(eventController.stream),
          ),
        ],
      );

      // Initialize the event handler so it starts listening.
      container.read(eventHandlerProvider);
    });

    tearDown(() {
      container.dispose();
      eventController.close();
    });

    test('workspace.created dispatches to WorkspaceNotifier', () async {
      eventController.add(const BridgeEvent(
        event: 'workspace.created',
        data: {'id': 'ws-new', 'title': 'New'},
      ));

      // Allow microtask to process.
      await Future<void>.delayed(Duration.zero);

      final state = container.read(workspaceProvider);
      expect(state.workspaces.length, equals(1));
      expect(state.workspaces.first.id, equals('ws-new'));
    });

    test('workspace.closed dispatches to WorkspaceNotifier', () async {
      // Seed a workspace first.
      eventController.add(const BridgeEvent(
        event: 'workspace.created',
        data: {'id': 'ws-1', 'title': 'One'},
      ));
      await Future<void>.delayed(Duration.zero);

      eventController.add(const BridgeEvent(
        event: 'workspace.closed',
        data: {'workspace_id': 'ws-1'},
      ));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(workspaceProvider);
      expect(state.workspaces, isEmpty);
    });

    test('surface.focused dispatches to SurfaceNotifier', () async {
      // Seed surfaces.
      container.read(surfaceProvider.notifier).setSurfaces([
        const Surface(id: 's-1', title: 'zsh', workspaceId: 'ws-1'),
        const Surface(id: 's-2', title: 'vim', workspaceId: 'ws-1'),
      ]);

      eventController.add(const BridgeEvent(
        event: 'surface.focused',
        data: {'surface_id': 's-2'},
      ));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(surfaceProvider);
      expect(state.focusedSurfaceId, equals('s-2'));
    });

    test('surface.title_changed dispatches to SurfaceNotifier', () async {
      container.read(surfaceProvider.notifier).setSurfaces([
        const Surface(id: 's-1', title: 'old', workspaceId: 'ws-1'),
      ]);

      eventController.add(const BridgeEvent(
        event: 'surface.title_changed',
        data: {'surface_id': 's-1', 'title': 'new-title'},
      ));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(surfaceProvider);
      expect(state.surfaces.first.title, equals('new-title'));
    });

    test('pane.focused dispatches to PaneNotifier', () async {
      eventController.add(const BridgeEvent(
        event: 'pane.focused',
        data: {'pane_id': 'p-1'},
      ));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(paneProvider);
      expect(state.focusedPaneId, equals('p-1'));
    });

    test('workspace.title_changed dispatches correctly', () async {
      eventController.add(const BridgeEvent(
        event: 'workspace.created',
        data: {'id': 'ws-1', 'title': 'Old'},
      ));
      await Future<void>.delayed(Duration.zero);

      eventController.add(const BridgeEvent(
        event: 'workspace.title_changed',
        data: {'workspace_id': 'ws-1', 'title': 'Renamed'},
      ));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(workspaceProvider);
      expect(state.workspaces.first.title, equals('Renamed'));
    });
  });
}

/// Fake ConnectionManager that exposes a controllable event stream.
class _FakeConnectionManager extends ConnectionManager {
  final Stream<BridgeEvent> _fakeEventStream;

  _FakeConnectionManager(this._fakeEventStream);

  @override
  Stream<BridgeEvent> get eventStream => _fakeEventStream;
}
