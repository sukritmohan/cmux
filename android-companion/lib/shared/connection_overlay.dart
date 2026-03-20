/// Connection state overlay displayed on top of the terminal screen.
///
/// Shows different states: connecting, authenticating, reconnecting,
/// disconnected, with appropriate animations and actions.
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';
import '../connection/connection_state.dart';

/// Warning orange for reconnecting state (not theme-dependent).
const _warningOrange = Color(0xFFD29922);

class ConnectionOverlay extends StatelessWidget {
  final ConnectionStatus status;
  final VoidCallback onReconnect;
  final VoidCallback? onRepair;

  const ConnectionOverlay({
    super.key,
    required this.status,
    required this.onReconnect,
    this.onRepair,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      color: c.bgPrimary.withAlpha(230),
      child: Center(
        child: _buildContent(c),
      ),
    );
  }

  Widget _buildContent(AppColorScheme c) {
    switch (status) {
      case ConnectionStatus.connecting:
      case ConnectionStatus.authenticating:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PulseRing(color: c.accent),
            const SizedBox(height: 24),
            Text(
              'Connecting to Mac...',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 16,
              ),
            ),
          ],
        );

      case ConnectionStatus.reconnecting:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PulseRing(color: _warningOrange),
            const SizedBox(height: 24),
            Text(
              'Reconnecting...',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 16,
              ),
            ),
            if (onRepair != null) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: onRepair,
                child: Text(
                  'Re-pair',
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ],
        );

      case ConnectionStatus.disconnected:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: c.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              'Connection lost',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Check your Tailscale connection and try again.',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onReconnect,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Reconnect'),
            ),
            if (onRepair != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: onRepair,
                child: Text(
                  'Re-pair',
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ],
        );

      case ConnectionStatus.connected:
        // Should not be shown when connected.
        return const SizedBox.shrink();
    }
  }
}

/// Animated pulse ring indicator for connecting/reconnecting states.
class _PulseRing extends StatefulWidget {
  final Color color;
  const _PulseRing({required this.color});

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final scale = 1.0 + _controller.value * 0.5;
        final opacity = 1.0 - _controller.value;

        return SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Pulse ring
              Transform.scale(
                scale: scale,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: widget.color.withAlpha((opacity * 150).toInt()),
                      width: 2,
                    ),
                  ),
                ),
              ),
              // Center dot
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
