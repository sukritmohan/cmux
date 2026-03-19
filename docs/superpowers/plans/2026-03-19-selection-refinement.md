# Selection Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make handle dragging feel precise and magical — velocity-damped drag, hard clamp to prevent handle crossing, and a magnifier loupe during drag.

**Architecture:** All changes in a single file (`android-companion/lib/terminal/terminal_view.dart`). Three features layered sequentially: (1) velocity damping replaces the raw coordinate mapping in `_onHandleDragUpdate`, (2) hard clamp adds a post-computation guard, (3) magnifier adds a new `_MagnifierPainter` class and a positioned widget in the Stack. Plus word snap debug logging.

**Tech Stack:** Flutter/Dart, CustomPainter, `ui.ParagraphBuilder`

**Spec:** `docs/superpowers/specs/2026-03-19-selection-refinement-design.md`

---

### Task 1: Add Velocity Damping State + Rewrite `_onHandleDragUpdate`

**Files:**
- Modify: `android-companion/lib/terminal/terminal_view.dart:128-146` (state declarations)
- Modify: `android-companion/lib/terminal/terminal_view.dart:439-447` (`_clearSelection`)
- Modify: `android-companion/lib/terminal/terminal_view.dart:560-638` (drag handlers)

- [ ] **Step 1: Add damping constants and state variables**

After the existing `_hapticThrottleMs` constant (~line 566), add damping constants:

```dart
/// Velocity damping: slow drags are scaled down for precision.
static const _dampingMin = 0.3;
static const _dampingMax = 1.0;
static const _dampingVelocityThreshold = 20.0;
```

After the existing `_showCopiedFeedback` field (~line 135), add drag accumulator state:

```dart
// Velocity-damped drag accumulators.
double _dragAccumX = 0;
double _dragAccumY = 0;
double _dragAnchorX = 0;
double _dragAnchorY = 0;
```

- [ ] **Step 2: Update `_clearSelection` to zero accumulators**

In `_clearSelection()` (~line 439), add after `_isDraggingEndHandle = false;`:

```dart
_dragAccumX = _dragAccumY = 0;
_dragAnchorX = _dragAnchorY = 0;
```

- [ ] **Step 3: Rewrite `_onHandleDragStart` to capture anchor**

Replace the body of `_onHandleDragStart` (~line 568) with:

```dart
void _onHandleDragStart(bool isStart, DragStartDetails details) {
  // Compute handle's viewport position (same math as _buildSelectionHandle).
  final anchorCol = isStart ? _selStartCol! : _selEndCol!;
  final anchorRow = isStart ? _selStartRow! : _selEndRow!;
  final pos = _gridToScreen(anchorCol, anchorRow);

  final handleCenterX = isStart
      ? pos.dx          // start: stem at left edge of cell
      : pos.dx + _lastCellWidth;  // end: stem at right edge of cell
  final handleCenterY = isStart
      ? pos.dy           // start: stem bottom at cell top
      : pos.dy + _lastCellHeight; // end: stem top at cell bottom

  // Bake finger offset into anchor once — no second subtraction in update.
  _dragAnchorX = handleCenterX;
  _dragAnchorY = handleCenterY - _handleFingerOffsetY;
  _dragAccumX = 0;
  _dragAccumY = 0;

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
```

- [ ] **Step 4: Rewrite `_onHandleDragUpdate` with velocity damping**

Replace the entire `_onHandleDragUpdate` method (~line 580) with:

```dart
void _onHandleDragUpdate(bool isStart, DragUpdateDetails details) {
  // Velocity-damped accumulation: slow drags are scaled down for precision.
  final velocity = details.delta.distance;
  final ratio = _dampingMin +
      (_dampingMax - _dampingMin) *
          (velocity / _dampingVelocityThreshold).clamp(0.0, 1.0);
  _dragAccumX += details.delta.dx * ratio;
  _dragAccumY += details.delta.dy * ratio;

  // Finger offset already baked into anchor — no second subtraction.
  final viewportPos = Offset(
    _dragAnchorX + _dragAccumX,
    _dragAnchorY + _dragAccumY,
  );
  final (col, row) = _hitTestCell(viewportPos);

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
```

- [ ] **Step 5: Run flutter analyze**

Run: `cd android-companion && flutter analyze --no-pub`
Expected: No new errors (only pre-existing warnings)

- [ ] **Step 6: Commit**

