/// Horizontal scrollable tab bar strip showing surfaces in the current workspace.
///
/// Each tab shows an icon and title. The active tab has a blue underline,
/// blue text, and an elevated background. Tabs with running processes
/// show a green dot indicator.
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';
import '../state/surface_provider.dart';

class TabBarStrip extends StatelessWidget {
  final List<Surface> surfaces;
  final String? focusedSurfaceId;
  final ValueChanged<String> onSurfaceSelected;

  const TabBarStrip({
    super.key,
    required this.surfaces,
    this.focusedSurfaceId,
    required this.onSurfaceSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (surfaces.isEmpty) {
      return const Expanded(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'No tabs',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ),
      );
    }

    return Expanded(
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(left: 4),
        itemCount: surfaces.length,
        separatorBuilder: (_, __) => const SizedBox(width: 1),
        itemBuilder: (context, index) {
          final surface = surfaces[index];
          final isActive = surface.id == focusedSurfaceId;

          return _TabItem(
            surface: surface,
            isActive: isActive,
            onTap: () => onSurfaceSelected(surface.id),
          );
        },
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final Surface surface;
  final bool isActive;
  final VoidCallback onTap;

  const _TabItem({
    required this.surface,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isActive ? AppColors.bgTertiary : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: isActive ? AppColors.accentBlue : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Running process indicator
            if (surface.hasRunningProcess)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 6),
                decoration: const BoxDecoration(
                  color: AppColors.accentGreen,
                  shape: BoxShape.circle,
                ),
              ),

            // Terminal icon
            Icon(
              Icons.terminal,
              size: 14,
              color: isActive ? AppColors.accentBlue : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),

            // Tab title
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                surface.title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  color: isActive ? AppColors.accentBlue : AppColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
