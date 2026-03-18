/// Breadcrumb navigation bar for the file explorer.
///
/// Shows the current path as clickable segments separated by ">" chevrons.
/// Last segment is bold (current directory). Right side shows the files icon.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/colors.dart';

class BreadcrumbBar extends StatelessWidget {
  /// Path segments to display (e.g. ['~', 'cmux', 'Sources']).
  final List<String> segments;

  const BreadcrumbBar({
    super.key,
    required this.segments,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.bgPrimary,
        border: Border(
          bottom: BorderSide(color: c.border),
        ),
      ),
      child: Row(
        children: [
          // Breadcrumb path segments
          Expanded(
            child: _buildBreadcrumbs(c),
          ),

          // Files pane icon on the right
          Icon(
            Icons.folder_outlined,
            size: 16,
            color: c.filesColor,
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbs(AppColorScheme c) {
    final children = <Widget>[];

    for (var i = 0; i < segments.length; i++) {
      final isLast = i == segments.length - 1;

      // Separator before all segments except the first
      if (i > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '\u203A', // single right-pointing angle quotation mark
              style: GoogleFonts.ibmPlexMono(
                fontSize: 10,
                color: c.textPrimary.withAlpha(102), // 40% opacity
              ),
            ),
          ),
        );
      }

      // Segment text
      children.add(
        Text(
          segments[i],
          style: GoogleFonts.ibmPlexMono(
            fontSize: 12,
            fontWeight: isLast ? FontWeight.w700 : FontWeight.w500,
            color: isLast ? c.textPrimary : c.textSecondary,
          ),
        ),
      );
    }

    return Row(
      children: children,
    );
  }
}
