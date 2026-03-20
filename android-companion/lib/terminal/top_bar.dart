/// Top bar with tab strip and pane type icon trigger.
///
/// Sits above the content area (42px height).
/// Left: menu button + scrollable tab bar showing surfaces.
/// Right: pane type icon (36x36, colored per active type).
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';
import '../shared/pane_type_dropdown.dart';
import '../state/surface_provider.dart';
import 'tab_bar_strip.dart';

class TopBar extends StatelessWidget {
  final List<Surface> surfaces;
  final String? focusedSurfaceId;
  final ValueChanged<String> onSurfaceSelected;
  final ValueChanged<String>? onSurfaceLongPressed;
  final VoidCallback onMenuTap;
  final PaneType activePaneType;
  final ValueChanged<PaneType> onPaneTypeChanged;
  final VoidCallback? onNewTab;

  /// Normalised swipe progress [-1.0, 1.0] passed through to [TabBarStrip].
  /// See [TabBarStrip.swipeProgress] for semantics.
  final double? swipeProgress;

  /// Index of the surface being swiped toward, passed through to [TabBarStrip].
  /// See [TabBarStrip.swipeTargetIndex] for semantics.
  final int? swipeTargetIndex;

  const TopBar({
    super.key,
    required this.surfaces,
    this.focusedSurfaceId,
    required this.onSurfaceSelected,
    this.onSurfaceLongPressed,
    required this.onMenuTap,
    this.activePaneType = PaneType.terminal,
    required this.onPaneTypeChanged,
    this.onNewTab,
    this.swipeProgress,
    this.swipeTargetIndex,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: c.bgPrimary,
        border: Border(
          bottom: BorderSide(color: c.border),
        ),
      ),
      child: Row(
        children: [
          // Menu button (opens workspace drawer)
          GestureDetector(
            onTap: onMenuTap,
            child: SizedBox(
              width: 40,
              height: 42,
              child: Icon(Icons.menu, size: 18, color: c.textSecondary),
            ),
          ),

          // Scrollable tab strip (browser mode shows static tabs).
          // swipeProgress and swipeTargetIndex are forwarded so the strip can
          // crossfade underline indicators during horizontal swipe gestures.
          TabBarStrip(
            surfaces: surfaces,
            focusedSurfaceId: focusedSurfaceId,
            onSurfaceSelected: onSurfaceSelected,
            onSurfaceLongPressed: onSurfaceLongPressed,
            paneType: activePaneType,
            swipeProgress: swipeProgress,
            swipeTargetIndex: swipeTargetIndex,
          ),

          // New tab button
          if (onNewTab != null)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: SizedBox(
                width: 28,
                height: 28,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: onNewTab,
                    child: Icon(Icons.add, size: 16, color: c.textMuted),
                  ),
                ),
              ),
            ),

          // Pane type dropdown (icon-only trigger)
          PaneTypeDropdown(
            activeType: activePaneType,
            onTypeSelected: onPaneTypeChanged,
          ),
        ],
      ),
    );
  }
}
