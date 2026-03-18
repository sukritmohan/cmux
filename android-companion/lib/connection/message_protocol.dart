/// V2 JSON-RPC message protocol for cmux bridge communication.
///
/// Matches the protocol defined in `BridgeConnection.swift`:
///   - Request:  `{"id": N, "method": "...", "params": {...}}`
///   - Response: `{"id": N, "ok": true, "result": {...}}`
///   - Error:    `{"id": N, "ok": false, "error": {"code": "...", "message": "..."}}`
///   - Event:    `{"event": "...", "data": {...}}`
library;

import 'dart:convert';

/// A JSON-RPC request to the bridge server.
class BridgeRequest {
  final int id;
  final String method;
  final Map<String, dynamic> params;

  const BridgeRequest({
    required this.id,
    required this.method,
    this.params = const {},
  });

  String toJson() {
    return jsonEncode({
      'id': id,
      'method': method,
      if (params.isNotEmpty) 'params': params,
    });
  }
}

/// A successful response from the bridge server.
class BridgeResponse {
  final int? id;
  final bool ok;
  final Map<String, dynamic>? result;
  final BridgeError? error;

  const BridgeResponse({
    this.id,
    required this.ok,
    this.result,
    this.error,
  });

  /// Parse a JSON text frame into a response.
  ///
  /// Returns null if the JSON is an event (has "event" key instead of "id").
  static BridgeResponse? fromJson(Map<String, dynamic> json) {
    // Events don't have an "id" field — they have "event".
    if (json.containsKey('event')) return null;

    final ok = json['ok'] as bool? ?? false;
    return BridgeResponse(
      id: (json['id'] as num?)?.toInt(),
      ok: ok,
      result: ok ? json['result'] as Map<String, dynamic>? : null,
      error: !ok && json['error'] is Map
          ? BridgeError.fromJson(json['error'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// Error payload from a failed bridge response.
class BridgeError {
  final String code;
  final String message;

  const BridgeError({required this.code, required this.message});

  factory BridgeError.fromJson(Map<String, dynamic> json) {
    return BridgeError(
      code: json['code'] as String? ?? 'unknown',
      message: json['message'] as String? ?? 'Unknown error',
    );
  }

  @override
  String toString() => 'BridgeError($code: $message)';
}

/// A push event from the bridge server (workspace/surface changes).
class BridgeEvent {
  final String event;
  final Map<String, dynamic> data;

  const BridgeEvent({required this.event, this.data = const {}});

  /// Parse a JSON text frame into an event.
  ///
  /// Returns null if the JSON is a response (has "id" key instead of "event").
  static BridgeEvent? fromJson(Map<String, dynamic> json) {
    final eventName = json['event'] as String?;
    if (eventName == null) return null;

    return BridgeEvent(
      event: eventName,
      data: json['data'] as Map<String, dynamic>? ?? const {},
    );
  }
}
