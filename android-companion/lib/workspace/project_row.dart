/// Project header row in the workspace drawer hierarchy.
///
/// Shows a monogram icon (uppercase first letter in a rounded square),
/// the project name in JetBrains Mono, and an animated disclosure chevron.
/// A 1px separator appears above non-first projects for visual grouping.
///
/// The "Other" section variant uses lighter weight and reduced opacity
/// to visually de-emphasize the synthetic catch-all group.
///
/// When [highlightQuery] is non-empty, matching substrings in the project
/// name are rendered in accent color for search result visualization.
///
/// When [aggregateNotificationCount] > 0 and the project is collapsed,
/// a notification badge is shown to bubble up unread counts from child
/// workspaces that are hidden beneath the fold.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/colors.dart';
import '../state/project_hierarchy_provider.dart';
import 'highlight_helper.dart';

/// A project header in the drawer's three-level hierarchy tree.
///
/// Tapping the row toggles expand/collapse of the project's branches.
/// The chevron rotates smoothly between expanded (0 deg) and collapsed
/// (-90 deg) states using [AnimatedRotation].
class ProjectRow extends StatelessWidget {
  /// The project model to render.
  final SidebarProject project;

  /// Whether the project section is currently expanded in the drawer.
  final bool isExpanded;

  /// True for the first project in the list — suppresses the top separator.
  final bool isFirst;

  /// Called when the user taps to toggle expand/collapse.
  final VoidCallback onTap;

  /// Search query for substring highlighting. When non-null and non-empty,
  /// matching segments in the project name are rendered in accent color.
  final String? highlightQuery;

  /// Sum of unread notification counts across all descendant workspaces.
  /// Shown as a badge when the project is collapsed and count > 0.
  final int aggregateNotificationCount;

  const ProjectRow({
    super.key,
    required this.project,
    required this.isExpanded,
    required this.isFirst,
    required this.onTap,
    this.highlightQuery,
    this.aggregateNotificationCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isOther = project.isOtherSection;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1px separator above non-first projects.
        if (!isFirst) _buildSeparator(isDark),

        // Tappable project row.
        GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: 38),
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
            ),
            child: Row(
              children: [
                _buildChevron(isDark),
                const SizedBox(width: 4),
                _buildMonogram(c, isDark, isOther),
                const SizedBox(width: 8),
                Expanded(child: _buildName(c, isDark, isOther)),

                // Aggregate notification badge when collapsed.
                if (!isExpanded && aggregateNotificationCount > 0) ...[
                  const SizedBox(width: 6),
                  _NotificationBadge(count: aggregateNotificationCount),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Animated disclosure chevron that rotates between 0 (expanded) and
  /// -0.25 turns (-90 deg, collapsed).
  Widget _buildChevron(bool isDark) {
    final chevronColor = isDark
        ? const Color(0x40E8E8EE) // rgba(232,232,238,0.25)
        : const Color(0x401A1A1F); // rgba(26,26,31,0.25)

    return SizedBox(
      width: 16,
      height: 16,
      child: AnimatedRotation(
        turns: isExpanded ? 0.0 : -0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: Icon(
          Icons.expand_more,
          size: 14,
          color: chevronColor,
        ),
      ),
    );
  }

  /// 22x22 rounded square monogram showing the project's first letter.
  Widget _buildMonogram(AppColorScheme c, bool isDark, bool isOther) {
    // "Other" uses 3% bg opacity; normal projects use 6%.
    final bgColor = isDark
        ? Color.fromRGBO(232, 232, 238, isOther ? 0.03 : 0.06)
        : Color.fromRGBO(26, 26, 31, isOther ? 0.03 : 0.06);

    final textColor = isDark
        ? const Color(0x80E8E8EE) // rgba(232,232,238,0.50)
        : const Color(0x731A1A1F); // rgba(26,26,31,0.45)

    final letter =
        project.name.isNotEmpty ? project.name[0].toUpperCase() : '?';

    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(5),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
    );
  }

  /// Project name label in JetBrains Mono.
  ///
  /// When [highlightQuery] is active, matching substrings are rendered
  /// in accent color. The "Other" section uses weight 500 and 35% opacity
  /// text instead of the standard weight 600 and full-opacity textPrimary.
  Widget _buildName(AppColorScheme c, bool isDark, bool isOther) {
    final textColor = isOther
        ? (isDark
            ? const Color(0x59E8E8EE) // rgba(232,232,238,0.35)
            : const Color(0x591A1A1F)) // rgba(26,26,31,0.35)
        : c.textPrimary;

    final baseStyle = TextStyle(
      fontFamily: 'JetBrains Mono',
      fontSize: 13,
      fontWeight: isOther ? FontWeight.w500 : FontWeight.w600,
      letterSpacing: -0.2,
      color: textColor,
    );

    final query = highlightQuery ?? '';
    if (query.isEmpty) {
      return Text(
        project.name,
        style: baseStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    // Highlight matching segments in accent color.
    final highlightColor = isDark
        ? const Color(0xFFE0A030)
        : const Color(0xFFB07810);

    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: buildHighlightedText(
        text: project.name,
        query: query,
        baseStyle: baseStyle,
        highlightColor: highlightColor,
      ),
    );
  }

  /// 1px horizontal rule above non-first projects.
  Widget _buildSeparator(bool isDark) {
    final color = isDark
        ? const Color(0x0DFFFFFF) // rgba(255,255,255,0.05)
        : const Color(0x0A000000); // rgba(0,0,0,0.04)

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
      child: Container(height: 1, color: color),
    );
  }
}

/// Pill-shaped notification badge with amber background and white text.
///
/// Reused across project and branch rows for aggregate notification
/// counts when sections are collapsed.
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
