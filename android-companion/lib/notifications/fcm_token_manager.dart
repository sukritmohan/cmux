/// Manages the Firebase Cloud Messaging token lifecycle.
///
/// After Firebase is initialized with config from the Mac, this manager:
/// 1. Retrieves the FCM device token
/// 2. Sends it to the Mac via `system.update_fcm_token`
/// 3. Listens for token refreshes and sends updates
/// 4. Handles incoming FCM messages (foreground + background)
library;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'attention_notification_handler.dart';

/// Top-level function for handling background FCM messages.
///
/// Must be a top-level function (not a method) for `onBackgroundMessage`.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundMessageHandler(RemoteMessage message) async {
  debugPrint('[FCMTokenManager] background message: ${message.messageId}');
  final data = message.data;
  await AttentionNotificationHandler.instance.showAttention(
    workspaceId: data['workspace_id'] ?? '',
    surfaceId: data['surface_id'] ?? '',
    reason: data['reason'] ?? 'notification',
    title: data['title'] ?? '',
  );
}

/// Singleton managing FCM token registration and message handling.
class FCMTokenManager {
  static final FCMTokenManager instance = FCMTokenManager._();
  FCMTokenManager._();

  /// Callback to send the FCM token to the Mac.
  /// Set by ConnectionManager when connected.
  void Function(String token)? onTokenAvailable;

  bool _initialized = false;

  /// Initialize FCM: get token, listen for refresh, set up message handlers.
  ///
  /// Call after `Firebase.initializeApp()` succeeds.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    final messaging = FirebaseMessaging.instance;

    // Request permission (Android 13+ requires explicit permission,
    // but flutter_local_notifications already handles this — FCM respects it).
    await messaging.requestPermission(
      alert: true,
      badge: false,
      sound: true,
    );

    // Get initial token and send to Mac.
    try {
      final token = await messaging.getToken();
      if (token != null) {
        debugPrint('[FCMTokenManager] initial token: ${token.substring(0, 20)}...');
        onTokenAvailable?.call(token);
      }
    } catch (e) {
      debugPrint('[FCMTokenManager] failed to get token: $e');
    }

    // Listen for token refreshes.
    messaging.onTokenRefresh.listen((token) {
      debugPrint('[FCMTokenManager] token refreshed');
      onTokenAvailable?.call(token);
    });

    // Foreground messages — show local notification.
    FirebaseMessaging.onMessage.listen((message) {
      debugPrint('[FCMTokenManager] foreground message: ${message.messageId}');
      final data = message.data;
      AttentionNotificationHandler.instance.showAttention(
        workspaceId: data['workspace_id'] ?? '',
        surfaceId: data['surface_id'] ?? '',
        reason: data['reason'] ?? 'notification',
        title: data['title'] ?? '',
      );
    });

    // Background messages.
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundMessageHandler);

    // User tapped a background FCM notification to open the app.
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      debugPrint('[FCMTokenManager] onMessageOpenedApp: ${message.messageId}');
      _navigateFromMessage(message);
    });

    // Cold-start: app was killed, user tapped a notification to launch it.
    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('[FCMTokenManager] getInitialMessage: ${initialMessage.messageId}');
      _navigateFromMessage(initialMessage);
    }
  }

  /// Extracts workspace/surface IDs from an FCM message and triggers navigation.
  void _navigateFromMessage(RemoteMessage message) {
    final data = message.data;
    final workspaceId = data['workspace_id'] ?? '';
    final surfaceId = data['surface_id'] ?? '';
    if (workspaceId.isEmpty) return;

    if (AttentionNotificationHandler.onNotificationTapped != null) {
      AttentionNotificationHandler.onNotificationTapped!.call(workspaceId, surfaceId);
    } else {
      // App not fully initialized yet — store for later consumption.
      AttentionNotificationHandler.pendingNavigation =
          (workspaceId: workspaceId, surfaceId: surfaceId);
    }
  }

  /// Reset state (e.g., on unpair).
  void reset() {
    _initialized = false;
    onTokenAvailable = null;
  }
}
