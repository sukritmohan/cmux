/// Riverpod providers for app-wide services.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection/connection_manager.dart';
import '../connection/connection_state.dart';
import '../connection/pairing_service.dart';

/// Singleton connection manager with lifecycle and network awareness.
final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  final manager = ConnectionManager();
  manager.initLifecycleObserver();
  ref.onDispose(() => manager.dispose());
  return manager;
});

/// Singleton pairing service.
final pairingServiceProvider = Provider<PairingService>((ref) {
  return PairingService();
});

/// Stream of connection status changes.
final connectionStatusProvider = StreamProvider<ConnectionStatus>((ref) {
  final manager = ref.watch(connectionManagerProvider);
  return manager.statusStream;
});

/// Whether the device has stored pairing credentials.
final isPairedProvider = FutureProvider<bool>((ref) async {
  final pairing = ref.watch(pairingServiceProvider);
  return pairing.isPaired();
});

/// Current theme mode (dark/light/system). Persists across restarts via
/// SharedPreferences. Defaults to dark until the saved preference is loaded.
final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

/// Notifier that persists the user's theme preference to SharedPreferences.
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  static const _key = 'theme_mode';

  ThemeModeNotifier() : super(ThemeMode.dark) {
    _loadSavedTheme();
  }

  Future<void> _loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved == 'light') {
      state = ThemeMode.light;
    }
    // If null or 'dark', keep the default ThemeMode.dark.
  }

  /// Update the theme mode and persist the choice.
  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      mode == ThemeMode.light ? 'light' : 'dark',
    );
  }
}
