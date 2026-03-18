/// GoRouter configuration for the cmux companion app.
///
/// Routes:
///   /pair     - QR code scanning (shown if unpaired)
///   /home     - Workspace list + connection status
///   /terminal/:surfaceId - Full-screen terminal view
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../home/home_screen.dart';
import '../onboarding/pairing_screen.dart';
import '../terminal/terminal_view.dart';
import 'providers.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/home',
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
        return '/home';
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
        path: '/home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/terminal/:surfaceId',
        builder: (context, state) {
          final surfaceId = state.pathParameters['surfaceId']!;
          return TerminalView(surfaceId: surfaceId);
        },
      ),
    ],
  );
});
