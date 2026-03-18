/// Horizontal scrollable tab bar strip showing surfaces in the current workspace.
///
/// Spec design (section 7):
/// - Font: IBM Plex Mono 11.5px/500, 0.2px letter spacing
/// - Active tab: textPrimary, bgSurface, amber underline (2px, 8px inset)
/// - Inactive: textMuted
/// - Connection dot: 5px green circle before active tab title
/// - Pane-group dot separators (3px textMuted dots)
/// - Right-edge fade gradient (32px)
/// - (+) button: 28x28, rounded 8px
///
/// When [paneType] is [PaneType.browser], static browser tabs are shown.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/colors.dart';
import '../shared/pane_type_dropdown.dart';
import '../state/surface_provider.dart';

/// Static browser tab descriptors for the browser pane.
class _BrowserTab {
  final String title;
  final bool isActive;

  const _BrowserTab({required this.title, required this.isActive});
}

const _staticBrowserTabs = [
  _BrowserTab(title: 'localhost', isActive: true),
  _BrowserTab(title: 'GitHub', isActive: false),
];

class TabBarStrip extends StatelessWidget {
  final List<Surface> surfaces;
  final String? focusedSurfaceId;
  final ValueChanged<String> onSurfaceSelected;
  final PaneType? paneType;

  const TabBarStrip({
    super.key,
    required this.surfaces,
    this.focusedSurfaceId,
    required this.onSurfaceSelected,
    this.paneType,
  });

  @override
  Widget build(BuildContext context) {
    if (paneType == PaneType.browser) {
      return _buildBrowserTabs(context);
    }
    return _buildSurfaceTabs(context);
  }

  Widget _buildBrowserTabs(BuildContext context) {
    final c = AppColors.of(context);

    return Expanded(
      child: _TabStripWrap(
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(left: 4),
          itemCount: _staticBrowserTabs.length,
          itemBuilder: (context, index) {
            final tab = _staticBrowserTabs[index];
            return _TabChip(
              title: tab.title,
              icon: Icons.language,
              isActive: tab.isActive,
              accentColor: c.browserColor,
              showConnectionDot: tab.isActive,
            );
          },
        ),
      ),
    );
  }

  Widget _buildSurfaceTabs(BuildContext context) {
    final c = AppColors.of(context);

    if (surfaces.isEmpty) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'No tabs',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: c.textMuted,
              ),
            ),
          ),
        ),
      );
    }

    return Expanded(
      child: _TabStripWrap(
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(left: 4),
          itemCount: surfaces.length,
          itemBuilder: (context, index) {
            final surface = surfaces[index];
            final isActive = surface.id == focusedSurfaceId;

            return GestureDetector(
              onTap: () => onSurfaceSelected(surface.id),
              child: _TabChip(
                title: surface.title,
                icon: Icons.terminal,
                isActive: isActive,
                accentColor: c.accent,
                showConnectionDot: isActive && surface.hasRunningProcess,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Wraps the tab strip with a right-edge fade gradient (32px).
class _TabStripWrap extends StatelessWidget {
  final Widget child;

  const _TabStripWrap({required this.child});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Stack(
      children: [
        child,
        // Right-edge fade gradient hinting at scrollability
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 32,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    c.bgPrimary.withAlpha(0),
                    c.bgPrimary,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A single tab chip matching the spec design.
class _TabChip extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isActive;
  final Color accentColor;
  final bool showConnectionDot;

  const _TabChip({
    required this.title,
    required this.icon,
    required this.isActive,
    required this.accentColor,
    this.showConnectionDot = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11),
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: isActive ? c.bgSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Connection dot (5px green circle before active tab title)
              if (showConnectionDot)
                Container(
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: c.connectedColor,
                    shape: BoxShape.circle,
                  ),
                ),

              // Tab title (IBM Plex Mono 11.5px/500)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  title,
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                    color: isActive ? c.textPrimary : c.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          // Amber underline (2px, 8px inset from edges)
          if (isActive)
            Container(
              height: 2,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: BorderRadius.circular(1),
              ),
              // Width set by parent constraints
            ),
        ],
      ),
    );
  }
}
