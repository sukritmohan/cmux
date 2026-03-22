/// A linked terminal entry row in the project hierarchy drawer.
///
/// Renders an italic sub-row under a branch showing a link icon and
/// "shared from {owningProjectName} / {owningWorkspaceName}" text.
/// Tapping navigates to the owning workspace. Styled at 22% opacity
/// to visually subordinate linked terminals below workspace rows.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/project_hierarchy_provider.dart';

class LinkedTerminalRow extends StatelessWidget {
  final LinkedTerminalEntry entry;
  final VoidCallback onTap;

  const LinkedTerminalRow({
    super.key,
    required this.entry,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Text color: 22% opacity of the theme's text base.
    final textColor = isDark
        ? const Color(0x38E8E8EE) // rgba(232,232,238,0.22)
        : const Color(0x381A1A1F); // rgba(26,26,31,0.22)

    // Link icon color: 20% opacity of the theme's text base, then 70%.
    // 20% * 0.7 = 14% effective opacity.
    final iconColor = isDark
        ? const Color(0x33E8E8EE) // rgba(232,232,238,0.20)
        : const Color(0x331A1A1F); // rgba(26,26,31,0.20)

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 28),
        padding: const EdgeInsets.fromLTRB(42, 4, 8, 4),
        child: Row(
          children: [
            // Link icon at 70% opacity of the 20% base color.
            Opacity(
              opacity: 0.7,
              child: Icon(Icons.link, size: 10, color: iconColor),
            ),

            const SizedBox(width: 6),

            // "shared from {project} / {workspace}" — italic, ellipsis truncation.
            Expanded(
              child: Text(
                'shared from ${entry.owningProjectName} / ${entry.owningWorkspaceName}',
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w400,
                  color: textColor,
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
