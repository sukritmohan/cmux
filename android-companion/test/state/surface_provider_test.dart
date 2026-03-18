import 'package:cmux_companion/state/surface_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SurfaceNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() => container.dispose());

    test('setSurfaces replaces all surfaces', () {
      final notifier = container.read(surfaceProvider.notifier);
      final surfaces = [
        const Surface(id: 's-1', title: 'zsh', workspaceId: 'ws-1'),
        const Surface(id: 's-2', title: 'vim', workspaceId: 'ws-1'),
      ];

      notifier.setSurfaces(surfaces, focusedId: 's-2');

      final state = container.read(surfaceProvider);
      expect(state.surfaces.length, equals(2));
      expect(state.focusedSurfaceId, equals('s-2'));
    });

    test('setSurfaces defaults focus to first surface', () {
      final notifier = container.read(surfaceProvider.notifier);
      notifier.setSurfaces([
        const Surface(id: 's-1', title: 'zsh', workspaceId: 'ws-1'),
      ]);

      final state = container.read(surfaceProvider);
      expect(state.focusedSurfaceId, equals('s-1'));
    });

    test('focusedSurface returns matching surface', () {
      final notifier = container.read(surfaceProvider.notifier);
      notifier.setSurfaces([
        const Surface(id: 's-1', title: 'zsh', workspaceId: 'ws-1'),
        const Surface(id: 's-2', title: 'vim', workspaceId: 'ws-1'),
      ], focusedId: 's-2');

      final state = container.read(surfaceProvider);
      expect(state.focusedSurface?.id, equals('s-2'));
    });

    test('onSurfaceFocused updates focused surface', () {
      final notifier = container.read(surfaceProvider.notifier);
      notifier.setSurfaces([
        const Surface(id: 's-1', title: 'zsh', workspaceId: 'ws-1'),
        const Surface(id: 's-2', title: 'vim', workspaceId: 'ws-1'),
      ]);

      notifier.onSurfaceFocused({'surface_id': 's-2'});

      final state = container.read(surfaceProvider);
      expect(state.focusedSurfaceId, equals('s-2'));
    });

    test('onSurfaceClosed removes surface', () {
      final notifier = container.read(surfaceProvider.notifier);
      notifier.setSurfaces([
        const Surface(id: 's-1', title: 'zsh', workspaceId: 'ws-1'),
        const Surface(id: 's-2', title: 'vim', workspaceId: 'ws-1'),
      ], focusedId: 's-1');

      notifier.onSurfaceClosed({'surface_id': 's-1'});

      final state = container.read(surfaceProvider);
      expect(state.surfaces.length, equals(1));
      expect(state.focusedSurfaceId, equals('s-2'));
    });

    test('onSurfaceClosed preserves focus when non-focused surface closes', () {
      final notifier = container.read(surfaceProvider.notifier);
      notifier.setSurfaces([
        const Surface(id: 's-1', title: 'zsh', workspaceId: 'ws-1'),
        const Surface(id: 's-2', title: 'vim', workspaceId: 'ws-1'),
      ], focusedId: 's-1');

      notifier.onSurfaceClosed({'surface_id': 's-2'});

      final state = container.read(surfaceProvider);
      expect(state.focusedSurfaceId, equals('s-1'));
    });

    test('onSurfaceTitleChanged updates title', () {
      final notifier = container.read(surfaceProvider.notifier);
      notifier.setSurfaces([
        const Surface(id: 's-1', title: 'zsh', workspaceId: 'ws-1'),
      ]);

      notifier.onSurfaceTitleChanged({
        'surface_id': 's-1',
        'title': 'bash',
      });

      final state = container.read(surfaceProvider);
      expect(state.surfaces.first.title, equals('bash'));
    });

    test('focusSurface updates focused ID', () {
      final notifier = container.read(surfaceProvider.notifier);
      notifier.setSurfaces([
        const Surface(id: 's-1', title: 'zsh', workspaceId: 'ws-1'),
        const Surface(id: 's-2', title: 'vim', workspaceId: 'ws-1'),
      ]);

      notifier.focusSurface('s-2');

      final state = container.read(surfaceProvider);
      expect(state.focusedSurfaceId, equals('s-2'));
    });
  });
}
