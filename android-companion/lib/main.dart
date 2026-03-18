/// cmux Android companion app entry point.
///
/// Wraps the app in a Riverpod [ProviderScope] and uses GoRouter
/// for navigation. Starts with a pairing check: if unpaired, shows
/// the QR scanner; otherwise, shows the home screen.
///
/// Supports dark/light themes via [themeModeProvider].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'app/router.dart';
import 'app/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: CmuxCompanionApp()));
}

class CmuxCompanionApp extends ConsumerWidget {
  const CmuxCompanionApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);

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
