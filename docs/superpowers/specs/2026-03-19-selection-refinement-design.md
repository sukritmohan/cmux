# Selection Refinement: Precision Handles, Magnifier, Clamping

**Status:** Approved (2026-03-19)
**Builds on:** [terminal-selection-handles-design](2026-03-18-terminal-selection-handles-design.md)
**Supersedes:** Phase 1 handle-crossing behavior (role swap → hard clamp), Phase 1 amber color → blue `#4A9EFF`
**File:** `android-companion/lib/terminal/terminal_view.dart`

---

## Problem

Handle dragging is imprecise and frustrating:
1. **Overshoots** — 1:1 finger-to-cell mapping means small finger movements jump multiple cells, especially vertically across rows.
2. **Handle crossing** — dragging the end handle past the start handle (or vice versa) creates inverted/nonsensical selections.
3. **No magnification** — the finger occludes the exact selection boundary, making precision impossible.
4. **Word snap broken** — long-press selects a single character instead of the word under the finger. *(Investigation only — see Section 4.)*

## Design

### 1. Velocity-Damped Drag (iOS-Style Magnetism)

Replace raw `localPosition` mapping with accumulated, velocity-scaled deltas.

**State added to `_TerminalViewState`:**
```dart
double _dragAccumX = 0;  // accumulated scaled X delta
double _dragAccumY = 0;  // accumulated scaled Y delta
double _dragAnchorX = 0; // handle's finger-target viewport X at drag start
double _dragAnchorY = 0; // handle's finger-target viewport Y at drag start
```

**On drag start (`_onHandleDragStart`):**
- Compute handle's current viewport position from anchor cell (same math as `_buildSelectionHandle`).
- Apply `_handleFingerOffsetY` **once** at anchor capture: `_dragAnchorY = handleCenterY - _handleFingerOffsetY`. This represents the finger's hit-test target position, not the handle's visual position.
- Zero `_dragAccumX/Y`.

**On each drag update (`_onHandleDragUpdate`):**
```
velocity = details.delta.distance
ratio = lerp(0.3, 1.0, (velocity / 20.0).clamp(0.0, 1.0))
_dragAccumX += details.delta.dx * ratio
_dragAccumY += details.delta.dy * ratio

// Finger offset already baked into anchor — no second subtraction.
viewportPos = Offset(
  _dragAnchorX + _dragAccumX,
  _dragAnchorY + _dragAccumY,
)
(col, row) = _hitTestCell(viewportPos)
```

**Feel:**
- Slow drag (< 3px/frame): 0.3x ratio — finger moves 10px, cursor moves ~3px (sub-cell precision)
- Fast drag (> 20px/frame): 1.0x ratio — 1:1 movement for fast sweeps
- Smooth lerp between — no jarring transitions

**Cleanup:** `_clearSelection()` must also zero `_dragAccumX/Y` and `_dragAnchorX/Y` to prevent stale state from contaminating future drags.

**Tuning constants (may adjust after device testing):**
- `_dampingMin = 0.3` — minimum damping ratio (slow speed)
- `_dampingMax = 1.0` — maximum damping ratio (fast speed)
- `_dampingVelocityThreshold = 20.0` — velocity (px/frame) at which ratio reaches max

### 2. Hard Clamp — No Handle Crossing

> **Note:** This supersedes the Phase 1 spec's "role swap" behavior. Hard clamp is simpler and avoids user confusion.

After computing `(col, row)` from the damped drag, linearize both handles:

```dart
dragIdx = row * _cols + col
otherIdx = (otherRow * _cols + otherCol)
```

**Clamping rules (strict inequality):**
- Start handle: `if (dragIdx > otherIdx)` → clamp to `otherIdx`
- End handle: `if (dragIdx < otherIdx)` → clamp to `otherIdx`

Using strict `>` / `<` (not `>=` / `<=`) so handles **can** overlap on the same cell (1-character selection) but neither can cross past. When overlapping, dragging either handle away from the overlap freely — no stuck state.

**Minimum selection:** 1 character (both handles on the same cell). The selection never inverts.

**Auto-scroll:** Not included in this spec. Handle drag is limited to currently visible terminal content. If the desired selection extends off-screen, the user must release, scroll, then re-select. Auto-scroll is a future enhancement.

### 3. Magnifier Loupe

A zoomed preview bubble that appears during handle drag, floating above the finger.

**Visual spec:**
```
             ┌─────────────────────┐
             │  ello_wor           │  ← 2x zoom, ~7 visible chars
             │       ▲             │     selection boundary highlighted
             └─────────┬───────────┘     with blue selection color
                       │  60dp gap
                       │
                     ┌─┴─┐
                     │ ● │  ← handle
                     └───┘
```

**Dimensions:**
- Width: 140dp (shows ~7 chars at 2x zoom, enough context)
- Height: 36dp (exactly 1 row at 2x: `17.825 * 2 = 35.65`, rounded to 36dp)
- Corner radius: 8dp
- Background: terminal background (`#0A0A0F`) with 1dp border (`#333`)
- Shadow: `BoxShadow(color: 0x60000000, blurRadius: 8, offset: (0, 2))`

