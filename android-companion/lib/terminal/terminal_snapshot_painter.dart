/// Static snapshot painter for adjacent terminal pre-rendering during swipe.
///
/// Renders a frozen snapshot of terminal cell state without any interactive
/// elements (no cursor, no selection, no blink timer). Used to display the
/// neighboring tab during a swipe-to-switch gesture so the user sees real
/// terminal content rather than a blank placeholder.
///
/// Cell rendering logic mirrors [TerminalPainter] exactly — same theme-aware
/// color resolution, same wrapping calculation, same glyph rendering — but
/// omits all cursor and selection drawing paths.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../native/ghostty_vt.dart';

/// Renders a static snapshot of terminal cells onto a [Canvas].
///
/// Inputs:
///   - [cells]      : flat list of [CellData] in row-major order
///   - [cols]       : number of columns in the Mac terminal grid
///   - [rows]       : number of rows in the Mac terminal grid
///   - [cellWidth]  : width of each rendered cell in logical pixels
///   - [cellHeight] : height of each rendered cell in logical pixels
///   - [fontSize]   : font size for glyph rendering (must match cell sizing)
///   - [paddingH]   : horizontal inset in logical pixels
///   - [paddingV]   : vertical inset in logical pixels
///
/// Outputs: fills the canvas with the terminal background color and draws
/// all cell backgrounds and text glyphs, text decorations included.
///
/// Assumptions:
///   - The canvas size is at least wide enough for one display column
///     (paddingH * 2 + cellWidth).
///   - [cells] length equals [cols] * [rows]; shorter lists are safe (renders
///     only available cells).
///   - fitCols is derived from the paint size at render time, matching the
///     same wrapping behaviour as [TerminalPainter].
class TerminalSnapshotPainter extends CustomPainter {
  final List<CellData> cells;
  final int cols;
  final int rows;
  final double cellWidth;
  final double cellHeight;
  final double fontSize;
  final double paddingH;
  final double paddingV;

  // Theme-aware default colors — same as TerminalPainter.
  final Color _bg;
  final Color _fg;

  const TerminalSnapshotPainter({
    required this.cells,
    required this.cols,
    required this.rows,
    required this.cellWidth,
    required this.cellHeight,
    required this.fontSize,
    required this.paddingH,
    required this.paddingV,
    required Color defaultBg,
    required Color defaultFg,
  })  : _bg = defaultBg,
        _fg = defaultFg;

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Fill entire canvas with the terminal background color.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = _bg,
    );

    if (cells.isEmpty || cols == 0 || rows == 0) return;

    // Derive fitCols from the available paint width, matching TerminalPainter's
    // wrapping behaviour (same formula used in TerminalView layout).
    final fitCols = ((size.width - 2 * paddingH) / cellWidth).floor();
    if (fitCols <= 0) return;

    // Number of display lines each Mac row wraps into.
    final wrapLines = (cols / fitCols).ceil();

    final bgPaint = Paint();

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        final index = row * cols + col;
        if (index >= cells.length) break;

        final cell = cells[index];

        // Skip spacer tails (right half of wide chars).
        if (cell.isSpacerTail) continue;

        // Map Mac grid position to wrapped display position.
        final displayRow = row * wrapLines + (col ~/ fitCols);
        final displayCol = col % fitCols;
        final x = paddingH + displayCol * cellWidth;
        final y = paddingV + displayRow * cellHeight;
        final charWidth = cell.isWide ? cellWidth * 2 : cellWidth;

        // Resolve colors, handling inverse attribute.
        Color fg;
        Color bg;

        if (cell.fgIsDefault) {
          fg = _fg;
        } else {
          fg = Color.fromARGB(255, cell.fgR, cell.fgG, cell.fgB);
        }

        if (cell.bgIsDefault) {
          bg = _bg;
        } else {
          bg = Color.fromARGB(255, cell.bgR, cell.bgG, cell.bgB);
        }

        if (cell.isInverse) {
          final tmp = fg;
          fg = bg;
          bg = tmp;
        }

        if (cell.isFaint) {
          fg = fg.withAlpha(128);
        }

        // Draw background (skip if default to avoid overdraw).
        if (!cell.bgIsDefault || cell.isInverse) {
          bgPaint.color = bg;
          canvas.drawRect(Rect.fromLTWH(x, y, charWidth, cellHeight), bgPaint);
        }

        // Draw character glyph.
        if (cell.codepoint != 0 && !cell.isInvisible) {
          final textStyle = ui.TextStyle(
            color: fg,
            fontSize: fontSize,
            fontFamily: 'JetBrains Mono',
            fontWeight: cell.isBold ? FontWeight.bold : FontWeight.normal,
            fontStyle: cell.isItalic ? FontStyle.italic : FontStyle.normal,
            decoration: _textDecoration(cell),
          );

          final paragraphBuilder = ui.ParagraphBuilder(
            ui.ParagraphStyle(textAlign: TextAlign.left),
          )
            ..pushStyle(textStyle)
            ..addText(cell.character);

          final paragraph = paragraphBuilder.build()
            ..layout(ui.ParagraphConstraints(width: charWidth));

          final textY = y + (cellHeight - paragraph.height) / 2;
          canvas.drawParagraph(paragraph, Offset(x, textY));
        }

        // Draw underline.
        if (cell.isUnderline) {
          final ulColor = cell.ulIsDefault
              ? fg
              : Color.fromARGB(255, cell.ulR, cell.ulG, cell.ulB);
          final ulPaint = Paint()
            ..color = ulColor
            ..strokeWidth = 1.0;
          final ulY = y + cellHeight - 2;
          canvas.drawLine(Offset(x, ulY), Offset(x + charWidth, ulY), ulPaint);
        }

        // Draw strikethrough.
        if (cell.isStrikethrough) {
          final stPaint = Paint()
            ..color = fg
            ..strokeWidth = 1.0;
          final stY = y + cellHeight / 2;
          canvas.drawLine(Offset(x, stY), Offset(x + charWidth, stY), stPaint);
        }

        // Draw overline.
        if (cell.isOverline) {
          final olPaint = Paint()
            ..color = fg
            ..strokeWidth = 1.0;
          canvas.drawLine(Offset(x, y + 1), Offset(x + charWidth, y + 1), olPaint);
        }
      }
    }

    // No cursor, selection, or blink rendering — this is a static snapshot.
  }

  TextDecoration? _textDecoration(CellData cell) {
    final decorations = <TextDecoration>[];
    if (cell.isStrikethrough) decorations.add(TextDecoration.lineThrough);
    if (cell.isOverline) decorations.add(TextDecoration.overline);
    if (decorations.isEmpty) return null;
    return TextDecoration.combine(decorations);
  }

  @override
  bool shouldRepaint(covariant TerminalSnapshotPainter oldDelegate) {
    return !identical(cells, oldDelegate.cells) ||
        cols != oldDelegate.cols ||
        rows != oldDelegate.rows ||
        cellWidth != oldDelegate.cellWidth ||
        cellHeight != oldDelegate.cellHeight;
  }
}
