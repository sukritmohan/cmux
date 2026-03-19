/// Pure terminal renderer widget using cell streaming from the Mac.
///
/// Rendering pipeline:
///   1. Mac reads Ghostty surface cells at 60fps
///   2. Binary cell frames arrive via WebSocket (types 0x01/0x02/0x03)
///   3. PtyDemuxer routes to channel stream
///   4. CellFrameParser updates cell grid
///   5. CustomPainter renders cells at native mobile font size
///
/// Cell sizing pipeline (font-size-first, keyboard-stable):
///   fontSize   = _targetFontSize              (11.5px — matches design spec)
///   cellWidth  = fontSize * _monoAdvanceRatio  (6.9px — JetBrains Mono advance)
///   cellHeight = fontSize * _lineHeightFactor  (17.825px — spec line-height 1.55)
///   padding    = _termPadH / _termPadV         (14px H, 12px V — spec padding)
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
import 'dart:math' show min, max;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/colors.dart';
import '../app/providers.dart';
import '../native/ghostty_vt.dart';
import 'cell_frame_parser.dart';

/// Target font size matching the design spec (font-size: 11.5px).
const _targetFontSize = 11.5;

/// Line-height factor from the design spec (line-height: 1.55).
const _lineHeightFactor = 1.55;

/// JetBrains Mono advance-width / font-size ratio.
const _monoAdvanceRatio = 0.6;

/// Horizontal padding inside the terminal area (spec: padding left/right).
const _termPadH = 14.0;

/// Vertical padding inside the terminal area (spec: padding top/bottom).
const _termPadV = 12.0;

/// Error red used in loading/error states (not theme-dependent).
const _errorRed = Color(0xFFF85149);

class TerminalView extends ConsumerStatefulWidget {
  final String surfaceId;
  final String? workspaceId;

  /// Notifier incremented by the parent when a scroll gesture fires.
  /// TerminalView listens and clears any active text selection.
  final ValueNotifier<int>? scrollNotifier;

  const TerminalView({
    super.key,
    required this.surfaceId,
    this.workspaceId,
    this.scrollNotifier,
  });

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

  // Cursor state for painting
  int _cursorCol = 0;
  int _cursorRow = 0;
  bool _cursorVisible = true;

  // Cursor blink: 530ms on/530ms off
  Timer? _blinkTimer;
  bool _cursorBlinkOn = true;

  // Text selection in Mac grid coordinates (col, row).
  int? _selStartCol, _selStartRow;
  int? _selEndCol, _selEndRow;
  bool _showCopyPill = false;

  // Handle drag state for selection refinement.
  bool _isDraggingStartHandle = false;
  bool _isDraggingEndHandle = false;
  int _lastHapticTimestamp = 0; // for 30ms throttle

  // "Copied!" feedback state.
  bool _showCopiedFeedback = false;

  // Layout values cached from the last build for hit-testing.
  int _lastFitCols = 0;
  int _lastWrapLines = 1;
  double _lastCellWidth = 0;
  double _lastCellHeight = 0;
  double _lastScrollOffsetY = 0;

