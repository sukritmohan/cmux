/// A single workspace item in the workspace drawer.
///
/// Shows workspace name, panel count, optional git branch badge, and
/// notification count badge. Active workspace is highlighted with a
/// 3px amber left bar and bgSurface background.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
    final c = AppColors.of(context);
    final panelCount = workspace.panels.length;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? c.bgSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
          border: isActive
              ? Border(
                  left: BorderSide(color: c.accent, width: 3),
                )
              : null,
        ),
        child: Row(
          children: [
            // Name, branch badge, and metadata — stacked vertically
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Workspace name
                  Text(
                    workspace.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isActive ? c.textPrimary : c.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: 4),

                  // Metadata row: panel count + optional branch badge
                  Row(
                    children: [
                      Text(
                        '$panelCount panel${panelCount != 1 ? 's' : ''}',
                        style: TextStyle(
                          fontSize: 11,
                          color: c.textMuted,
                        ),
                      ),
                      if (workspace.branch != null) ...[
                        const SizedBox(width: 6),
                        _BranchBadge(branch: workspace.branch!, colors: c),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Notification badge — positioned on the right
            if (workspace.notificationCount > 0)
              _NotificationBadge(
                count: workspace.notificationCount,
                colors: c,
              ),
          ],
        ),
      ),
    );
  }
}

/// Pill-shaped badge showing the git branch name.
class _BranchBadge extends StatelessWidget {
  final String branch;
  final AppColorScheme colors;

  const _BranchBadge({required this.branch, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: colors.accentGlow,
        borderRadius: BorderRadius.circular(AppColors.radiusXs),
      ),
      child: Text(
        branch,
        style: GoogleFonts.ibmPlexMono(
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          color: colors.accentText,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Amber circle showing the unread notification count.
class _NotificationBadge extends StatelessWidget {
  final int count;
  final AppColorScheme colors;

  const _NotificationBadge({required this.count, required this.colors});

  @override
  Widget build(BuildContext context) {
    // Cap display at 99 to prevent overflow in the small badge
    final label = count > 99 ? '99+' : '$count';

    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.accent,
        shape: BoxShape.circle,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}
