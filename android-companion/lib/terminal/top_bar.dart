/// Top bar with tab strip and pane type dropdown.
///
/// Sits above the terminal content area (40px height).
/// Left: menu button + scrollable tab bar showing surfaces.
/// Right: pane type selector separated by a 1px divider.
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

  const TopBar({
    super.key,
    required this.surfaces,
    this.focusedSurfaceId,
    required this.onSurfaceSelected,
    required this.onMenuTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.bgSecondary,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(66), // ~26%
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          // Menu button (opens workspace drawer)
          GestureDetector(
            onTap: onMenuTap,
            child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.menu, size: 18, color: AppColors.textSecondary),
            ),
          ),

          // Scrollable tab strip
          TabBarStrip(
            surfaces: surfaces,
            focusedSurfaceId: focusedSurfaceId,
            onSurfaceSelected: onSurfaceSelected,
          ),

          // 1px vertical divider
          Container(
            width: 1,
            height: 20,
            color: AppColors.borderSubtle,
          ),

          // Pane type dropdown
          const PaneTypeDropdown(),
        ],
      ),
    );
  }
}
