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
  final VoidCallback onMenuTap;
  final PaneType activePaneType;
  final ValueChanged<PaneType> onPaneTypeChanged;

  const TopBar({
    super.key,
    required this.surfaces,
    this.focusedSurfaceId,
    required this.onSurfaceSelected,
    required this.onMenuTap,
    this.activePaneType = PaneType.terminal,
    required this.onPaneTypeChanged,
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

          // Scrollable tab strip (browser mode shows static tabs)
          TabBarStrip(
            surfaces: surfaces,
            focusedSurfaceId: focusedSurfaceId,
            onSurfaceSelected: onSurfaceSelected,
            paneType: activePaneType,
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
