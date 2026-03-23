/// A single workspace row in the project hierarchy drawer.
///
/// Shows a dot indicator, workspace name, and optional notification badge.
/// Active workspace is highlighted with a 3px amber left border, glowing
/// dot, and full-opacity text at weight 600. Used inside the three-level
/// project > branch > workspace tree, not as a standalone item.
///
/// When [highlightQuery] is non-empty, matching substrings in the workspace
/// title are rendered in accent color for search result visualization.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/colors.dart';
import '../state/workspace_provider.dart';
import 'highlight_helper.dart';

class WorkspaceTile extends StatelessWidget {
  final Workspace workspace;
  final bool isActive;
  final VoidCallback onTap;

  /// Called when the user long-presses the workspace tile.
  final VoidCallback? onLongPress;

  /// Search query for substring highlighting. When non-null and non-empty,
  /// matching segments in the workspace title are rendered in accent color.
  final String? highlightQuery;

  const WorkspaceTile({
    super.key,
    required this.workspace,
    required this.isActive,
    required this.onTap,
    this.onLongPress,
    this.highlightQuery,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        // Active state: compensate left padding for the 3px border.
        // 42px total indent: active = 39px padding + 3px border.
        padding: EdgeInsets.fromLTRB(
          isActive ? 39 : 42,
          8,
          8,
          8,
        ),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0x0FE0A030) // rgba(224,160,48,0.06)
              : Colors.transparent,
          borderRadius: isActive
              ? const BorderRadius.only(
                  topRight: Radius.circular(5),
                  bottomRight: Radius.circular(5),
                )
              : BorderRadius.circular(5),
          border: isActive
              ? const Border(
                  left: BorderSide(
                    color: Color(0xFFE0A030),
                    width: 3,
                  ),
                )
              : null,
        ),
        child: Row(
          children: [
            // Dot indicator — glows amber when active.
            _DotIndicator(isActive: isActive, isDark: isDark),

            const SizedBox(width: 8),

            // Workspace name — optionally highlighted.
            Expanded(child: _buildName(c, isDark)),

            // Notification badge — pill shape, amber background, white text.
            if (workspace.notificationCount > 0)
              _NotificationBadge(count: workspace.notificationCount),
          ],
        ),
      ),
    );
  }

  /// Workspace name label in IBM Plex Sans.
  ///
  /// When [highlightQuery] is active, matching substrings are rendered
  /// in accent color.
  Widget _buildName(AppColorScheme c, bool isDark) {
    final textColor = isActive
        ? c.textPrimary
        : (isDark
            ? const Color(0x80E8E8EE) // rgba(232,232,238,0.50)
            : const Color(0x801A1A1F)); // rgba(26,26,31,0.50)

    final baseStyle = GoogleFonts.ibmPlexSans(
      fontSize: 13,
      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
      color: textColor,
    );

    final query = highlightQuery ?? '';
    if (query.isEmpty) {
      return Text(
        workspace.title,
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
        text: workspace.title,
        query: query,
        baseStyle: baseStyle,
        highlightColor: highlightColor,
      ),
    );
  }
}

/// 4x4 circle dot indicator before the workspace name.
///
/// Active state: amber with a 6px glow shadow.
/// Inactive state: subtle 15% (dark) or 12% (light) opacity.
class _DotIndicator extends StatelessWidget {
  final bool isActive;
  final bool isDark;

  const _DotIndicator({required this.isActive, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final Color dotColor;
    final List<BoxShadow>? shadows;

    if (isActive) {
      dotColor = isDark
          ? const Color(0xFFE0A030)
          : const Color(0xFFB07810);
      shadows = [
        BoxShadow(
          color: const Color(0x80E0A030), // rgba(224,160,48,0.5)
          blurRadius: 6,
        ),
      ];
    } else {
      dotColor = isDark
          ? const Color(0x26E8E8EE) // rgba(232,232,238,0.15)
          : const Color(0x1F1A1A1F); // rgba(26,26,31,0.12)
      shadows = null;
    }

    return Container(
      width: 4,
      height: 4,
      decoration: BoxDecoration(
        color: dotColor,
        shape: BoxShape.circle,
        boxShadow: shadows,
      ),
    );
  }
}

/// Pill-shaped notification badge with amber background and white text.
///
/// Min-width 18px, height 18px, border-radius 9px for pill shape.
/// Displays count capped at "99+" to prevent overflow.
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
