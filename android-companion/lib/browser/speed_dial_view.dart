/// Speed dial new tab page with discovered ports and recent URLs.
///
/// Shown when a browser tab has no URL. Displays a grid of active ports
/// from the desktop Mac and a list of recently visited URLs.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/colors.dart';
import '../app/providers.dart';
import 'browser_tab_provider.dart';
import 'url_rewriter.dart';

/// Polling interval for ports.list API while the speed dial is visible.
const _portsRefreshInterval = Duration(seconds: 10);

class SpeedDialView extends ConsumerStatefulWidget {
  /// Called when the user selects a URL (port card or recent URL tap).
  final ValueChanged<String> onUrlSelected;

  const SpeedDialView({
    super.key,
    required this.onUrlSelected,
  });

  @override
  ConsumerState<SpeedDialView> createState() => _SpeedDialViewState();
}

class _SpeedDialViewState extends ConsumerState<SpeedDialView> {
  Timer? _portsTimer;

  @override
  void initState() {
    super.initState();
    _fetchPorts();
    _portsTimer = Timer.periodic(_portsRefreshInterval, (_) => _fetchPorts());
  }

  @override
  void dispose() {
    _portsTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchPorts() async {
    try {
      final manager = ref.read(connectionManagerProvider);
      final response = await manager.sendRequest('ports.list');
      if (!response.ok || response.result == null) return;

      final portsList = response.result!['ports'] as List?;
      if (portsList == null) return;

      final ports = portsList.cast<Map<String, dynamic>>().map((p) {
        return DiscoveredPort(
          port: p['port'] as int? ?? 0,
          processName: p['process_name'] as String? ?? p['name'] as String?,
          protocol: p['protocol'] as String?,
        );
      }).toList();

      ref.read(browserTabProvider.notifier).setDiscoveredPorts(ports);
    } catch (e) {
      debugPrint('[SpeedDial] Failed to fetch ports: $e');
    }
  }

  String get _tailscaleIp {
    final manager = ref.read(connectionManagerProvider);
    return manager.host ?? '100.0.0.0';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final state = ref.watch(browserTabProvider);

    return Container(
      color: c.bgDeep,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Discovered Ports section
            if (state.discoveredPorts.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    'ACTIVE PORTS',
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                      color: c.textMuted,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _fetchPorts,
                    child: Icon(Icons.refresh, size: 16, color: c.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _PortsGrid(
                ports: state.discoveredPorts,
                onPortTapped: (port) {
                  final protocol = port.protocol ?? 'http';
                  widget.onUrlSelected('$protocol://$_tailscaleIp:${port.port}');
                },
              ),
              const SizedBox(height: 24),
            ],

            // Recent URLs section
            if (state.recentUrls.isNotEmpty) ...[
              Text(
                'RECENT',
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                  color: c.textMuted,
                ),
              ),
              const SizedBox(height: 10),
              ...state.recentUrls.map((recent) => _RecentUrlRow(
                    recentUrl: recent,
                    onTap: () => widget.onUrlSelected(recent.url),
                  )),
            ],

            // Empty state
            if (state.discoveredPorts.isEmpty && state.recentUrls.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 48),
                  child: Column(
                    children: [
                      Icon(Icons.language, size: 48, color: c.textMuted),
                      const SizedBox(height: 12),
                      Text(
                        'Type a URL above to get started',
                        style: TextStyle(fontSize: 13, color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 2-column grid of discovered port cards.
class _PortsGrid extends StatelessWidget {
  final List<DiscoveredPort> ports;
  final ValueChanged<DiscoveredPort> onPortTapped;

  const _PortsGrid({
    required this.ports,
    required this.onPortTapped,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.2,
      ),
      itemCount: ports.length,
      itemBuilder: (context, index) {
        return _PortCard(
          port: ports[index],
          onTap: () => onPortTapped(ports[index]),
        );
      },
    );
  }
}

/// A single port card showing port number and process name.
class _PortCard extends StatelessWidget {
  final DiscoveredPort port;
  final VoidCallback onTap;

  const _PortCard({
    required this.port,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Material(
      color: c.bgSurface,
      borderRadius: BorderRadius.circular(AppColors.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                ':${port.port}',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.browserColor,
                ),
              ),
              if (port.processName != null) ...[
                const SizedBox(height: 2),
                Text(
                  port.processName!,
                  style: TextStyle(
                    fontSize: 11,
                    color: c.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A single recent URL row with globe icon, title, and subdued URL.
class _RecentUrlRow extends StatelessWidget {
  final RecentUrl recentUrl;
  final VoidCallback onTap;

  const _RecentUrlRow({
    required this.recentUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final parsed = parseDisplayUrl(recentUrl.url);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Icon(Icons.language, size: 18, color: c.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recentUrl.title ?? parsed.host,
                      style: TextStyle(fontSize: 13, color: c.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      recentUrl.url,
                      style: TextStyle(fontSize: 11, color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