```bash
cd /Users/sm/code/cmux && git add android-companion/lib/terminal/terminal_view.dart
git commit -m "feat(android): add velocity-damped drag to selection handles

Slow drags (< 3px/frame) scale at 0.3x for character-precise selection.
Fast drags (> 20px/frame) move 1:1 for quick coverage. Finger offset
baked into anchor at drag start to prevent double-subtraction.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add Hard Clamp — Prevent Handle Crossing

**Files:**
- Modify: `android-companion/lib/terminal/terminal_view.dart` (`_onHandleDragUpdate` from Task 1)

- [ ] **Step 1: Add clamping logic after hit-test in `_onHandleDragUpdate`**

In `_onHandleDragUpdate`, after `final (col, row) = _hitTestCell(viewportPos);`, insert the clamping block before the `prevCol`/`prevRow` lines:

```dart
  // Hard clamp: prevent handle crossing. Start can't pass end, end can't pass start.
  var clampedCol = col;
  var clampedRow = row;
  final dragIdx = row * _cols + col;
  if (isStart) {
    final endIdx = _selEndRow! * _cols + _selEndCol!;
    if (dragIdx > endIdx) {
      clampedCol = _selEndCol!;
      clampedRow = _selEndRow!;
    }
  } else {
    final startIdx = _selStartRow! * _cols + _selStartCol!;
    if (dragIdx < startIdx) {
      clampedCol = _selStartCol!;
      clampedRow = _selStartRow!;
    }
  }
