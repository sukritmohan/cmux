/// Pairing service for QR code credential management.
///
/// Parses QR payloads from BridgeSettingsView.swift ({"host", "port", "token"})
/// and stores credentials securely in Android Keystore via FlutterSecureStorage.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stored pairing credentials.
class PairingCredentials {
  final String host;
  final int port;
  final String token;

  const PairingCredentials({
    required this.host,
    required this.port,
    required this.token,
  });
}

class PairingService {
  static const _keyHost = 'cmux_bridge_host';
  static const _keyPort = 'cmux_bridge_port';
  static const _keyToken = 'cmux_bridge_token';

  final FlutterSecureStorage _storage;

  PairingService()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );

  /// Parse a QR code payload string into credentials.
  ///
  /// Expected format (from BridgeSettingsView.swift:174):
  /// ```json
  /// {"host": "<tailscale-ip>", "port": 17377, "token": "<base64>"}
  /// ```
  ///
  /// Returns null if the payload is malformed.
  PairingCredentials? parseQrPayload(String rawPayload) {
    try {
      final json = jsonDecode(rawPayload) as Map<String, dynamic>;
      final host = json['host'] as String?;
      final port = json['port'] as int?;
      final token = json['token'] as String?;

      if (host == null || host.isEmpty || port == null || token == null || token.isEmpty) {
        return null;
      }

      return PairingCredentials(host: host, port: port, token: token);
    } catch (_) {
      return null;
    }
  }

  /// Store pairing credentials in Android Keystore.
  Future<void> saveCredentials(PairingCredentials credentials) async {
    await Future.wait([
      _storage.write(key: _keyHost, value: credentials.host),
      _storage.write(key: _keyPort, value: credentials.port.toString()),
      _storage.write(key: _keyToken, value: credentials.token),
    ]);
  }

  /// Load stored credentials, or null if not paired.
  Future<PairingCredentials?> loadCredentials() async {
    final results = await Future.wait([
      _storage.read(key: _keyHost),
      _storage.read(key: _keyPort),
      _storage.read(key: _keyToken),
    ]);

    final host = results[0];
    final portStr = results[1];
    final token = results[2];

    if (host == null || portStr == null || token == null) return null;

    final port = int.tryParse(portStr);
    if (port == null) return null;

    return PairingCredentials(host: host, port: port, token: token);
  }

  /// Check if credentials are stored.
  Future<bool> isPaired() async {
    return await _storage.read(key: _keyToken) != null;
  }

  /// Clear stored credentials (unpair).
  Future<void> clearCredentials() async {
    await Future.wait([
      _storage.delete(key: _keyHost),
      _storage.delete(key: _keyPort),
      _storage.delete(key: _keyToken),
    ]);
  }
}
