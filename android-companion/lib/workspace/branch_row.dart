/// Branch row in the workspace drawer hierarchy.
///
/// Shows a fork icon, the branch name in IBM Plex Mono, an optional dirty
/// dot indicator, an animated disclosure chevron, and a (+) button to create
/// a new workspace on this branch. Sits at the second indentation level
/// (24px left padding) beneath [ProjectRow].
///
/// When [highlightQuery] is non-empty, matching substrings in the branch
/// name are rendered in accent color for search result visualization.
///
/// When [aggregateNotificationCount] > 0 and the branch is collapsed,
/// a notification badge is shown to bubble up unread counts from child
/// workspaces hidden beneath the fold.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/project_hierarchy_provider.dart';
import 'highlight_helper.dart';

/// A branch row within a project section in the drawer tree.
///
/// Tapping the row toggles expand/collapse of the branch's workspaces.
/// The (+) button creates a new workspace scoped to the parent project's
/// repo path.
class BranchRow extends StatelessWidget {
  /// The branch model to render.
  final SidebarBranch branch;

  /// Whether the branch section is currently expanded in the drawer.
  final bool isExpanded;

  /// Called when the user taps to toggle expand/collapse.
  final VoidCallback onTap;

  /// Called when the user taps the (+) button to create a new workspace.
  /// Null when workspace creation is not available.
  final VoidCallback? onAddWorkspace;

  /// Search query for substring highlighting. When non-null and non-empty,
  /// matching segments in the branch name are rendered in accent color.
  final String? highlightQuery;

  /// Sum of unread notification counts across all workspaces on this branch.
  /// Shown as a badge when the branch is collapsed and count > 0.
  final int aggregateNotificationCount;

  const BranchRow({
    super.key,
    required this.branch,
    required this.isExpanded,
    required this.onTap,
    this.onAddWorkspace,
    this.highlightQuery,
    this.aggregateNotificationCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 30),
        padding: const EdgeInsets.fromLTRB(24, 5, 8, 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          children: [
            _buildChevron(isDark),
            const SizedBox(width: 2),
            _buildForkIcon(isDark),
            const SizedBox(width: 4),
            Flexible(child: _buildName(isDark)),
            const Spacer(),
            if (branch.isDirty) ...[
              const SizedBox(width: 5),
              _buildDirtyDot(),
            ],

            // Aggregate notification badge when collapsed.
            if (!isExpanded && aggregateNotificationCount > 0) ...[
              const SizedBox(width: 5),
              _NotificationBadge(count: aggregateNotificationCount),
            ],

            const SizedBox(width: 6),
            _buildAddButton(isDark),
          ],
        ),
      ),
    );
  }

  /// Animated disclosure chevron — smaller than the project level (14px).
  Widget _buildChevron(bool isDark) {
    final chevronColor = isDark
        ? const Color(0x33E8E8EE) // rgba(232,232,238,0.20)
        : const Color(0x331A1A1F); // rgba(26,26,31,0.20)

    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedRotation(
        turns: isExpanded ? 0.0 : -0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: Icon(
          Icons.expand_more,
          size: 12,
          color: chevronColor,
        ),
      ),
    );
  }

  /// Git fork icon rendered as a small material icon.
  Widget _buildForkIcon(bool isDark) {
    final iconColor = isDark
        ? const Color(0x4DE8E8EE) // rgba(232,232,238,0.30)
        : const Color(0x4D1A1A1F); // rgba(26,26,31,0.30)

    return Icon(
      Icons.fork_right,
      size: 12,
      color: iconColor,
    );
  }

  /// Branch name in IBM Plex Mono at 11.5px, 48% opacity.
  ///
  /// When [highlightQuery] is active, matching substrings are rendered
  /// in accent color.
  Widget _buildName(bool isDark) {
    final textColor = isDark
        ? const Color(0x7AE8E8EE) // rgba(232,232,238,0.48)
        : const Color(0x7A1A1A1F); // rgba(26,26,31,0.48)

    final pillColor = isDark
        ? const Color(0x26FFFFFF) // ~15% white
        : const Color(0x14000000); // ~8% black

    final baseStyle = GoogleFonts.ibmPlexMono(
      fontSize: 11.5,
      fontWeight: FontWeight.w500,
      color: textColor,
    );

    final query = highlightQuery ?? '';
    Widget nameWidget;
    if (query.isEmpty) {
      nameWidget = Text(
        branch.name,
        style: baseStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else {
      // Highlight matching segments in accent color.
      final highlightColor = isDark
          ? const Color(0xFFE0A030)
          : const Color(0xFFB07810);

      nameWidget = RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: buildHighlightedText(
          text: branch.name,
          query: query,
          baseStyle: baseStyle,
          highlightColor: highlightColor,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: pillColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: nameWidget,
    );
  }

  /// 5x5 amber circle with a subtle glow, indicating uncommitted changes.
  Widget _buildDirtyDot() {
    return Container(
      width: 5,
      height: 5,
      decoration: BoxDecoration(
        color: const Color(0xFFE0A030),
        shape: BoxShape.circle,
        boxShadow: const [
          BoxShadow(
            color: Color(0x66E0A030), // rgba(224,160,48,0.4)
            blurRadius: 4,
          ),
        ],
      ),
    );
  }

  /// 18x18 add button for creating a new workspace on this branch.
  Widget _buildAddButton(bool isDark) {
    final textColor = isDark
        ? const Color(0x4DE8E8EE) // rgba(232,232,238,0.30)
        : const Color(0x4D1A1A1F); // rgba(26,26,31,0.30)

    return GestureDetector(
      onTap: onAddWorkspace,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: 0.5,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            '+',
            style: GoogleFonts.ibmPlexSans(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Pill-shaped notification badge with amber background and white text.
///
/// Reused for aggregate notification counts when branch sections are
/// collapsed, bubbling up unread counts from hidden child workspaces.
class _NotificationBadge extends StatelessWidget {
  final int count;

  const _NotificationBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';

    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFE0A030),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: GoogleFonts.ibmPlexSans(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}