```

Then change the references from `col`/`row` to `clampedCol`/`clampedRow` for the remainder of the method (prevCol comparison and setState).

The full method after this change:

```dart
void _onHandleDragUpdate(bool isStart, DragUpdateDetails details) {
  // Velocity-damped accumulation.
  final velocity = details.delta.distance;
  final ratio = _dampingMin +
      (_dampingMax - _dampingMin) *
          (velocity / _dampingVelocityThreshold).clamp(0.0, 1.0);
  _dragAccumX += details.delta.dx * ratio;
  _dragAccumY += details.delta.dy * ratio;

  final viewportPos = Offset(
    _dragAnchorX + _dragAccumX,
    _dragAnchorY + _dragAccumY,
  );
  var (col, row) = _hitTestCell(viewportPos);

  // Hard clamp: prevent handle crossing.
  final dragIdx = row * _cols + col;
  if (isStart) {
    final endIdx = _selEndRow! * _cols + _selEndCol!;
    if (dragIdx > endIdx) {
      col = _selEndCol!;
      row = _selEndRow!;
    }
  } else {
    final startIdx = _selStartRow! * _cols + _selStartCol!;
    if (dragIdx < startIdx) {
      col = _selStartCol!;
      row = _selStartRow!;
    }
  }

  final prevCol = isStart ? _selStartCol : _selEndCol;
  final prevRow = isStart ? _selStartRow : _selEndRow;
  if (col == prevCol && row == prevRow) return;

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
```

- [ ] **Step 2: Run flutter analyze**

Run: `cd android-companion && flutter analyze --no-pub`
Expected: No new errors

- [ ] **Step 3: Commit**

```bash
cd /Users/sm/code/cmux && git add android-companion/lib/terminal/terminal_view.dart
git commit -m "feat(android): hard clamp selection handles — no crossing allowed

Start handle cannot pass end handle and vice versa. Uses strict
inequality so handles can overlap (1-char selection) but never invert.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Add Magnifier Loupe — `_MagnifierPainter` Class

**Files:**
- Modify: `android-companion/lib/terminal/terminal_view.dart` (add new class after `_HandlePainter`)

- [ ] **Step 1: Add `_MagnifierPainter` class**

After the `_HandlePainter` class (after ~line 1354), add the magnifier painter:

```dart
/// Paints a zoomed-in view of terminal cells for the selection magnifier.
///
/// Shows ~7 characters at 2x zoom, centered on [focusCol]/[focusRow].
/// Selection highlight is rendered for cells within [selLo]..[selHi].
class _MagnifierPainter extends CustomPainter {
  final List<CellData> cells;
  final int cols;
  final int focusCol;
  final int focusRow;
  final double cellWidth;
  final double cellHeight;
  final double fontSize;
  final int selLo;
  final int selHi;

  static const _bg = Color(0xFF0A0A0F);
  static const _fg = Color(0xFFE8E8EE);
  static const _selColor = Color(0x404A9EFF); // 25% blue
  static const _zoom = 2.0;

  _MagnifierPainter({
    required this.cells,
    required this.cols,
    required this.focusCol,
    required this.focusRow,
    required this.cellWidth,
    required this.cellHeight,
    required this.fontSize,
    required this.selLo,
    required this.selHi,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Clip to rounded rect.
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(8),
    );
    canvas.clipRRect(rrect);

    // Fill background.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = _bg,
    );

    final zCellW = cellWidth * _zoom;
    final zCellH = cellHeight * _zoom;
    final zFontSize = fontSize * _zoom;

    // How many cells fit in the magnifier width.
    final visibleCols = (size.width / zCellW).ceil();
    // Center the focus cell horizontally.
    final startCol = focusCol - visibleCols ~/ 2;

    for (int i = 0; i < visibleCols; i++) {
      final col = startCol + i;
      if (col < 0 || col >= cols) continue;

      final index = focusRow * cols + col;
      if (index < 0 || index >= cells.length) continue;

      final cell = cells[index];
      if (cell.isSpacerTail) continue;

      final x = i * zCellW + (size.width - visibleCols * zCellW) / 2;
      // Vertically center the single row.
      final y = (size.height - zCellH) / 2;
      final charWidth = cell.isWide ? zCellW * 2 : zCellW;

      // Draw selection highlight.
      if (selLo >= 0 && index >= selLo && index <= selHi) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, charWidth, zCellH),
          Paint()..color = _selColor,
        );
      }

      // Draw character.
      if (cell.codepoint != 0 && !cell.isInvisible) {
        Color fg;
        if (cell.fgIsDefault) {
          fg = _fg;
        } else {
          fg = Color.fromARGB(255, cell.fgR, cell.fgG, cell.fgB);
        }
        if (cell.isInverse) {
          final cellBg = cell.bgIsDefault ? _bg : Color.fromARGB(255, cell.bgR, cell.bgG, cell.bgB);
          fg = cellBg;
        }
        if (cell.isFaint) {
          fg = fg.withAlpha(128);
        }

        final textStyle = ui.TextStyle(
          color: fg,
          fontSize: zFontSize,
          fontFamily: 'JetBrains Mono',
          fontWeight: cell.isBold ? FontWeight.bold : FontWeight.normal,
          fontStyle: cell.isItalic ? FontStyle.italic : FontStyle.normal,
        );

        final pb = ui.ParagraphBuilder(
          ui.ParagraphStyle(textAlign: TextAlign.left),
        )
          ..pushStyle(textStyle)
          ..addText(cell.character);

        final paragraph = pb.build()
          ..layout(ui.ParagraphConstraints(width: charWidth));

        final textY = y + (zCellH - paragraph.height) / 2;
        canvas.drawParagraph(paragraph, Offset(x, textY));
      }
    }

    // Draw border.
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = const Color(0xFF333333)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _MagnifierPainter old) {
    return !identical(cells, old.cells) ||
        focusCol != old.focusCol ||
        focusRow != old.focusRow ||
        selLo != old.selLo ||
        selHi != old.selHi;
  }
}
```

- [ ] **Step 2: Run flutter analyze**

Run: `cd android-companion && flutter analyze --no-pub`
Expected: No new errors (class is defined but not yet used — no warning since it's private and will be referenced in Task 4)

- [ ] **Step 3: Commit**

```bash
cd /Users/sm/code/cmux && git add android-companion/lib/terminal/terminal_view.dart
git commit -m "feat(android): add _MagnifierPainter for selection magnifier loupe

Renders ~7 chars at 2x zoom centered on the focus cell, with selection
highlight. Clips to rounded rect with 1dp border. Will be wired into
the widget tree in the next commit.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Wire Magnifier Into Widget Tree + Lifecycle

**Files:**
- Modify: `android-companion/lib/terminal/terminal_view.dart:128-146` (state)
- Modify: `android-companion/lib/terminal/terminal_view.dart:165-173` (dispose)
- Modify: `android-companion/lib/terminal/terminal_view.dart:439-447` (`_clearSelection`)
- Modify: `android-companion/lib/terminal/terminal_view.dart:568-578` (`_onHandleDragStart`)
- Modify: `android-companion/lib/terminal/terminal_view.dart:631-638` (`_onHandleDragEnd`)
- Modify: `android-companion/lib/terminal/terminal_view.dart:886-902` (Stack children)

- [ ] **Step 1: Add magnifier state variables**

After the drag accumulator fields (added in Task 1), add:

```dart
// Magnifier loupe state.
bool _showMagnifier = false;
Timer? _magnifierDelayTimer;
int _magnifierFocusCol = 0;
int _magnifierFocusRow = 0;

static const _magnifierWidth = 140.0;
static const _magnifierHeight = 36.0;
static const _magnifierOffsetY = 60.0;
static const _magnifierDelay = 50; // ms before showing
```

- [ ] **Step 2: Cancel magnifier timer in `dispose`**

In `dispose()` (~line 165), add before `super.dispose();`:

```dart
_magnifierDelayTimer?.cancel();
```

- [ ] **Step 3: Reset magnifier state in `_clearSelection`**

In `_clearSelection()`, add after the accumulator zeroing (from Task 1):

```dart
_showMagnifier = false;
_magnifierDelayTimer?.cancel();
```

- [ ] **Step 4: Show magnifier on drag start (with delay)**

In `_onHandleDragStart`, after the accumulator zeroing (from Task 1), before `setState`, add:

```dart
  // Show magnifier after brief delay to avoid flicker on accidental touches.
  _magnifierFocusCol = anchorCol;
  _magnifierFocusRow = anchorRow;
  _magnifierDelayTimer?.cancel();
  _magnifierDelayTimer = Timer(const Duration(milliseconds: _magnifierDelay), () {
    if (mounted) setState(() => _showMagnifier = true);
  });
```

- [ ] **Step 5: Update magnifier focus cell in drag update**

In `_onHandleDragUpdate`, inside the `setState` block (where `_selStartCol`/`_selEndCol` are updated), add:

```dart
_magnifierFocusCol = col;
_magnifierFocusRow = row;
```

- [ ] **Step 6: Hide magnifier on drag end**

In `_onHandleDragEnd` (~line 631), add at the start of the method body:

```dart
_magnifierDelayTimer?.cancel();
```

And inside the `setState` block, add:

```dart
_showMagnifier = false;
```

- [ ] **Step 7: Add magnifier widget builder method**

Add a new method before `_buildSelectionHandle` (~line 1008):

```dart
/// Builds the magnifier loupe widget, positioned above (or below) the
/// active handle during drag.
Widget _buildMagnifier({
  required double cellWidth,
  required double cellHeight,
  required double viewportWidth,
  required double viewportHeight,
}) {
  // Position magnifier centered on the focus cell.
  final pos = _gridToScreen(_magnifierFocusCol, _magnifierFocusRow);
  final isStart = _isDraggingStartHandle;

  // Handle top edge in viewport.
  final handleTop = isStart
      ? pos.dy - 40
      : pos.dy + cellHeight - 8;

  // Default: above the handle.
  var magnifierTop = handleTop - _magnifierOffsetY - _magnifierHeight;
  // Flip below if too close to top edge.
  if (magnifierTop < 8) {
    final handleBottom = handleTop + 48; // 48dp handle height
    magnifierTop = handleBottom + _magnifierOffsetY;
  }
  // Clamp vertical bottom edge.
  magnifierTop = magnifierTop.clamp(8.0, viewportHeight - _magnifierHeight - 8);

  // Center horizontally on the cell, clamped to screen edges (8dp margin).
  final magnifierLeft = (pos.dx + cellWidth / 2 - _magnifierWidth / 2)
      .clamp(8.0, viewportWidth - _magnifierWidth - 8);

  // Compute selection range for highlight.
  int selLo = -1;
  int selHi = -1;
  if (_hasSelection) {
    final s = _selStartRow! * _cols + _selStartCol!;
    final e = _selEndRow! * _cols + _selEndCol!;
    selLo = min(s, e);
    selHi = max(s, e);
  }

  return Positioned(
    left: magnifierLeft,
    top: magnifierTop,
    child: IgnorePointer(
      child: AnimatedOpacity(
        opacity: _showMagnifier ? 1.0 : 0.0,
        duration: Duration(milliseconds: _showMagnifier ? 100 : 80),
        curve: _showMagnifier ? Curves.easeOut : Curves.easeIn,
        child: Container(
          width: _magnifierWidth,
          height: _magnifierHeight,
          decoration: const BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Color(0x60000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: CustomPaint(
            size: Size(_magnifierWidth, _magnifierHeight),
            painter: _MagnifierPainter(
              cells: _cells,
              cols: _cols,
              focusCol: _magnifierFocusCol,
              focusRow: _magnifierFocusRow,
              cellWidth: cellWidth,
              cellHeight: cellHeight,
              fontSize: _targetFontSize,
              selLo: selLo,
              selHi: selHi,
            ),
          ),
        ),
      ),
    ),
  );
}
```

- [ ] **Step 8: Add magnifier to the Stack in `build()`**

In the Stack children (~line 886), after the selection handles block and before the inner shadow `Positioned`, add:

```dart
// Magnifier loupe — shown during handle drag.
if (_hasSelection && (_isDraggingStartHandle || _isDraggingEndHandle))
  _buildMagnifier(
    cellWidth: cellWidth,
    cellHeight: cellHeight,
    viewportWidth: constraints.maxWidth,
    viewportHeight: constraints.maxHeight,
  ),
```

- [ ] **Step 9: Run flutter analyze**

Run: `cd android-companion && flutter analyze --no-pub`
Expected: No new errors

- [ ] **Step 10: Commit**

```bash
cd /Users/sm/code/cmux && git add android-companion/lib/terminal/terminal_view.dart
git commit -m "feat(android): wire magnifier loupe into selection handle drag

Shows 2x zoomed text centered on the dragged cell. Appears with 100ms
fade after 50ms delay. Flips below handle when near terminal top edge.
Disappears on drag end.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Word Snap Debug Logging

**Files:**
- Modify: `android-companion/lib/terminal/terminal_view.dart:529-540` (`_onLongPressStart`)

- [ ] **Step 1: Add debug logging to `_onLongPressStart`**

In `_onLongPressStart`, after `final (col, row) = _hitTestCell(...)` and before `_expandToWord`, add:

```dart
// Debug: log cell codepoints around the pressed position for word snap investigation.
if (_cells.isNotEmpty && _cols > 0) {
  final rowStart = row * _cols;
  final neighbors = <String>[];
  for (int c = max(0, col - 3); c <= min(_cols - 1, col + 3); c++) {
    final idx = rowStart + c;
    if (idx < _cells.length) {
      final cp = _cells[idx].codepoint;
      final ch = cp > 0x20 ? String.fromCharCode(cp) : '.';
      final marker = c == col ? '*' : ' ';
      neighbors.add('$marker[$c]=0x${cp.toRadixString(16)}($ch)');
    }
  }
  debugPrint('[WordSnap] row=$row col=$col cells: ${neighbors.join(' ')}');
}
```

- [ ] **Step 2: Run flutter analyze**

Run: `cd android-companion && flutter analyze --no-pub`
Expected: No new errors

- [ ] **Step 3: Commit**

```bash
cd /Users/sm/code/cmux && git add android-companion/lib/terminal/terminal_view.dart
git commit -m "debug(android): add word snap codepoint logging on long press

Logs codepoints of cells around the pressed position to diagnose why
word expansion selects single characters instead of full words.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Build, Deploy, and Verify

**Files:** None (build + test only)

- [ ] **Step 1: Run final flutter analyze**

Run: `cd android-companion && flutter analyze --no-pub`
Expected: No new errors

- [ ] **Step 2: Build debug APK**

Run: `cd /Users/sm/code/cmux/android-companion && flutter build apk --debug`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: Deploy to phone**

Run: `tailscale file cp /Users/sm/code/cmux/android-companion/build/app/outputs/flutter-apk/app-debug.apk sm-fold:`
Expected: File sent successfully

- [ ] **Step 4: Manual test checklist**

Verify on device:
- Slow handle drag: handle moves ~0.3x finger speed, character-precise
- Fast handle drag: handle moves 1:1, covers ground quickly
- End handle cannot drag past start handle (clamps at same cell)
- Start handle cannot drag past end handle (clamps at same cell)
- Magnifier appears during handle drag (100ms fade after 50ms delay)
- Magnifier shows 2x zoomed text with blue selection highlight
- Magnifier flips below handle when dragging near top rows
- Magnifier disappears on drag end
- Long press: check logcat for `[WordSnap]` codepoint output
- Copy pill still works after drag refinement
- Clearing selection (tap) resets everything cleanly