**Rendering:**
- `_MagnifierPainter` CustomPainter, separate from `TerminalPainter`
- Reuses the same cell-rendering approach as `TerminalPainter`: `ui.ParagraphBuilder` per-cell with `fontSize * _magnifierZoom` (23px) and `cellWidth * _magnifierZoom` / `cellHeight * _magnifierZoom`
- Centers on the current selection boundary cell (the cell being dragged)
- Shows selection highlight (blue `#4A9EFF` at 25% opacity) for cells within the selection range
- Clips to the loupe's rounded rect via `canvas.clipRRect()`
- Receives: `cells`, `cols`, `focusCol`, `focusRow`, `cellWidth`, `cellHeight`, `fontSize`, `selLo`, `selHi`

**Positioning:**
- Horizontally centered on the handle, clamped to screen edges (8dp margin left/right)
- **Vertically, default:** 60dp above handle top edge
- **Vertical edge case:** If the magnifier's top edge would go above `y = 8`, flip it **below** the handle instead (60dp below handle bottom edge). This handles selections in the top rows.
- Follows handle position on each drag update

**Animation:**
- **Appear:** `AnimatedOpacity` from 0.0 → 1.0, duration 100ms, `Curves.easeOut`. Delayed 50ms after drag start to avoid flicker on accidental touches.
- **Disappear:** `AnimatedOpacity` from 1.0 → 0.0, duration 80ms, `Curves.easeIn`.
- State: `_showMagnifier` bool toggled on drag start/end, drives `AnimatedOpacity`.

**Lifecycle:**
- Drag start: set `_showMagnifier = true` after 50ms timer
- Drag update: update magnifier position + focus cell
- Drag end: set `_showMagnifier = false`, cancel timer if pending

### 4. Word Snap Investigation (Out of Scope for Implementation)

> **This section is investigation-only.** The word snap fix will be a separate follow-up once the root cause is identified.

The `_expandToWord()` method checks `cell.codepoint == 0 || cell.codepoint == 0x20` to detect boundaries. Current behavior: selects single character instead of word.

**Investigation plan:**
1. Add `debugPrint` in `_onLongPressStart` to log the codepoint at the hit-tested cell and its neighbors.
2. Likely root cause: cell codepoints may be encoded differently than expected (e.g., UTF-32 vs UTF-16, or the binary parser stores grapheme clusters differently).
3. Fix will depend on what the debug logging reveals.

If the codepoints are correct but the word detection heuristic is wrong, we'll expand the "word character" set to include common terminal characters like `-`, `_`, `.`, `/`, `~`.

## Interaction Lifecycle (Updated)

1. **Long press** → selects word (or single char until word snap is fixed) → handles + copy pill appear
2. **Handle drag start** → 50ms timer starts → magnifier fades in, copy pill hides, drag anchor + finger offset captured, accumulators zeroed
3. **Handle drag update** → velocity-damped delta accumulated → cell computed → **clamped** against other handle → magnifier + handle + selection update
4. **Handle drag end** → magnifier fades out, copy pill reappears, accumulators reset

## Constants Summary

| Name | Value | Purpose |
|------|-------|---------|
| `_dampingMin` | 0.3 | Min drag ratio (slow speed) |
| `_dampingMax` | 1.0 | Max drag ratio (fast speed) |
| `_dampingVelocityThreshold` | 20.0 | px/frame for max ratio |
| `_handleFingerOffsetY` | 28.0 | Vertical offset above touch (applied once at anchor) |
| `_hapticThrottleMs` | 30 | Min ms between haptics |
| `_magnifierWidth` | 140.0 | Loupe width in dp |
| `_magnifierHeight` | 36.0 | Loupe height (1 row at 2x zoom) |
| `_magnifierOffsetY` | 60.0 | Gap above/below handle |
| `_magnifierZoom` | 2.0 | Zoom factor |
| `_magnifierDelay` | 50 | ms delay before showing |
| `_magnifierFadeIn` | 100 | ms fade-in duration |
| `_magnifierFadeOut` | 80 | ms fade-out duration |

## Files Modified

- `android-companion/lib/terminal/terminal_view.dart` — all changes in this single file

## Verification

1. `cd android-companion && flutter analyze --no-pub` — no new errors
2. Build + deploy: `cd android-companion && flutter build apk --debug && tailscale file cp build/app/outputs/flutter-apk/app-debug.apk sm-fold:`
3. Manual test:
   - Slow drag: handle moves ~0.3x finger speed, character-precise
   - Fast drag: handle moves 1:1, covers ground quickly
   - Magnifier: appears during drag with 100ms fade, shows 2x zoomed text with selection highlight
   - Magnifier flips below handle when near top of terminal
   - End handle clamped: cannot drag past start handle (and vice versa)
   - Handles can overlap (1-char selection) but not cross
   - Selection clear resets all drag state cleanly
   - Long press: debug logging shows cell codepoints (word snap investigation only)
