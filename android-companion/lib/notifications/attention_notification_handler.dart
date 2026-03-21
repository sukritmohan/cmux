/// Handles Android system notifications for terminal attention events.
///
/// Initializes [flutter_local_notifications] and provides [showAttention]
/// to display a notification when a surface needs the user's attention
/// (bell, Claude Code idle, etc.).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Singleton handler for terminal attention notifications on Android.
class AttentionNotificationHandler {
  static final AttentionNotificationHandler instance =
      AttentionNotificationHandler._();

  AttentionNotificationHandler._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Channel ID for terminal attention notifications.
  static const _channelId = 'cmux_attention';
  static const _channelName = 'Terminal Attention';
  static const _channelDescription =
      'Notifications when a terminal pane needs attention';

  /// Initialize the notification plugin. Safe to call multiple times.
  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(initSettings);

    // Request notification permission on Android 13+ (API 33+).
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final granted = await androidPlugin.requestNotificationsPermission();
      debugPrint('[AttentionNotificationHandler] permission granted=$granted');
    }

    _initialized = true;
  }

  /// Show an Android system notification for a surface.attention event.
  ///
  /// [workspaceId] and [surfaceId] identify the source.
  /// [reason] describes why (e.g. "bell", "notification").
  /// [title] is the notification title from the desktop event.
  Future<void> showAttention({
    required String workspaceId,
    required String surfaceId,
    required String reason,
    required String title,
  }) async {
    if (!_initialized) await initialize();

    debugPrint('[AttentionNotificationHandler] showAttention ws=$workspaceId reason=$reason title=$title');
    final displayTitle = title.isNotEmpty ? title : 'Terminal attention';
    final displayBody = reason == 'bell'
        ? 'Terminal bell in workspace'
        : 'Terminal needs attention';

    // Use a unique ID so each notification alerts separately.
    // Includes timestamp to avoid silent replacement of existing notifications.
    final notificationId =
        (workspaceId + surfaceId + DateTime.now().millisecondsSinceEpoch.toString()).hashCode;

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(notificationId, displayTitle, displayBody, details);
  }
}
