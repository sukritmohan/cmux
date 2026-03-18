/// Riverpod providers for app-wide services.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/connection_manager.dart';
import '../connection/connection_state.dart';
import '../connection/pairing_service.dart';

/// Singleton connection manager.
final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  final manager = ConnectionManager();
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

/// Current theme mode (dark/light/system). Defaults to dark.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);
