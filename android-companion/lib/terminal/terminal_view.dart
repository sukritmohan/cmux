/// Pure terminal renderer widget using cell streaming from the Mac.
///
/// Rendering pipeline:
///   1. Mac reads Ghostty surface cells at 60fps
///   2. Binary cell frames arrive via WebSocket (types 0x01/0x02/0x03)
///   3. PtyDemuxer routes to channel stream
///   4. CellFrameParser updates cell grid
///   5. CustomPainter renders cells at native mobile font size
///
/// Cell sizing pipeline (keyboard-stable):
///   cellWidth  = viewportWidth / cols         (width-only derivation)
///   cellHeight = cellWidth * _cellAspectRatio  (stable regardless of keyboard)
///   fontSize   = cellHeight * 0.72             (tuned for JetBrains Mono x-height)
///
/// When the on-screen keyboard appears (adjustResize), the viewport shrinks
/// vertically but width stays constant — so cell dimensions never change.
/// A clip + translate keeps the cursor row visible by scrolling the terminal.
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

/// Height-to-width ratio for terminal cells. 1.75:1 yields ~15-18 visible
/// rows in portrait vs ~12-14 with the previous 2.0 ratio.
const _cellAspectRatio = 1.75;

/// Error red used in loading/error states (not theme-dependent).
const _errorRed = Color(0xFFF85149);

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

  // Keyboard input — onKeyEvent handles hardware/Bluetooth keyboards while
  // the hidden TextField + _onTextChanged handles soft keyboard IME.
  late final _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
  final _textController = TextEditingController();
  String _lastText = '';

  // On-screen debug log (temporary — remove after debugging)
  final List<String> _debugLog = [];
  void _dlog(String msg) {
    debugPrint('[TerminalView] $msg');
    setState(() {
      _debugLog.add(msg);
      if (_debugLog.length > 8) _debugLog.removeAt(0);
    });
  }

  // Cursor state for painting
  int _cursorCol = 0;
  int _cursorRow = 0;
  bool _cursorVisible = true;

  // Cursor blink: 530ms on/530ms off
  Timer? _blinkTimer;
  bool _cursorBlinkOn = true;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
    _subscribeToSurface();
    _startBlinkTimer();
  }

  @override
  void dispose() {
    _unsubscribe();
    _textController.dispose();
    _focusNode.dispose();
    _blinkTimer?.cancel();
    super.dispose();
  }

  void _startBlinkTimer() {
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (mounted) {
        setState(() => _cursorBlinkOn = !_cursorBlinkOn);
      }
    });
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

    // Reset blink phase on new frame (cursor moved or content changed).
    _cursorBlinkOn = true;

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

  /// Whether we're programmatically resetting the buffer (ignore listener).
  bool _resettingBuffer = false;

  /// Handles soft keyboard IME input by diffing the hidden TextField's text.
  void _onTextChanged() {
    if (_resettingBuffer) return;

    final newText = _textController.text;
    _dlog('textChanged: last=${_lastText.length}ch new=${newText.length}ch');

    if (newText.length > _lastText.length) {
      // Characters were added — extract and send the new portion.
      final added = newText.substring(_lastText.length);
      _dlog('IME added: "${added.replaceAll('\n', '\\n')}"');
      // Convert newlines to carriage returns for terminal.
      _sendInput(added.replaceAll('\n', '\r'));
    } else if (newText.length < _lastText.length) {
      // Characters were deleted — send backspace for each deleted char.
      final deletedCount = _lastText.length - newText.length;
      _dlog('IME deleted $deletedCount chars');
      for (int i = 0; i < deletedCount; i++) {
        _sendInput('\x7f');
      }
    }

    _lastText = newText;

    // Reset buffer if it gets too long to prevent memory bloat.
    if (_textController.text.length > 100) {
      _resettingBuffer = true;
      _textController.text = '';
      _lastText = '';
      _resettingBuffer = false;
    }
  }

  /// Handles key events from the hardware/software keyboard.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    _dlog('keyEvent: ${event.runtimeType} key=${event.logicalKey.keyLabel} char=${event.character}');
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
    final c = AppColors.of(context);

    if (_subscribing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: c.accent),
            const SizedBox(height: 16),
            Text(
              'Connecting to terminal...',
              style: TextStyle(color: c.textSecondary),
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
              const Icon(Icons.error_outline, size: 48, color: _errorRed),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: const TextStyle(color: _errorRed),
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
        _dlog('onTap: hasFocus=${_focusNode.hasFocus}');
        _focusNode.requestFocus();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (_cols == 0 || _rows == 0) {
            return Center(
              child: CircularProgressIndicator(color: c.accent),
            );
          }

          // Derive cell dimensions from width only — stable regardless
          // of keyboard visibility (adjustResize shrinks height, not width).
          final cellWidth = constraints.maxWidth / _cols;
          final cellHeight = cellWidth * _cellAspectRatio;
          final terminalHeight = cellHeight * _rows;

          // Auto-scroll to keep cursor row visible.
          final visibleRows = (constraints.maxHeight / cellHeight).floor();
          final maxScrollRow = (_rows - visibleRows).clamp(0, _rows);
          final scrollRow = (_cursorRow - visibleRows + 1).clamp(0, maxScrollRow);
          final scrollOffsetY = scrollRow * cellHeight;

          return ClipRect(
            child: Stack(
              children: [
                // Hidden text input to capture soft keyboard IME events.
                Positioned.fill(
                  child: Opacity(
                    opacity: 0,
                    child: TextField(
                      controller: _textController,
                      focusNode: _focusNode,
                      autofocus: true,
                      maxLines: null,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.none,
                      enableSuggestions: false,
                      autocorrect: false,
                      showCursor: false,
                      decoration: const InputDecoration.collapsed(hintText: ''),
                    ),
                  ),
                ),

                // Terminal content, translated to scroll cursor into view
                Transform.translate(
                  offset: Offset(0, -scrollOffsetY),
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, terminalHeight),
                    painter: TerminalPainter(
                      cells: _cells,
                      cols: _cols,
                      rows: _rows,
                      cellWidth: cellWidth,
                      cellHeight: cellHeight,
                      cursorCol: _cursorCol,
                      cursorRow: _cursorRow,
                      cursorVisible: _cursorVisible && _cursorBlinkOn,
                    ),
                  ),
                ),

                // Inner shadow: 3px gradient at terminal top edge — feels recessed
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 3,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withAlpha(38), // ~15%
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Subtle vignette: radial gradient for depth
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment.center,
                          radius: 1.2,
                          colors: [
                            Colors.transparent,
                            const Color(0xFF080B10).withAlpha(40),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // DEBUG OVERLAY — remove after debugging
                if (_debugLog.isNotEmpty)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Container(
                        color: Colors.black.withAlpha(200),
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          _debugLog.join('\n'),
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// CustomPainter that renders the terminal cell grid.
///
/// Uses dark theme colors always since terminal content is Mac-rendered
/// and should maintain dark terminal aesthetics regardless of app theme.
class TerminalPainter extends CustomPainter {
  final List<CellData> cells;
  final int cols;
  final int rows;
  final double cellWidth;
  final double cellHeight;
  final int cursorCol;
  final int cursorRow;
  final bool cursorVisible;

  // Terminal always uses dark palette for cell rendering.
  static const _bg = Color(0xFF0A0A0F);
  static const _fg = Color(0xFFE8E8EE);
  static const _cursorColor = Color(0xCCE0A030); // amber cursor at ~80%

  TerminalPainter({
    required this.cells,
    required this.cols,
    required this.rows,
    required this.cellWidth,
    required this.cellHeight,
    required this.cursorCol,
    required this.cursorRow,
    required this.cursorVisible,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (cells.isEmpty || cols == 0 || rows == 0) return;

    final fontSize = cellHeight * 0.72;

    // 1. Fill entire canvas with terminal background to prevent gaps.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = _bg,
    );

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

        // Determine if this cell is under the cursor (for character inversion).
        final isCursorCell = cursorVisible && col == cursorCol && row == cursorRow;

        // Draw character glyph.
        if (cell.codepoint != 0 && !cell.isInvisible) {
          // Under cursor: draw character in background color for inversion effect.
          final charColor = isCursorCell ? _bg : fg;

          final textStyle = ui.TextStyle(
            color: charColor,
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

    // Draw cursor: filled block with slight transparency and rounded corners.
    if (cursorVisible && cursorCol < cols && cursorRow < rows) {
      final cx = cursorCol * cellWidth;
      final cy = cursorRow * cellHeight;
      final cursorPaint = Paint()
        ..color = _cursorColor
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx, cy, cellWidth, cellHeight),
          const Radius.circular(2),
        ),
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
        cursorVisible != oldDelegate.cursorVisible ||
        cellWidth != oldDelegate.cellWidth ||
        cellHeight != oldDelegate.cellHeight;
  }
}
