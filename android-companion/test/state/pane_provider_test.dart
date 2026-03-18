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
      });

      expect(pane.id, equals('pane-1'));
      expect(pane.surfaceId, equals('surf-1'));
      expect(pane.type, equals('terminal'));
      expect(pane.x, equals(0.0));
      expect(pane.y, equals(0.0));
      expect(pane.width, equals(0.5));
      expect(pane.height, equals(1.0));
      expect(pane.focused, isTrue);
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
