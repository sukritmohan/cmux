import 'package:cmux_companion/state/workspace_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  group('Workspace.fromJson', () {
    test('parses full workspace JSON', () {
      final json = {
        'id': 'ws-1',
        'title': 'My Workspace',
        'panels': [
          {'id': 'p-1', 'type': 'terminal', 'title': 'zsh'},
          {'id': 'p-2', 'type': 'browser', 'title': 'localhost:3000'},
        ],
        'focused_panel_id': 'p-1',
      };

      final ws = Workspace.fromJson(json);
      expect(ws.id, equals('ws-1'));
      expect(ws.title, equals('My Workspace'));
      expect(ws.panels.length, equals(2));
      expect(ws.panels[0].type, equals('terminal'));
      expect(ws.panels[1].type, equals('browser'));
      expect(ws.focusedPanelId, equals('p-1'));
    });

    test('provides defaults for missing fields', () {
      final ws = Workspace.fromJson({});
      expect(ws.id, isEmpty);
      expect(ws.title, equals('Untitled'));
      expect(ws.panels, isEmpty);
      expect(ws.focusedPanelId, isNull);
      expect(ws.branch, isNull);
      expect(ws.notificationCount, equals(0));
    });

    test('primarySurfaceId returns first terminal panel', () {
      final ws = Workspace.fromJson({
        'id': 'ws-1',
        'title': 'test',
        'panels': [
          {'id': 'browser-1', 'type': 'browser'},
          {'id': 'term-1', 'type': 'terminal'},
        ],
        'focused_panel_id': 'browser-1',
      });

      expect(ws.primarySurfaceId, equals('term-1'));
    });

    test('primarySurfaceId falls back to focusedPanelId', () {
      final ws = Workspace.fromJson({
        'id': 'ws-1',
        'title': 'test',
        'panels': [
          {'id': 'browser-1', 'type': 'browser'},
        ],
        'focused_panel_id': 'browser-1',
      });

      expect(ws.primarySurfaceId, equals('browser-1'));
    });

    test('parses branch field from JSON', () {
      final ws = Workspace.fromJson({
        'id': 'ws-1',
        'title': 'Feature Work',
        'branch': 'feat/new-ui',
      });

      expect(ws.branch, equals('feat/new-ui'));
    });

    test('branch defaults to null when absent', () {
      final ws = Workspace.fromJson({
        'id': 'ws-1',
        'title': 'No Branch',
      });

      expect(ws.branch, isNull);
    });

    test('parses notificationCount from JSON', () {
      final ws = Workspace.fromJson({
        'id': 'ws-1',
        'title': 'Busy Workspace',
        'notification_count': 5,
      });

      expect(ws.notificationCount, equals(5));
    });

    test('notificationCount defaults to zero when absent', () {
      final ws = Workspace.fromJson({
        'id': 'ws-1',
        'title': 'Quiet Workspace',
      });

      expect(ws.notificationCount, equals(0));
    });

    test('parses all fields together including branch and notifications', () {
      final ws = Workspace.fromJson({
        'id': 'ws-full',
        'title': 'Full Workspace',
        'panels': [
          {'id': 'p-1', 'type': 'terminal'},
        ],
        'focused_panel_id': 'p-1',
        'branch': 'main',
        'notification_count': 3,
      });

      expect(ws.id, equals('ws-full'));
      expect(ws.title, equals('Full Workspace'));
      expect(ws.panels.length, equals(1));
      expect(ws.focusedPanelId, equals('p-1'));
      expect(ws.branch, equals('main'));
      expect(ws.notificationCount, equals(3));
    });
  });

  group('Workspace.copyWith', () {
    test('preserves branch when not overridden', () {
      const ws = Workspace(
        id: 'ws-1',
        title: 'Original',
        branch: 'develop',
        notificationCount: 2,
      );

      final updated = ws.copyWith(title: 'Updated');

      expect(updated.title, equals('Updated'));
      expect(updated.branch, equals('develop'));
      expect(updated.notificationCount, equals(2));
    });

    test('overrides branch when provided', () {
      const ws = Workspace(
        id: 'ws-1',
        title: 'Original',
        branch: 'develop',
      );

      final updated = ws.copyWith(branch: 'main');

      expect(updated.branch, equals('main'));
    });

    test('overrides notificationCount when provided', () {
      const ws = Workspace(
        id: 'ws-1',
        title: 'Original',
        notificationCount: 5,
      );

      final updated = ws.copyWith(notificationCount: 0);

      expect(updated.notificationCount, equals(0));
    });
  });

  group('WorkspacePanel.fromJson', () {
    test('parses panel JSON', () {
      final panel = WorkspacePanel.fromJson({
        'id': 'p-1',
        'type': 'terminal',
        'title': 'zsh',
      });
      expect(panel.id, equals('p-1'));
      expect(panel.type, equals('terminal'));
      expect(panel.title, equals('zsh'));
    });

    test('defaults type to terminal', () {
      final panel = WorkspacePanel.fromJson({'id': 'p-1'});
      expect(panel.type, equals('terminal'));
    });
  });

  group('WorkspaceState', () {
    test('activeWorkspace returns workspace matching activeWorkspaceId', () {
      final ws1 = Workspace.fromJson({'id': 'ws-1', 'title': 'First'});
      final ws2 = Workspace.fromJson({'id': 'ws-2', 'title': 'Second'});

      final state = WorkspaceState(
        workspaces: [ws1, ws2],
        activeWorkspaceId: 'ws-2',
      );

      expect(state.activeWorkspace?.id, equals('ws-2'));
      expect(state.activeWorkspace?.title, equals('Second'));
    });

    test('activeWorkspace falls back to first workspace', () {
      final ws1 = Workspace.fromJson({'id': 'ws-1', 'title': 'First'});

      final state = WorkspaceState(
        workspaces: [ws1],
        activeWorkspaceId: 'non-existent',
      );

      expect(state.activeWorkspace?.id, equals('ws-1'));
    });

    test('activeWorkspace is null when empty', () {
      const state = WorkspaceState();
      expect(state.activeWorkspace, isNull);
    });
  });

  group('WorkspaceNotifier event handlers', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() => container.dispose());

    test('onWorkspaceCreated adds workspace', () {
      final notifier = container.read(workspaceProvider.notifier);
      notifier.onWorkspaceCreated({
        'id': 'ws-new',
        'title': 'New Workspace',
        'panels': [],
      });

      final state = container.read(workspaceProvider);
      expect(state.workspaces.length, equals(1));
      expect(state.workspaces.first.id, equals('ws-new'));
    });

    test('onWorkspaceCreated ignores empty ID', () {
      final notifier = container.read(workspaceProvider.notifier);
      notifier.onWorkspaceCreated({'title': 'Bad'});

      final state = container.read(workspaceProvider);
      expect(state.workspaces, isEmpty);
    });

    test('onWorkspaceClosed removes workspace', () {
      final notifier = container.read(workspaceProvider.notifier);
      notifier.onWorkspaceCreated({'id': 'ws-1', 'title': 'A'});
      notifier.onWorkspaceCreated({'id': 'ws-2', 'title': 'B'});

      notifier.onWorkspaceClosed({'workspace_id': 'ws-1'});

      final state = container.read(workspaceProvider);
      expect(state.workspaces.length, equals(1));
      expect(state.workspaces.first.id, equals('ws-2'));
    });

    test('onWorkspaceClosed updates activeWorkspaceId if closed', () {
      final notifier = container.read(workspaceProvider.notifier);
      notifier.onWorkspaceCreated({'id': 'ws-1', 'title': 'A'});
      notifier.onWorkspaceCreated({'id': 'ws-2', 'title': 'B'});
      notifier.selectWorkspace('ws-1');

      notifier.onWorkspaceClosed({'workspace_id': 'ws-1'});

      final state = container.read(workspaceProvider);
      expect(state.activeWorkspaceId, equals('ws-2'));
    });

    test('onWorkspaceTitleChanged updates title', () {
      final notifier = container.read(workspaceProvider.notifier);
      notifier.onWorkspaceCreated({'id': 'ws-1', 'title': 'Old'});

      notifier.onWorkspaceTitleChanged({
        'workspace_id': 'ws-1',
        'title': 'New Title',
      });

      final state = container.read(workspaceProvider);
      expect(state.workspaces.first.title, equals('New Title'));
    });

    test('onWorkspaceSelected updates activeWorkspaceId', () {
      final notifier = container.read(workspaceProvider.notifier);
      notifier.onWorkspaceCreated({'id': 'ws-1', 'title': 'A'});
      notifier.onWorkspaceCreated({'id': 'ws-2', 'title': 'B'});

      notifier.onWorkspaceSelected({'workspace_id': 'ws-2'});

      final state = container.read(workspaceProvider);
      expect(state.activeWorkspaceId, equals('ws-2'));
    });

    test('selectWorkspace sets active workspace', () {
      final notifier = container.read(workspaceProvider.notifier);
      notifier.selectWorkspace('ws-42');

      final state = container.read(workspaceProvider);
      expect(state.activeWorkspaceId, equals('ws-42'));
    });

    test('onWorkspaceCreated preserves branch and notificationCount', () {
      final notifier = container.read(workspaceProvider.notifier);
      notifier.onWorkspaceCreated({
        'id': 'ws-branch',
        'title': 'Dev',
        'branch': 'feature/drawer',
        'notification_count': 7,
      });

      final state = container.read(workspaceProvider);
      expect(state.workspaces.first.branch, equals('feature/drawer'));
      expect(state.workspaces.first.notificationCount, equals(7));
    });
  });
}
