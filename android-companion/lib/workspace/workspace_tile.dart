/// A single workspace item in the workspace drawer.
///
/// Shows workspace icon, name, and panel count. Active workspace
/// is highlighted with bgSurface background and blue right border.
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';
import '../state/workspace_provider.dart';

class WorkspaceTile extends StatelessWidget {
  final Workspace workspace;
  final bool isActive;
  final VoidCallback onTap;

  const WorkspaceTile({
    super.key,
    required this.workspace,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final panelCount = workspace.panels.length;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isActive ? AppColors.bgSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
          border: isActive
              ? const Border(
                  right: BorderSide(color: AppColors.accentBlue, width: 2),
                )
              : null,
        ),
        child: Row(
          children: [
            // Workspace icon
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: isActive ? AppColors.chipBg : AppColors.bgTertiary,
                borderRadius: BorderRadius.circular(AppColors.radiusSm),
              ),
              child: Icon(
                Icons.terminal,
                size: 16,
                color: isActive ? AppColors.accentBlue : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 12),

            // Name and metadata
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    workspace.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isActive
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '$panelCount panel${panelCount != 1 ? 's' : ''}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
