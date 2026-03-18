/// URL bar component for the browser view.
///
/// Row layout: back/forward nav buttons + URL field with styled scheme/host/path.
/// Bottom border separates it from the web content area below.
import 'package:flutter/material.dart';

import '../app/colors.dart';

/// Static URL data for the mock browser view.
class MockUrl {
  final String scheme;
  final String host;
  final String path;

  const MockUrl({
    required this.scheme,
    required this.host,
    this.path = '',
  });
}

class UrlBar extends StatelessWidget {
  /// Whether the back button is enabled.
  final bool canGoBack;

  /// Whether the forward button is enabled.
  final bool canGoForward;

  /// URL to display, split into scheme/host/path for styled rendering.
  final MockUrl url;

  const UrlBar({
    super.key,
    this.canGoBack = false,
    this.canGoForward = false,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: c.bgPrimary,
        border: Border(
          bottom: BorderSide(color: c.border),
        ),
      ),
      child: Row(
        children: [
          // Back button
          _NavButton(
            icon: Icons.arrow_back_ios_new,
            enabled: canGoBack,
          ),
          const SizedBox(width: 8),

          // Forward button
          _NavButton(
            icon: Icons.arrow_forward_ios,
            enabled: canGoForward,
          ),
          const SizedBox(width: 8),

          // URL field
          Expanded(
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: c.bgSurface,
                borderRadius: BorderRadius.circular(AppColors.radiusSm),
              ),
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(
                  children: [
                    // Scheme at 40% opacity
                    TextSpan(
                      text: url.scheme,
                      style: TextStyle(
                        fontSize: 12,
                        color: c.textPrimary.withAlpha(102),
                      ),
                    ),
                    // Host at full opacity
                    TextSpan(
                      text: url.host,
                      style: TextStyle(
                        fontSize: 12,
                        color: c.textPrimary,
                      ),
                    ),
                    // Path in secondary color
                    if (url.path.isNotEmpty)
                      TextSpan(
                        text: url.path,
                        style: TextStyle(
                          fontSize: 12,
                          color: c.textSecondary,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 28x28 navigation button (back/forward).
class _NavButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;

  const _NavButton({
    required this.icon,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return SizedBox(
      width: 28,
      height: 28,
      child: Icon(
        icon,
        size: 14,
        color: enabled ? c.textSecondary : c.textMuted,
      ),
    );
  }
}
