/// GoRouter configuration for the cmux companion app.
///
/// Routes:
///   /pair      - QR code scanning (shown if unpaired)
///   /terminal  - Main terminal screen (workspace tabs, modifier bar, drawer)
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../onboarding/pairing_screen.dart';
import '../terminal/terminal_screen.dart';
import 'providers.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/terminal',
    redirect: (context, state) async {
      final isPaired = await ref.read(pairingServiceProvider).isPaired();

      // Redirect unpaired users to the pairing screen.
      if (!isPaired && state.uri.path != '/pair') {
        return '/pair';
      }

      // Redirect paired users away from /pair unless they intentionally
      // tapped the QR scanner button (rescan=true).
      if (isPaired &&
          state.uri.path == '/pair' &&
          state.uri.queryParameters['rescan'] != 'true') {
        return '/terminal';
      }

      // Legacy /home route → redirect to /terminal.
      if (state.uri.path == '/home') {
        return '/terminal';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/pair',
        builder: (context, state) => PairingScreen(
          rescan: state.uri.queryParameters['rescan'] == 'true',
        ),
      ),
      GoRoute(
        path: '/terminal',
        builder: (context, state) => const TerminalScreen(),
      ),
    ],
  );
});
