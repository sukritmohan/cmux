import 'package:cmux_companion/state/pane_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Pane.fromJson', () {
    test('parses full pane JSON', () {
      final pane = Pane.fromJson({
        'id': 'pane-1',
        'surface_id': 'surf-1',
        'type': 'terminal',
        'x': 0.0,
        'y': 0.0,
        'width': 0.5,
        'height': 1.0,
        'focused': true,
        'surface_count': 3,
      });

      expect(pane.id, equals('pane-1'));
      expect(pane.surfaceId, equals('surf-1'));
      expect(pane.type, equals('terminal'));
      expect(pane.x, equals(0.0));
      expect(pane.y, equals(0.0));
      expect(pane.width, equals(0.5));
      expect(pane.height, equals(1.0));
      expect(pane.focused, isTrue);
      expect(pane.surfaceCount, equals(3));
    });

    test('provides defaults for missing fields', () {
      final pane = Pane.fromJson({});
      expect(pane.id, isEmpty);
      expect(pane.surfaceId, isNull);
      expect(pane.type, equals('terminal'));
      expect(pane.x, equals(0));
      expect(pane.y, equals(0));
      expect(pane.width, equals(1));
      expect(pane.height, equals(1));
      expect(pane.focused, isFalse);
      expect(pane.surfaceCount, equals(1));
    });

    test('surfaceCount defaults to 1 when absent', () {
      final pane = Pane.fromJson({
        'id': 'pane-x',
        'type': 'browser',
      });
      expect(pane.surfaceCount, equals(1));
    });

    test('surfaceCount parses explicit value', () {
      final pane = Pane.fromJson({
        'id': 'pane-y',
        'surface_count': 5,
      });
      expect(pane.surfaceCount, equals(5));
    });
  });

  group('Pane.copyWith', () {
    test('copies with updated focused', () {
      const original = Pane(id: 'p1', focused: false, surfaceCount: 2);
      final copy = original.copyWith(focused: true);

      expect(copy.focused, isTrue);
      expect(copy.surfaceCount, equals(2));
      expect(copy.id, equals('p1'));
    });

    test('copies with updated surfaceCount', () {
      const original = Pane(id: 'p2', surfaceCount: 1);
      final copy = original.copyWith(surfaceCount: 4);

      expect(copy.surfaceCount, equals(4));
      expect(copy.id, equals('p2'));
    });

    test('preserves all fields when no overrides given', () {
      const original = Pane(
        id: 'p3',
        surfaceId: 'surf-3',
        type: 'browser',
        x: 0.5,
        y: 0.0,
        width: 0.5,
        height: 1.0,
        focused: true,
        surfaceCount: 3,
      );
      final copy = original.copyWith();

      expect(copy.id, equals(original.id));
      expect(copy.surfaceId, equals(original.surfaceId));
      expect(copy.type, equals(original.type));
      expect(copy.x, equals(original.x));
      expect(copy.y, equals(original.y));
      expect(copy.width, equals(original.width));
      expect(copy.height, equals(original.height));
      expect(copy.focused, equals(original.focused));
      expect(copy.surfaceCount, equals(original.surfaceCount));
    });
  });

  group('PaneNotifier event handlers', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() => container.dispose());

    test('onPaneFocused updates focused pane', () {
      final notifier = container.read(paneProvider.notifier);

      // The notifier starts empty — onPaneFocused should still set focusedPaneId.
      notifier.onPaneFocused({'pane_id': 'p-2'});

      final state = container.read(paneProvider);
      expect(state.focusedPaneId, equals('p-2'));
    });

    test('onPaneFocused ignores null pane_id', () {
      final notifier = container.read(paneProvider.notifier);
      notifier.onPaneFocused({});

      final state = container.read(paneProvider);
      expect(state.focusedPaneId, isNull);
    });
  });
}
