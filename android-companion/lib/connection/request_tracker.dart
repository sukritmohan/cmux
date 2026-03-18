/// Tracks pending JSON-RPC requests and resolves them when responses arrive.
///
/// Each request gets an auto-incrementing integer ID. When a response with
/// a matching ID arrives, the corresponding [Future] completes.
library;

import 'dart:async';

import 'message_protocol.dart';

class RequestTracker {
  int _nextId = 1;
  final Map<int, Completer<BridgeResponse>> _pending = {};

  /// Allocate the next request ID and register a pending future.
  ({int id, Future<BridgeResponse> future}) track() {
    final id = _nextId++;
    final completer = Completer<BridgeResponse>();
    _pending[id] = completer;
    return (id: id, future: completer.future);
  }

  /// Resolve a pending request by response ID.
  ///
  /// Returns true if a matching request was found and completed.
  bool resolve(BridgeResponse response) {
    if (response.id == null) return false;
    final completer = _pending.remove(response.id);
    if (completer == null) return false;
    completer.complete(response);
    return true;
  }

  /// Fail all pending requests (e.g., on disconnect).
  void failAll(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
  }

  /// Number of requests still awaiting a response.
  int get pendingCount => _pending.length;
}