  // Track last sent resize dimensions to avoid redundant resize requests.
  int _lastSentCols = 0;
  int _lastSentRows = 0;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
    _subscribeToSurface();
    _startBlinkTimer();
    widget.scrollNotifier?.addListener(_onScrollNotified);
  }

  @override
  void dispose() {
    widget.scrollNotifier?.removeListener(_onScrollNotified);
    _unsubscribe();
    _textController.dispose();
    _focusNode.dispose();
    _blinkTimer?.cancel();
    super.dispose();
  }

  void _onScrollNotified() {
    if (_hasSelection) {
      _clearSelection();
    }
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

  /// Sends a resize request to the Mac to match the phone's terminal dimensions.
  ///
  /// This implements tmux-style resize: the Mac terminal is resized to the phone's
  /// cols/rows so both views show identical content with no wrapping needed.
  Future<void> _sendResize(int cols, int rows) async {
    try {
      final manager = ref.read(connectionManagerProvider);
      await manager.sendRequest(
        'surface.pty.resize',
        params: {
          'surface_id': widget.surfaceId,
          'cols': cols,
          'rows': rows,
        },
      );
      debugPrint('[TerminalView] Sent resize: ${cols}x$rows');
    } catch (e) {
      debugPrint('[TerminalView] Resize error: $e');
    }
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
    if (newText.length > _lastText.length) {
      // Characters were added — extract and send the new portion.
      final added = newText.substring(_lastText.length);
      // Convert newlines to carriage returns for terminal.
      _sendInput(added.replaceAll('\n', '\r'));
    } else if (newText.length < _lastText.length) {
      // Characters were deleted — send backspace for each deleted char.
      final deletedCount = _lastText.length - newText.length;
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

  // ---------------------------------------------------------------------------
  // Text selection helpers
  // ---------------------------------------------------------------------------

  bool get _hasSelection =>
      _selStartCol != null &&
      _selStartRow != null &&
      _selEndCol != null &&
      _selEndRow != null;

  void _clearSelection() {
    setState(() {
      _selStartCol = _selStartRow = _selEndCol = _selEndRow = null;
      _showCopyPill = false;
    });
  }

  /// Converts a local touch position to Mac grid (col, row), accounting for
  /// padding, wrapping, and scroll offset.
  (int col, int row) _hitTestCell(Offset local) {
    final fitCols = _lastFitCols;
    final cellWidth = _lastCellWidth;
    final cellHeight = _lastCellHeight;
    final wrapLines = _lastWrapLines;
    if (fitCols == 0 || cellWidth == 0 || cellHeight == 0) return (0, 0);

    // Account for scroll offset: local.dy is in viewport space, add scroll
    // to get canvas space.
    final canvasY = local.dy + _lastScrollOffsetY;

    final displayCol =
        ((local.dx - _termPadH) / cellWidth).floor().clamp(0, fitCols - 1);
    final displayRow =
        ((canvasY - _termPadV) / cellHeight).floor().clamp(0, _rows * wrapLines - 1);

    // Inverse of wrapping: display → Mac grid.
    final macRow = displayRow ~/ wrapLines;
    final wrapOffset = displayRow % wrapLines;
    final macCol = wrapOffset * fitCols + displayCol;

    return (macCol.clamp(0, _cols - 1), macRow.clamp(0, _rows - 1));
  }

  /// Converts Mac grid (col, row) to viewport screen position (top-left of cell).
  /// Inverse of `_hitTestCell`. Used for positioning selection handles.
  Offset _gridToScreen(int col, int row) {
    final wrapLines = _lastWrapLines;
    final fitCols = _lastFitCols;
    final cellWidth = _lastCellWidth;
    final cellHeight = _lastCellHeight;
    if (fitCols == 0) return Offset.zero;

    final displayRow = row * wrapLines + (col ~/ fitCols);
    final displayCol = col % fitCols;
    return Offset(
      _termPadH + displayCol * cellWidth,
      _termPadV + displayRow * cellHeight - _lastScrollOffsetY,
    );
  }

  void _onLongPressStart(LongPressStartDetails details) {
    final (col, row) = _hitTestCell(details.localPosition);
    setState(() {
      _selStartCol = col;
      _selStartRow = row;
      _selEndCol = col;
      _selEndRow = row;

      _showCopyPill = false;
    });
    HapticFeedback.mediumImpact();
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final (col, row) = _hitTestCell(details.localPosition);
    setState(() {
      _selEndCol = col;
      _selEndRow = row;
    });
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (_hasSelection) {
      setState(() => _showCopyPill = true);
    }
  }

  // ---------------------------------------------------------------------------
  // Handle drag for selection refinement
  // ---------------------------------------------------------------------------

  /// Touch slop is handled by Flutter's PanGestureRecognizer (default 18px).
  /// The 28dp finger offset ensures the selection boundary is visible above
  /// the user's finger during drag.
  static const _handleFingerOffsetY = 28.0;

  /// Minimum interval between character-boundary haptics (ms).
  static const _hapticThrottleMs = 30;

  void _onHandleDragStart(bool isStart, DragStartDetails details) {
    setState(() {
      if (isStart) {
        _isDraggingStartHandle = true;
      } else {
        _isDraggingEndHandle = true;
      }
      _showCopyPill = false;
    });
    HapticFeedback.selectionClick();
  }

  void _onHandleDragUpdate(bool isStart, DragUpdateDetails details) {
    // Apply finger offset: map from 28dp above touch point.
    final adjusted = Offset(
      details.localPosition.dx,
      details.localPosition.dy - _handleFingerOffsetY,
    );
    final (col, row) = _hitTestCell(adjusted);

    // Determine which boundary to update.
    final prevCol = isStart ? _selStartCol : _selEndCol;
    final prevRow = isStart ? _selStartRow : _selEndRow;

    // Only update if cell changed.
    if (col == prevCol && row == prevRow) return;

    // Haptic click on each new cell boundary, throttled.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastHapticTimestamp >= _hapticThrottleMs) {
      HapticFeedback.selectionClick();
      _lastHapticTimestamp = now;
    }

    setState(() {
      if (isStart) {
        _selStartCol = col;
        _selStartRow = row;
      } else {
        _selEndCol = col;
        _selEndRow = row;
      }
    });
  }

  void _onHandleDragEnd(bool isStart, DragEndDetails details) {
    setState(() {
      _isDraggingStartHandle = false;
      _isDraggingEndHandle = false;
      _showCopyPill = _hasSelection;
    });
    HapticFeedback.mediumImpact();
  }

  /// Extracts selected text from cell data and copies to clipboard.
  void _copySelection() {
    if (!_hasSelection || _cells.isEmpty) return;

    // Normalize to reading order.
    final startIdx = _selStartRow! * _cols + _selStartCol!;
    final endIdx = _selEndRow! * _cols + _selEndCol!;
    final lo = min(startIdx, endIdx);
    final hi = max(startIdx, endIdx);

    final buf = StringBuffer();
    int lastRow = lo ~/ _cols;

    for (int i = lo; i <= hi && i < _cells.length; i++) {
      final row = i ~/ _cols;
      if (row != lastRow) {
        buf.write('\n');
        lastRow = row;
      }
      final cell = _cells[i];
      if (cell.codepoint != 0 && !cell.isSpacerTail) {
        buf.write(cell.character);
      }
    }

    Clipboard.setData(ClipboardData(text: buf.toString()));

    setState(() {
      _showCopyPill = false;
    });

    // Brief "Copied!" feedback, then clear selection.
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _clearSelection();
    });
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
        if (_hasSelection) {
          _clearSelection();
        } else {
          _focusNode.requestFocus();
        }
      },
      onLongPressStart: _onLongPressStart,
      onLongPressMoveUpdate: _onLongPressMoveUpdate,
      onLongPressEnd: _onLongPressEnd,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (_cols == 0 || _rows == 0) {
            return Center(
              child: CircularProgressIndicator(color: c.accent),
            );
          }

          // Font-size-first cell sizing: fixed dimensions from the design
          // spec, stable regardless of keyboard visibility.
          const cellWidth = _targetFontSize * _monoAdvanceRatio;   // 6.9px
          const cellHeight = _targetFontSize * _lineHeightFactor;  // 17.825px

          // How many columns/rows fit on the phone screen.
          final fitCols = ((constraints.maxWidth - _termPadH * 2) / cellWidth)
              .floor()
              .clamp(1, 999);
          final fitRows = ((constraints.maxHeight - _termPadV * 2) / cellHeight)
              .floor()
              .clamp(1, 999);

          // Send resize to Mac if phone dimensions changed (tmux-style resize).
          // After resize, _cols from the cell stream will match fitCols, so
          // wrapLines becomes 1 and rendering is 1:1 with the Mac grid.
          if (fitCols != _lastSentCols || fitRows != _lastSentRows) {
            _lastSentCols = fitCols;
            _lastSentRows = fitRows;
            _sendResize(fitCols, fitRows);
          }

          // Use Mac's actual cols for rendering (after resize, _cols == fitCols).
          final renderCols = _cols.clamp(1, _cols);
          // How many display lines each Mac row wraps into.
          final wrapLines = (_cols / renderCols).ceil();
          // Total display rows after wrapping.
          final displayRows = _rows * wrapLines;
          final terminalHeight = cellHeight * displayRows;

          // Cursor display position after wrapping.
          final cursorDisplayRow =
              _cursorRow * wrapLines + (_cursorCol ~/ renderCols);

          // Auto-scroll to keep cursor visible, accounting for padding.
          final contentHeight = constraints.maxHeight - (_termPadV * 2);
          final visibleRows = (contentHeight / cellHeight).floor();
          final maxScrollRow =
              (displayRows - visibleRows).clamp(0, displayRows);
          final scrollRow =
              (cursorDisplayRow - visibleRows + 1).clamp(0, maxScrollRow);
          final scrollOffsetY = scrollRow * cellHeight;

          // Cache layout values for hit-testing in gesture handlers.
          _lastFitCols = renderCols;
          _lastWrapLines = wrapLines;
          _lastCellWidth = cellWidth;
          _lastCellHeight = cellHeight;
          _lastScrollOffsetY = scrollOffsetY;

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
                    size: Size(
                      constraints.maxWidth,
                      terminalHeight + _termPadV * 2,
                    ),
                    painter: TerminalPainter(
                      cells: _cells,
                      cols: _cols,
                      rows: _rows,
                      fitCols: renderCols,
                      cellWidth: cellWidth,
                      cellHeight: cellHeight,
                      fontSize: _targetFontSize,
                      paddingH: _termPadH,
                      paddingV: _termPadV,
                      cursorCol: _cursorCol,
                      cursorRow: _cursorRow,
                      cursorVisible: _cursorVisible && _cursorBlinkOn,
                      selStartCol: _selStartCol,
                      selStartRow: _selStartRow,
                      selEndCol: _selEndCol,
                      selEndRow: _selEndRow,
                    ),
                  ),
                ),

                // Copy pill — shown above selection end after long-press lift
                if (_showCopyPill && _hasSelection)
                  _buildCopyPill(renderCols, cellWidth, cellHeight,
                      wrapLines, scrollOffsetY),

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

              ],
            ),
          );
        },
      ),
    );
  }

  /// Floating copy pill positioned above the selection end point.
  Widget _buildCopyPill(int fitCols, double cellWidth, double cellHeight,
      int wrapLines, double scrollOffsetY) {
    // Position pill above the end of the selection.
    final endCol = _selEndCol ?? 0;
    final endRow = _selEndRow ?? 0;
    final displayRow = endRow * wrapLines + (endCol ~/ fitCols);
    final displayCol = endCol % fitCols;
    final pillX = _termPadH + displayCol * cellWidth;
    final pillY =
        _termPadV + displayRow * cellHeight - scrollOffsetY - 36;

    return Positioned(
      left: pillX.clamp(8.0, double.infinity),
      top: pillY.clamp(4.0, double.infinity),
      child: GestureDetector(
        onTap: _copySelection,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFE0A030),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: const Text(
            'Copy',
            style: TextStyle(
              color: Color(0xFF0A0A0F),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
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
  final int fitCols;
  final double cellWidth;
  final double cellHeight;
  final double fontSize;
  final double paddingH;
  final double paddingV;
  final int cursorCol;
  final int cursorRow;
  final bool cursorVisible;

  // Selection bounds in Mac grid coordinates (nullable = no selection).
  final int? selStartCol;
  final int? selStartRow;
  final int? selEndCol;
  final int? selEndRow;

  // Terminal always uses dark palette for cell rendering.
  static const _bg = Color(0xFF0A0A0F);
  static const _fg = Color(0xFFE8E8EE);
  static const _cursorColor = Color(0xCCE0A030); // amber cursor at ~80%
  static const _selectionColor = Color(0x40E0A030); // translucent amber

  TerminalPainter({
    required this.cells,
    required this.cols,
    required this.rows,
    required this.fitCols,
    required this.cellWidth,
    required this.cellHeight,
    required this.fontSize,
    required this.paddingH,
    required this.paddingV,
    required this.cursorCol,
    required this.cursorRow,
    required this.cursorVisible,
    this.selStartCol,
    this.selStartRow,
    this.selEndCol,
    this.selEndRow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (cells.isEmpty || cols == 0 || rows == 0) return;

    // Number of display lines each Mac row wraps into.
    final wrapLines = (cols / fitCols).ceil();

    // 1. Fill entire canvas with terminal background to prevent gaps.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = _bg,
    );

    // Compute selection range (normalized to reading order).
    int selLo = -1;
    int selHi = -1;
    if (selStartCol != null &&
        selStartRow != null &&
        selEndCol != null &&
        selEndRow != null) {
      final selStart = selStartRow! * cols + selStartCol!;
      final selEnd = selEndRow! * cols + selEndCol!;
      selLo = min(selStart, selEnd);
      selHi = max(selStart, selEnd);
    }
    final selPaint = Paint()..color = _selectionColor;

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

        // Draw selection highlight.
        if (selLo >= 0 && index >= selLo && index <= selHi) {
          canvas.drawRect(
              Rect.fromLTWH(x, y, charWidth, cellHeight), selPaint);
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
      final cursorDispRow = cursorRow * wrapLines + (cursorCol ~/ fitCols);
      final cursorDispCol = cursorCol % fitCols;
      final cx = paddingH + cursorDispCol * cellWidth;
      final cy = paddingV + cursorDispRow * cellHeight;
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
        cols != oldDelegate.cols ||
        fitCols != oldDelegate.fitCols ||
        cursorCol != oldDelegate.cursorCol ||
        cursorRow != oldDelegate.cursorRow ||
        cursorVisible != oldDelegate.cursorVisible ||
        cellWidth != oldDelegate.cellWidth ||
        cellHeight != oldDelegate.cellHeight ||
        selStartCol != oldDelegate.selStartCol ||
        selStartRow != oldDelegate.selStartRow ||
        selEndCol != oldDelegate.selEndCol ||
        selEndRow != oldDelegate.selEndRow;
  }
}
