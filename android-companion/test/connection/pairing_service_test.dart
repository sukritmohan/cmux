import 'package:cmux_companion/connection/pairing_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairingService.parseQrPayload', () {
    late PairingService service;

    setUp(() {
      service = PairingService();
    });

    test('parses valid QR payload', () {
      const payload = '{"host":"100.64.0.1","port":17377,"token":"dGVzdHRva2Vu"}';
      final credentials = service.parseQrPayload(payload);

      expect(credentials, isNotNull);
      expect(credentials!.host, equals('100.64.0.1'));
      expect(credentials.port, equals(17377));
      expect(credentials.token, equals('dGVzdHRva2Vu'));
    });

    test('returns null for invalid JSON', () {
      expect(service.parseQrPayload('not json'), isNull);
      expect(service.parseQrPayload(''), isNull);
      expect(service.parseQrPayload('{'), isNull);
    });

    test('returns null when host is missing', () {
      const payload = '{"port":17377,"token":"abc"}';
      expect(service.parseQrPayload(payload), isNull);
    });

    test('returns null when host is empty', () {
      const payload = '{"host":"","port":17377,"token":"abc"}';
      expect(service.parseQrPayload(payload), isNull);
    });

    test('returns null when port is missing', () {
      const payload = '{"host":"100.64.0.1","token":"abc"}';
      expect(service.parseQrPayload(payload), isNull);
    });

    test('returns null when token is missing', () {
      const payload = '{"host":"100.64.0.1","port":17377}';
      expect(service.parseQrPayload(payload), isNull);
    });

    test('returns null when token is empty', () {
      const payload = '{"host":"100.64.0.1","port":17377,"token":""}';
      expect(service.parseQrPayload(payload), isNull);
    });

    test('handles extra fields gracefully', () {
      const payload =
          '{"host":"100.64.0.1","port":17377,"token":"abc","extra":"ignored"}';
      final credentials = service.parseQrPayload(payload);
      expect(credentials, isNotNull);
      expect(credentials!.host, equals('100.64.0.1'));
    });
  });
}
