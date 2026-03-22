/// Shared text-highlighting helper for search match visualization.
///
/// Splits a text string into segments that match/don't-match the search
/// query and renders matched segments in the accent highlight color.
/// Used by [ProjectRow], [BranchRow], and [WorkspaceTile] when the
/// drawer search is active.
library;

import 'package:flutter/painting.dart';

/// Builds a [TextSpan] that highlights all occurrences of [query] within
/// [text] using [highlightColor] and bold weight.
///
/// Matching is case-insensitive substring search. Non-matched segments use
/// [baseStyle]; matched segments use [highlightColor] with weight 600.
/// Returns a plain [TextSpan] when [query] is empty.
TextSpan buildHighlightedText({
  required String text,
  required String query,
  required TextStyle baseStyle,
  required Color highlightColor,
}) {
  if (query.isEmpty) return TextSpan(text: text, style: baseStyle);

  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  final spans = <TextSpan>[];
  var start = 0;

  while (true) {
    final index = lowerText.indexOf(lowerQuery, start);
    if (index == -1) {
      // Remaining non-matching tail.
      spans.add(TextSpan(text: text.substring(start), style: baseStyle));
      break;
    }
    // Non-matching segment before this match.
    if (index > start) {
      spans.add(TextSpan(text: text.substring(start, index), style: baseStyle));
    }
    // Matching segment — highlighted.
    spans.add(TextSpan(
      text: text.substring(index, index + query.length),
      style: baseStyle.copyWith(
        color: highlightColor,
        fontWeight: FontWeight.w600,
      ),
    ));
    start = index + query.length;
  }

  return TextSpan(children: spans);
}
