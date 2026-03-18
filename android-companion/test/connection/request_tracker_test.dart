import 'dart:async';

import 'package:cmux_companion/connection/message_protocol.dart';
import 'package:cmux_companion/connection/request_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RequestTracker', () {
    late RequestTracker tracker;

    setUp(() {
      tracker = RequestTracker();
    });

    test('auto-increments request IDs', () {
      final first = tracker.track();
      final second = tracker.track();
      final third = tracker.track();

      expect(first.id, equals(1));
      expect(second.id, equals(2));
      expect(third.id, equals(3));
    });

    test('resolves matching response', () async {
      final tracked = tracker.track();

      final response = BridgeResponse(
        id: tracked.id,
        ok: true,
        result: {'foo': 'bar'},
      );

      expect(tracker.resolve(response), isTrue);

      final result = await tracked.future;
      expect(result.ok, isTrue);
      expect(result.result?['foo'], equals('bar'));
    });

    test('ignores response with unknown ID', () {
      tracker.track(); // ID 1

      final response = BridgeResponse(id: 999, ok: true);
      expect(tracker.resolve(response), isFalse);
    });

    test('ignores response with null ID', () {
      tracker.track();

      final response = BridgeResponse(id: null, ok: true);
      expect(tracker.resolve(response), isFalse);
    });

    test('tracks pending count', () {
      expect(tracker.pendingCount, equals(0));

      tracker.track();
      tracker.track();
      expect(tracker.pendingCount, equals(2));

      final response = BridgeResponse(id: 1, ok: true);
      tracker.resolve(response);
      expect(tracker.pendingCount, equals(1));
    });

    test('failAll completes all pending with error', () async {
      final t1 = tracker.track();
      final t2 = tracker.track();

      // Expect errors from both futures.
      expect(t1.future, throwsA(isA<Exception>()));
      expect(t2.future, throwsA(isA<Exception>()));

      tracker.failAll(Exception('disconnected'));
      expect(tracker.pendingCount, equals(0));
    });

    test('resolve after failAll does nothing', () async {
      final tracked = tracker.track();
      // Consume the error to prevent unhandled exception.
      unawaited(tracked.future.catchError((_) => const BridgeResponse(ok: false)));

      tracker.failAll(Exception('disconnected'));

      final response = BridgeResponse(id: 1, ok: true);
      expect(tracker.resolve(response), isFalse);
    });
  });
}
