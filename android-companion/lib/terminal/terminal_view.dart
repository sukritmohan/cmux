/// Pure terminal renderer widget using cell streaming from the Mac.
///
/// Rendering pipeline:
///   1. Mac reads Ghostty surface cells at 60fps
///   2. Binary cell frames arrive via WebSocket (types 0x01/0x02/0x03)
///   3. PtyDemuxer routes to channel stream
///   4. CellFrameParser updates cell grid
///   5. CustomPainter renders cells at native mobile font size
///
/// No VT parser needed on Android — the Mac does all terminal parsing.
/// This widget is a pure renderer with no navigation chrome (no Scaffold,
/// no AppBar, no Drawer). The parent [TerminalScreen] provides those.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/colors.dart';
import '../app/providers.dart';
import '../native/ghostty_vt.dart';
import 'cell_frame_parser.dart';

class TerminalView extends ConsumerStatefulWidget {
  final String surfaceId;
  final String? workspaceId;

  const TerminalView({super.key, required this.surfaceId, this.workspaceId});

  @override
  ConsumerState<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends ConsumerState<TerminalView> {
  final _cellParser = CellFrameParser();
  StreamSubscription? _cellSub;
  int? _channelId;
  List<CellData> _cells = [];
  int _cols = 0;
  int _rows = 0;
  bool _subscribing = true;
  String? _error;

  // Keyboard input
  final _focusNode = FocusNode();

  // Cursor state for painting
  int _cursorCol = 0;
  int _cursorRow = 0;
  bool _cursorVisible = true;

  @override
  void initState() {
    super.initState();
    _subscribeToSurface();
  }

  @override
  void dispose() {
    _unsubscribe();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _subscribeToSurface() async {
    final manager = ref.read(connectionManagerProvider);

    try {
      // Select the workspace first to ensure its Ghostty surface is created.
      // Background tabs may have uninitialized native surfaces.
      if (widget.workspaceId != null) {
        debugPrint('[TerminalView] Selecting workspace: ${widget.workspaceId}');
        await manager.sendRequest(
          'workspace.select',
          params: {'workspace_id': widget.workspaceId},
        );
        // Give the surface a moment to initialize after selection.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      // Subscribe to cell-based screen output for this surface.
      debugPrint('[TerminalView] Subscribing to cell stream: ${widget.surfaceId}');
      final response = await manager.sendRequest(
        'surface.cells.subscribe',
        params: {'surface_id': widget.surfaceId},
      );

      if (!response.ok || response.result == null) {
        final errorMsg = response.error ?? 'Unknown error';
        debugPrint('[TerminalView] Cell subscribe failed: $errorMsg');
        if (mounted) {
          setState(() {
            _subscribing = false;
            _error = 'Cell subscribe failed: $errorMsg';
          });
        }
        return;
      }

      _channelId = response.result!['channel'] as int?;
      if (_channelId == null) {
        debugPrint('[TerminalView] No channel ID in response: ${response.result}');
        if (mounted) {
          setState(() {
            _subscribing = false;
            _error = 'No channel ID returned from server';
          });
        }
        return;
      }

      debugPrint('[TerminalView] Subscribed to cell stream on channel $_channelId');

      // Start listening for cell data frames.
      _cellSub = manager.ptyDemuxer.subscribe(_channelId!).listen(_onCellFrame);

      if (mounted) {
        setState(() => _subscribing = false);
      }
    } catch (e) {
      debugPrint('[TerminalView] Subscribe error: $e');
      if (mounted) {
        setState(() {
          _subscribing = false;
          _error = 'Connection error: $e';
        });
      }
    }
  }

  void _unsubscribe() {
    _cellSub?.cancel();
    _cellSub = null;

    if (_channelId != null) {
      try {
        final manager = ref.read(connectionManagerProvider);
        manager.sendRequest(
          'surface.cells.unsubscribe',
          params: {'surface_id': widget.surfaceId},
        );
        manager.ptyDemuxer.unsubscribe(_channelId!);
      } catch (_) {
        // Best effort cleanup.
      }
    }
  }

  /// Handles binary cell frames from the Mac.
  void _onCellFrame(Uint8List data) {
    final result = _cellParser.parse(data);
    if (result == null) return;

    setState(() {
      _cells = result.cells;
      _cols = result.cols;
      _rows = result.rows;
      _cursorCol = result.cursorCol;
      _cursorRow = result.cursorRow;
      _cursorVisible = result.cursorVisible;
    });
  }

  /// Sends text input to the Mac-side PTY.
  Future<void> _sendInput(String text) async {
    if (text.isEmpty) return;
    try {
      final manager = ref.read(connectionManagerProvider);
      await manager.sendRequest(
        'surface.pty.write',
        params: {
          'surface_id': widget.surfaceId,
          'data': text,
        },
      );
    } catch (e) {
      debugPrint('[TerminalView] Write error: $e');
    }
  }

  /// Handles key events from the hardware/software keyboard.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    String? data;

    if (key == LogicalKeyboardKey.enter) {
      data = '\r';
    } else if (key == LogicalKeyboardKey.backspace) {
      data = '\x7f';
    } else if (key == LogicalKeyboardKey.tab) {
      data = '\t';
    } else if (key == LogicalKeyboardKey.escape) {
      data = '\x1b';
    } else if (key == LogicalKeyboardKey.arrowUp) {
      data = '\x1b[A';
    } else if (key == LogicalKeyboardKey.arrowDown) {
      data = '\x1b[B';
    } else if (key == LogicalKeyboardKey.arrowRight) {
      data = '\x1b[C';
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      data = '\x1b[D';
    } else if (key == LogicalKeyboardKey.delete) {
      data = '\x1b[3~';
    } else if (key == LogicalKeyboardKey.home) {
      data = '\x1b[H';
    } else if (key == LogicalKeyboardKey.end) {
      data = '\x1b[F';
    }

    if (data != null) {
      _sendInput(data);
      return KeyEventResult.handled;
    }

    final char = event.character;
    if (char != null && char.isNotEmpty) {
      _sendInput(char);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (_subscribing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.accentBlue),
            SizedBox(height: 16),
            Text(
              'Connecting to terminal...',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppColors.accentRed),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.accentRed),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _subscribing = true;
                    _error = null;
                  });
                  _subscribeToSurface();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        _focusNode.requestFocus();
        SystemChannels.textInput.invokeMethod('TextInput.show');
      },
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (_cols == 0 || _rows == 0) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.accentBlue),
              );
            }

            final cellWidth = constraints.maxWidth / _cols;
            final cellHeight = cellWidth * 2.0;
            final terminalHeight = cellHeight * _rows;

            return SizedBox(
              width: constraints.maxWidth,
              height: terminalHeight.clamp(0, constraints.maxHeight),
              child: CustomPaint(
                size: Size(constraints.maxWidth,
                    terminalHeight.clamp(0, constraints.maxHeight)),
                painter: TerminalPainter(
                  cells: _cells,
                  cols: _cols,
                  rows: _rows,
                  cursorCol: _cursorCol,
                  cursorRow: _cursorRow,
                  cursorVisible: _cursorVisible,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// CustomPainter that renders the terminal cell grid.
///
/// Each cell is drawn as a colored rectangle (background) with a
/// character glyph on top. Supports bold, italic, underline,
/// strikethrough, inverse, and dim attributes.
class TerminalPainter extends CustomPainter {
  final List<CellData> cells;
  final int cols;
  final int rows;
  final int cursorCol;
  final int cursorRow;
  final bool cursorVisible;

  TerminalPainter({
    required this.cells,
    required this.cols,
    required this.rows,
    required this.cursorCol,
    required this.cursorRow,
    required this.cursorVisible,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (cells.isEmpty || cols == 0 || rows == 0) return;

    final cellWidth = size.width / cols;
    final cellHeight = size.height / rows;
    final fontSize = cellHeight * 0.75;

    final bgPaint = Paint();

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        final index = row * cols + col;
        if (index >= cells.length) break;

        final cell = cells[index];

        // Skip spacer tails (right half of wide chars).
        if (cell.isSpacerTail) continue;

        final x = col * cellWidth;
        final y = row * cellHeight;
        final charWidth = cell.isWide ? cellWidth * 2 : cellWidth;

        // Resolve colors, handling inverse attribute.
        Color fg;
        Color bg;

        if (cell.fgIsDefault) {
          fg = AppColors.terminalFg;
        } else {
          fg = Color.fromARGB(255, cell.fgR, cell.fgG, cell.fgB);
        }

        if (cell.bgIsDefault) {
          bg = AppColors.terminalBg;
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
            fontFamily: 'monospace',
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
          final ulColor = cell.ulIsDefault ? fg : Color.fromARGB(255, cell.ulR, cell.ulG, cell.ulB);
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

    // Draw cursor.
    if (cursorVisible && cursorCol < cols && cursorRow < rows) {
      final cx = cursorCol * cellWidth;
      final cy = cursorRow * cellHeight;
      final cursorPaint = Paint()
        ..color = AppColors.terminalCursor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(
        Rect.fromLTWH(cx, cy, cellWidth, cellHeight),
        cursorPaint,
      );
    }
  }

  TextDecoration? _textDecoration(CellData cell) {
    final decorations = <TextDecoration>[];
    if (cell.isStrikethrough) decorations.add(TextDecoration.lineThrough);
    if (cell.isOverline) decorations.add(TextDecoration.overline);
    if (decorations.isEmpty) return null;
    return TextDecoration.combine(decorations);
  }

  @override
  bool shouldRepaint(covariant TerminalPainter oldDelegate) {
    return !identical(cells, oldDelegate.cells) ||
        cursorCol != oldDelegate.cursorCol ||
        cursorRow != oldDelegate.cursorRow ||
        cursorVisible != oldDelegate.cursorVisible;
  }
}
