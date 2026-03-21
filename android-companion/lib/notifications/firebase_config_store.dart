/// Stores and retrieves Firebase configuration received from the Mac during pairing.
///
/// The Mac extracts config from the user's `google-services.json` and sends it
/// during `auth.pair`. This store persists it in [FlutterSecureStorage] so
/// Firebase can be initialized at runtime without baking credentials into the APK.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Firebase configuration fields needed for `Firebase.initializeApp()`.
class FirebaseConfig {
  final String projectId;
  final String apiKey;
  final String senderId;
  final String appId;

  const FirebaseConfig({
    required this.projectId,
    required this.apiKey,
    required this.senderId,
    required this.appId,
  });

  factory FirebaseConfig.fromJson(Map<String, dynamic> json) {
    return FirebaseConfig(
      projectId: json['project_id'] as String,
      apiKey: json['api_key'] as String,
      senderId: json['sender_id'] as String,
      appId: json['app_id'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'project_id': projectId,
        'api_key': apiKey,
        'sender_id': senderId,
        'app_id': appId,
      };
}

/// Persists Firebase config in secure storage for runtime Firebase initialization.
class FirebaseConfigStore {
  static const _key = 'fcm_firebase_config';
  static const _storage = FlutterSecureStorage();

  /// Saves Firebase config received from the Mac during pairing.
  static Future<void> save(FirebaseConfig config) async {
    await _storage.write(key: _key, value: jsonEncode(config.toJson()));
  }

  /// Loads stored Firebase config, or `null` if not yet received.
  static Future<FirebaseConfig?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return FirebaseConfig.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Returns `true` if Firebase config has been stored.
  static Future<bool> hasConfig() async {
    return await _storage.containsKey(key: _key);
  }

  /// Removes stored Firebase config (e.g., on unpair).
  static Future<void> clear() async {
    await _storage.delete(key: _key);
  }
}
