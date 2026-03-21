/// VS Code-style minimap painter that renders terminal cells as colored blocks.
///
/// At minimap scale (~100-200dp per pane), individual characters are
/// illegible. Instead, each non-empty cell is drawn as a small filled
/// rectangle using the cell's foreground color. This creates a
/// recognizable "shape" of terminal content — prompts, colored output
/// (git status, ls), and whitespace are visually distinguishable.
///
/// Performance: groups cells by color to batch `drawRect` calls.
/// At ~3fps repaint rate (from [MinimapCellConsumer]), the cost is
/// negligible compared to the main terminal's 60fps text rendering.
library;

import 'dart:ui' show Canvas, Color, Offset, Paint, PaintingStyle, Rect, Size;

import 'package:flutter/rendering.dart' show CustomPainter;

import '../native/ghostty_vt.dart';

class MinimapTerminalPainter extends CustomPainter {
  final List<CellData> cells;
  final int cols;
  final int rows;
  final Color _bg;
  final Color _fg;

  MinimapTerminalPainter({
    required this.cells,
    required this.cols,
    required this.rows,
    required Color defaultBg,
    required Color defaultFg,
  })  : _bg = defaultBg,
        _fg = defaultFg;

  @override
  void paint(Canvas canvas, Size size) {
    if (cells.isEmpty || cols == 0 || rows == 0) return;

    // Fill background.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = _bg,
    );

    // Cell dimensions at minimap scale.
    final cellW = size.width / cols;
    final cellH = size.height / rows;

    // Batch rects by color to reduce draw calls.
    final batches = <int, List<Rect>>{};

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        final idx = row * cols + col;
        if (idx >= cells.length) break;

        final cell = cells[idx];

        // Skip empty cells and spacer tails.
        if (cell.codepoint == 0 || cell.codepoint == 0x20 || cell.isSpacerTail) {
          continue;
        }

        // Resolve foreground color.
        Color fg;
        if (cell.fgIsDefault) {
          fg = _fg;
        } else {
          fg = Color.fromARGB(255, cell.fgR, cell.fgG, cell.fgB);
        }

        // Handle inverse attribute.
        if (cell.isInverse) {
          Color bg;
          if (cell.bgIsDefault) {
            bg = _bg;
          } else {
            bg = Color.fromARGB(255, cell.bgR, cell.bgG, cell.bgB);
          }
          fg = bg;
          // Skip if inverse makes it invisible against background.
          if (fg == _bg) continue;
        }

        if (cell.isFaint) {
          fg = fg.withAlpha(128);
        }

        final rect = Rect.fromLTWH(
          col * cellW,
          row * cellH,
          cellW,
          cellH * 0.8, // Slight vertical gap for line separation.
        );

        final colorKey = fg.toARGB32();
        (batches[colorKey] ??= []).add(rect);
      }
    }

    // Draw batched rects per color.
    final paint = Paint()..style = PaintingStyle.fill;
    for (final entry in batches.entries) {
      paint.color = Color(entry.key);
      for (final rect in entry.value) {
        canvas.drawRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant MinimapTerminalPainter old) {
    return !identical(cells, old.cells) ||
        cols != old.cols ||
        rows != old.rows;
  }
}
