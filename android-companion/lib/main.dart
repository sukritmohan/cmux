/// cmux Android companion app entry point.
///
/// Wraps the app in a Riverpod [ProviderScope] and uses GoRouter
/// for navigation. Starts with a pairing check: if unpaired, shows
/// the QR scanner; otherwise, shows the home screen.
///
/// Supports dark/light themes via [themeModeProvider].
library;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'notifications/attention_notification_handler.dart';
import 'notifications/fcm_token_manager.dart';
import 'notifications/firebase_config_store.dart';
import 'state/surface_provider.dart';
import 'state/workspace_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AttentionNotificationHandler.instance.initialize();
  await _initializeFirebaseIfConfigured();
  runApp(const ProviderScope(child: CmuxCompanionApp()));
}

/// Initializes Firebase with stored config if available.
///
/// Config is received from the Mac during pairing and stored in secure storage.
/// If no config is stored (user hasn't set up FCM), this is a no-op —
/// WebSocket-based notifications continue to work.
Future<void> _initializeFirebaseIfConfigured() async {
  final config = await FirebaseConfigStore.load();
  if (config == null) return;

  try {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: config.apiKey,
        appId: config.appId,
        messagingSenderId: config.senderId,
        projectId: config.projectId,
      ),
    );
    await FCMTokenManager.instance.initialize();
  } catch (e) {
    // Firebase init failure is non-fatal — WebSocket notifications still work.
    debugPrint('[main] Firebase initialization failed: $e');
  }
}

class CmuxCompanionApp extends ConsumerWidget {
  const CmuxCompanionApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);

    // Wire notification taps to workspace/surface navigation.
    AttentionNotificationHandler.onNotificationTapped = (workspaceId, surfaceId) {
      debugPrint('[main] notification tapped: ws=$workspaceId surface=$surfaceId');
      ref.read(workspaceProvider.notifier).selectWorkspace(workspaceId);
      if (surfaceId.isNotEmpty) {
        ref.read(surfaceProvider.notifier).focusSurface(surfaceId);
      }
    };

    return MaterialApp.router(
      title: 'cmux Companion',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
