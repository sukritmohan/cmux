# Terminal Text Selection Handles — Design Spec

**Date:** 2026-03-18
**Status:** Approved
**Scope:** Android companion terminal view — refined text selection with draggable handles and haptic snap

## Problem

After the initial long-press selection, users cannot adjust selection boundaries. Once the finger lifts, the selection is frozen — if it's off by a character, the user must start over. On a terminal grid with 6.9px-wide cells, this one-shot model is frustrating and imprecise.

## Solution

Add **inverted teardrop selection handles** at both ends of the selection that the user can drag to refine boundaries. Handles snap to the character grid with **haptic feedback on each cell boundary**, giving users tactile precision even when their finger occludes the text.

## Design

### Selection Handles

**Shape:** Inverted teardrop (lollipop) — filled circle with a thin vertical stem connecting to the character boundary.

**Dimensions:**
- Circle diameter: 24dp
- Stem: 2dp wide x 8dp tall
- Touch target: 48x48dp (invisible, centered on circle)

**Positioning:**
- Start handle: stem connects to top-left corner of first selected cell. Circle hangs below-left.
- End handle: stem connects to bottom-right corner of last selected cell. Circle hangs below-right.
- When handles would overlap (1-2 char selection): start handle flips above the selection.

**Color:**
- Fill: `#E0A030` (accent amber, 100%)
- Stem: `#E0A030` at 70% opacity
- Inner dot: 4dp white circle at center, 40% opacity (subtle "grabbable" affordance)
- Shadow: 0x2dp blur 6dp, `#000000` at 25%

**Lifecycle:**
- Appear immediately when finger lifts after long-press selection (no animation)
- Disappear immediately when selection is cleared (no animation)

### Handle Dragging

**Touch slop:** 8dp dead zone before drag activates (prevents accidental drags near the copy pill).

**Finger offset:** Handle follows finger but offset 28dp upward, so the user's finger does not occlude the selection boundary.

**Snap-to-character:** Handle position maps to nearest cell boundary via hit-testing. Handle jumps instantly from cell to cell — no smooth interpolation, no spring physics. Terminal selection is discrete.

**Handle crossing:** If start handle is dragged past end handle (or vice versa), roles swap silently and instantly.

**Copy pill during drag:** Hide the copy pill while a handle is being dragged. Reposition and show it on release.

### Haptic Feedback

| Moment | Haptic | Purpose |
|--------|--------|---------|
| Long press starts selection | `HapticFeedback.mediumImpact()` | "Grabbed something" |
| Each character boundary during handle drag | `HapticFeedback.selectionClick()` | Detent clicks — feel each character |
| Handle released | `HapticFeedback.mediumImpact()` | "Set down" |
| Copy tapped | `HapticFeedback.heavyImpact()` | Reward thunk |

**Throttling:** Character-boundary haptics throttled to minimum 30ms interval to prevent motor saturation during fast drags.

### Copy Pill Enhancement

After tapping Copy:
1. Text changes from "Copy" to "Copied!" with a checkmark icon
2. Pill color transitions from `#E0A030` (amber) to `#50C878` (green) over 200ms
3. After 600ms, selection and pill are dismissed

### Full Interaction Lifecycle

1. **Long press** → selection starts at pressed cell, amber highlight, `mediumImpact` haptic
2. **Drag** (optional) → selection end extends, `selectionClick` haptic per cell boundary
3. **Lift finger** → handles appear at selection boundaries, copy pill appears above end
4. **Drag a handle** → copy pill hides, handle snaps cell-to-cell with `selectionClick` haptics
5. **Release handle** → copy pill repositions and reappears, `mediumImpact` haptic
6. **Tap "Copy"** → pill shows "Copied!" in green, `heavyImpact` haptic, dismisses after 600ms
7. **Tap elsewhere** → everything dismissed immediately, no haptic

## Implementation Notes

### New State in `_TerminalViewState`

```dart
bool _isDraggingStartHandle = false;
bool _isDraggingEndHandle = false;
Offset? _handleDragOffset;      // finger position during drag
int _lastHapticTimestamp = 0;   // for 30ms throttle
```

### Color Constants

```dart
static const _handleColor = Color(0xFFE0A030);       // amber 100%
static const _handleStemColor = Color(0xB3E0A030);    // amber 70%
static const _handleHighlight = Color(0x66FFFFFF);     // white 40%
static const _handleShadow = Color(0x40000000);        // black 25%
static const _copiedGreen = Color(0xFF50C878);         // success green
```

### Hit Testing Priority

Handle `GestureDetector` widgets sit on top of the terminal `CustomPaint` in the `Stack`, below the copy pill. When a handle is being dragged, gestures should not propagate to the parent scroll/gesture layer.

### File Changes

Only `android-companion/lib/terminal/terminal_view.dart` — all handle rendering, drag logic, and haptic feedback are local widget state. No new files, no new providers.

## Future Enhancements (Phase 2)

- Magnifier lens during handle drag (2x zoom, rounded rect, crosshair)
- Spring physics for handle appearance (overshoot-and-settle)
- Staggered handle entrance animation
- Word-level selection (double-tap)
- Line-level selection (triple-tap)
