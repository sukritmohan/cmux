import 'dart:convert';

import 'package:cmux_companion/connection/message_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BridgeRequest', () {
    test('serializes to JSON with params', () {
      final request = BridgeRequest(
        id: 1,
        method: 'auth.pair',
        params: {'token': 'abc123'},
      );

      final json = jsonDecode(request.toJson()) as Map<String, dynamic>;
      expect(json['id'], equals(1));
      expect(json['method'], equals('auth.pair'));
      expect(json['params']['token'], equals('abc123'));
    });

    test('omits params when empty', () {
      final request = BridgeRequest(id: 2, method: 'system.subscribe_events');

      final json = jsonDecode(request.toJson()) as Map<String, dynamic>;
      expect(json.containsKey('params'), isFalse);
    });
  });

  group('BridgeResponse', () {
    test('parses success response', () {
      final json = {
        'id': 1,
        'ok': true,
        'result': {'authenticated': true},
      };

      final response = BridgeResponse.fromJson(json);
      expect(response, isNotNull);
      expect(response!.ok, isTrue);
      expect(response.id, equals(1));
      expect(response.result?['authenticated'], isTrue);
      expect(response.error, isNull);
    });

    test('parses error response', () {
      final json = {
        'id': 1,
        'ok': false,
        'error': {'code': 'auth_failed', 'message': 'Invalid token'},
      };

      final response = BridgeResponse.fromJson(json);
      expect(response, isNotNull);
      expect(response!.ok, isFalse);
      expect(response.error?.code, equals('auth_failed'));
      expect(response.error?.message, equals('Invalid token'));
    });

    test('returns null for event messages', () {
      final json = {
        'event': 'workspace.changed',
        'data': {'workspace_id': 'abc'},
      };

      expect(BridgeResponse.fromJson(json), isNull);
    });
  });

  group('BridgeEvent', () {
    test('parses event message', () {
      final json = {
        'event': 'surface.created',
        'data': {'surface_id': 'uuid-123'},
      };

      final event = BridgeEvent.fromJson(json);
      expect(event, isNotNull);
      expect(event!.event, equals('surface.created'));
      expect(event.data['surface_id'], equals('uuid-123'));
    });

    test('returns null for response messages', () {
      final json = {'id': 1, 'ok': true, 'result': {}};
      expect(BridgeEvent.fromJson(json), isNull);
    });

    test('defaults data to empty map', () {
      final json = {'event': 'ping'};
      final event = BridgeEvent.fromJson(json);
      expect(event?.data, isEmpty);
    });
  });

  group('BridgeError', () {
    test('provides defaults for missing fields', () {
      final error = BridgeError.fromJson({});
      expect(error.code, equals('unknown'));
      expect(error.message, equals('Unknown error'));
    });

    test('toString includes code and message', () {
      final error = BridgeError(code: 'test', message: 'Test error');
      expect(error.toString(), contains('test'));
      expect(error.toString(), contains('Test error'));
    });
  });
}
