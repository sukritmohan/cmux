/// Home screen showing connection status and workspace list.
///
/// Displays a colored status indicator dot, and lists workspaces
/// fetched via the `workspace.list` bridge command. Tapping a
/// workspace navigates to the terminal view.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../connection/connection_state.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  List<Map<String, dynamic>> _workspaces = [];
  bool _loading = true;
  StreamSubscription? _statusSub;

  @override
  void initState() {
    super.initState();
    _initConnection();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _initConnection() async {
    final manager = ref.read(connectionManagerProvider);
    final pairing = ref.read(pairingServiceProvider);

    final credentials = await pairing.loadCredentials();
    if (credentials == null) {
      if (mounted) context.go('/pair');
      return;
    }

    manager.setCredentials(
      host: credentials.host,
      port: credentials.port,
      token: credentials.token,
    );

    // Listen for connected status to fetch workspaces.
    _statusSub = manager.statusStream.listen((status) {
      if (status == ConnectionStatus.connected) {
        _fetchWorkspaces();
      }
    });

    await manager.connect();
  }

  Future<void> _fetchWorkspaces() async {
    setState(() => _loading = true);

    try {
      final manager = ref.read(connectionManagerProvider);
      final response = await manager.sendRequest('workspace.list');

      if (response.ok && response.result != null) {
        final workspaces = response.result!['workspaces'];
        if (workspaces is List) {
          setState(() {
            _workspaces = workspaces.cast<Map<String, dynamic>>();
            _loading = false;
          });
          return;
        }
      }
    } catch (_) {
      // Connection not ready or request failed.
    }

    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(connectionStatusProvider);
    final currentStatus = statusAsync.valueOrNull ?? ConnectionStatus.disconnected;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusDot(status: currentStatus),
            const SizedBox(width: 8),
            const Text('cmux'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchWorkspaces,
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => context.go('/pair?rescan=true'),
          ),
        ],
      ),
      body: _buildBody(currentStatus),
    );
  }

  Widget _buildBody(ConnectionStatus status) {
    if (status == ConnectionStatus.connecting ||
        status == ConnectionStatus.authenticating) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF00C853)),
            SizedBox(height: 16),
            Text('Connecting to Mac...'),
          ],
        ),
      );
    }

    if (status == ConnectionStatus.reconnecting) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFFFA726)),
            SizedBox(height: 16),
            Text('Reconnecting...'),
          ],
        ),
      );
    }

    if (status == ConnectionStatus.disconnected) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('Not connected'),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _initConnection,
              child: const Text('Reconnect'),
            ),
          ],
        ),
      );
    }

    // Connected
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00C853)),
      );
    }

    if (_workspaces.isEmpty) {
      return const Center(
        child: Text('No workspaces found.\nOpen a terminal on your Mac.'),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchWorkspaces,
      child: ListView.builder(
        itemCount: _workspaces.length,
        itemBuilder: (context, index) {
          final ws = _workspaces[index];
          final name = ws['title'] as String? ?? 'Workspace ${index + 1}';
          final surfaceId = ws['surface_id'] as String? ?? '';
          final panelCount = (ws['panels'] as List?)?.length ?? 0;

          return ListTile(
            leading: const Icon(Icons.terminal, color: Color(0xFF00C853)),
            title: Text(name),
            subtitle: Text('$panelCount panel${panelCount != 1 ? 's' : ''}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              if (surfaceId.isNotEmpty) {
                context.go('/terminal/$surfaceId');
              }
            },
          );
        },
      ),
    );
  }
}

/// Colored dot indicating connection status.
class _StatusDot extends StatelessWidget {
  final ConnectionStatus status;

  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (status) {
      case ConnectionStatus.connected:
        color = const Color(0xFF00C853);
      case ConnectionStatus.connecting:
      case ConnectionStatus.authenticating:
        color = const Color(0xFFFFA726);
      case ConnectionStatus.reconnecting:
        color = const Color(0xFFFFA726);
      case ConnectionStatus.disconnected:
        color = const Color(0xFFCF6679);
    }

    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
