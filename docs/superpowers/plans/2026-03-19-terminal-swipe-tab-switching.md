# Implementation Plan: Terminal Swipe Tab Switching

**Spec:** `docs/superpowers/specs/2026-03-19-terminal-swipe-tab-switching-design.md`
**Date:** 2026-03-19

## Dependency Graph

```
Chunk 1 (Gesture Detection)  ──┐
                                ├──► Chunk 3 (Animation/Orchestration) ──► Chunk 4 (Pre-rendering)
Chunk 2 (Navigation Helpers) ──┘         │                                       │
                                         ├──► Chunk 5 (Tab Bar Sync)             │
                                         ├──► Chunk 6 (Haptics)                  │
                                         │                                       │
                                         └───────────┬───────────────────────────┘
                                                      │
                                                      ▼
                                              Chunk 7 (Polish)
```

Chunks 1 and 2 can be implemented in parallel. Chunks 4, 5, and 6 can be implemented in parallel after Chunk 3. Chunk 7 comes last.

---

## Chunk 1: Direction-Lock Gesture Detection in GestureLayer

**Files:** `android-companion/lib/shared/gesture_layer.dart`

**Changes:**

Add direction-lock state machine to `_GestureLayerState`. New fields:
- `_directionLock` enum (`none`, `horizontal`, `vertical`)
- `_cumulativeDelta` (Offset accumulator)
- Constant `_directionLockThreshold = 10.0`

Extend `GestureCallbacks` with three new optional callbacks:
- `onTabSwipeStart` (`VoidCallback?`) — called when direction locks to horizontal
- `onTabSwipeUpdate` (`ValueChanged<double>?`) — called with cumulative horizontal pixel displacement
- `onTabSwipeEnd` (`void Function(double displacement, double velocity)?`) — called on release with final displacement and horizontal velocity

Add parameter `bool canSwipeTabs` (default `false`). When false, direction-lock branch is entirely skipped.

Modify `_onScaleStart`: when `_pointerCount == 1`, `canSwipeTabs` is true, and NOT an edge swipe, reset `_directionLock` to `none` and `_cumulativeDelta` to `Offset.zero`.

Modify `_onScaleUpdate`: when `_pointerCount == 1`, `canSwipeTabs` is true, NOT edge swipe:
- If `_directionLock == none`: accumulate delta. Once magnitude exceeds 10px, compare `abs(dx)` vs `abs(dy)`. Set lock accordingly. If horizontal, call `onTabSwipeStart`.
- If `_directionLock == horizontal`: call `onTabSwipeUpdate(cumulativeDeltaX)`.
- If `_directionLock == vertical`: call `onScroll(deltaY)` as today.

Modify `_onScaleEnd`: if `_directionLock == horizontal`, call `onTabSwipeEnd(displacement, velocityX)` instead of the normal pan-end logic.

**Acceptance Criteria:**
- Single-finger horizontal swipe (>10px) triggers `onTabSwipeStart` + continuous `onTabSwipeUpdate`
- Single-finger vertical swipe (>10px) still triggers `onScroll` as before
- Edge swipe (x < 20px) still opens drawer regardless of direction
- Two-finger pinch still opens minimap
- When `canSwipeTabs` is false, all behavior identical to current code

**Dependencies:** None

---

## Chunk 2: Surface Provider Navigation Helpers

**Files:** `android-companion/lib/state/surface_provider.dart`

**Changes:**

Add two methods to `SurfaceNotifier`:
- `String? nextSurfaceId()` — returns surface ID after `focusedSurfaceId` in list, or `null` at end
- `String? previousSurfaceId()` — returns surface ID before `focusedSurfaceId` in list, or `null` at start

Add convenience getters to `SurfaceState`:
- `int get focusedIndex` — index of `focusedSurfaceId` in `surfaces`, or 0
- `bool get hasMultipleSurfaces` — `surfaces.length > 1`

Pure lookups, no state mutation.

**Acceptance Criteria:**
- `nextSurfaceId()` returns correct next ID, or `null` at last surface
- `previousSurfaceId()` returns correct previous ID, or `null` at first surface
- `focusedIndex` returns correct zero-based index
- `hasMultipleSurfaces` returns false when 0 or 1 surfaces

**Dependencies:** None

---

## Chunk 3: Animation Infrastructure and Swipe Orchestration

**Files:** `android-companion/lib/terminal/terminal_screen.dart`

**Changes:**

Make `_TerminalScreenState` use `TickerProviderStateMixin` for animation support.

Add state fields:
- `AnimationController _swipeAnimController` — drives commit/cancel/rubber-band spring animations
- `ValueNotifier<double> _swipeOffset` — current horizontal pixel offset (0 = rest, negative = left, positive = right)
- `String? _swipeTargetSurfaceId` — adjacent surface being swiped toward
- `bool _isSwipeAnimating` — tracks whether spring animation is in flight

Add handler methods:

`_onTabSwipeStart()`:
- If animation in flight, snap to end state immediately (`_swipeAnimController.stop()`, apply final value, reset)
- Check multiple surfaces via `canSwipeTabs`

`_onTabSwipeUpdate(double displacement)`:
- Determine direction: negative = swiping left (next tab), positive = right (previous tab)
- Look up adjacent surface via `nextSurfaceId()` / `previousSurfaceId()`
- If no adjacent surface: apply rubber-band dampening `_swipeOffset.value = displacement * 0.3`
- Otherwise: set `_swipeTargetSurfaceId`, `_swipeOffset.value = displacement` (1:1 tracking)

`_onTabSwipeEnd(double displacement, double velocity)`:
- Commit if `abs(displacement) > terminalWidth * 0.35` OR `abs(velocity) > 800`
- If commit and target exists: animate `_swipeOffset` to `+/- terminalWidth` with `SpringSimulation`. On complete, call `_commitTabSwitch()`
- If cancel: animate `_swipeOffset` back to 0, clear target

`_commitTabSwitch()`:
- Call `ref.read(surfaceProvider.notifier).focusSurface(_swipeTargetSurfaceId!)`
- Send RPC `surface.focus` via connection manager
- Reset `_swipeOffset.value = 0`, `_swipeTargetSurfaceId = null`, `_scrollRemainder = 0`

Wire `GestureLayer` with `canSwipeTabs: surfaceState.hasMultipleSurfaces` and the three callbacks.

Wrap terminal content in `ValueListenableBuilder<double>` on `_swipeOffset` with `Transform.translate`. (Adjacent terminal rendering deferred to Chunk 4.)

**Acceptance Criteria:**
- Horizontal swipe moves terminal view left/right following finger
- Releasing past 35% of width animates to completion and switches tabs
- Releasing with velocity > 800 px/s commits regardless of displacement
- Releasing below thresholds snaps back to center
- Rubber-band dampening at edges (first/last tab)
- New touch during animation snaps previous animation to end state
- Scroll remainder resets on tab switch
- RPC `surface.focus` sent to desktop on commit

**Dependencies:** Chunk 1, Chunk 2

---

## Chunk 4: Adjacent Terminal Pre-Rendering (Snapshot Painter)

**Files:**
- `android-companion/lib/terminal/terminal_snapshot_painter.dart` (new)
- `android-companion/lib/terminal/terminal_screen.dart`
- `android-companion/lib/state/surface_provider.dart`

**Changes:**

**New file `terminal_snapshot_painter.dart`:**
Create `TerminalSnapshotPainter` extending `CustomPainter`. Accepts same cell data as `TerminalPainter` but renders static snapshot — no cursor, no selection, no blink timer. Reuse cell-rendering logic from `TerminalPainter` via shared helper/mixin.

**Surface provider:**
Add `Map<String, CellSnapshot> _cellSnapshots` to `SurfaceNotifier` where `CellSnapshot` holds `List<CellData> cells`, `int cols`, `int rows`. Methods:
- `updateSnapshot(surfaceId, cells, cols, rows)` — stores latest
- `CellSnapshot? getSnapshot(surfaceId)` — retrieves it

**Terminal screen:**
In `ValueListenableBuilder`, when `_swipeTargetSurfaceId != null` and offset != 0:
- Look up snapshot from provider
- Render `CustomPaint` with `TerminalSnapshotPainter` positioned at `screenWidth + offsetX` or `-screenWidth + offsetX`
- Both current terminal and snapshot in a `Stack` wrapped in `ClipRect`

**Terminal view (minor):**
When receiving new cell frame, also call `updateSnapshot(surfaceId, cells, cols, rows)` so latest frame is always available.

**Acceptance Criteria:**
- Adjacent terminal's last known content visible sliding in during swipe
- Snapshot matches live terminal visual style (colors, font, background)
- No cursor or selection in snapshot
- No live subscription created for adjacent surface
- Snapshot updates on each cell frame arrival

**Dependencies:** Chunk 3

---

## Chunk 5: Tab Bar Sync During Swipe

**Files:**
- `android-companion/lib/terminal/tab_bar_strip.dart`
- `android-companion/lib/terminal/top_bar.dart`
- `android-companion/lib/terminal/terminal_screen.dart`

**Changes:**

**TabBarStrip:**
Add optional params `double? swipeProgress` (-1.0 to 1.0) and `int? swipeTargetIndex`.
Convert to `StatefulWidget` with `ScrollController` for `ListView`.

When swipe active:
- Render underline as separate positioned widget that lerps between current and target tab positions
- Auto-scroll `ListView` to reveal target tab when `abs(swipeProgress) > 0.2`

**TopBar:** Pass through `swipeProgress` and `swipeTargetIndex`.

**TerminalScreen:** Compute `swipeProgress = _swipeOffset.value / terminalWidth` (clamped -1..1), determine `swipeTargetIndex`. Pass via `TopBar`. Use `ValueListenableBuilder` around `TopBar` for efficient updates.

**Acceptance Criteria:**
- Tab underline smoothly interpolates between current and target tab during swipe
- Off-screen target tabs auto-scroll into view at 20%
- Indicator settles on new tab on commit, returns to original on cancel
- No visual glitches with adjacent vs distant tabs

**Dependencies:** Chunk 3

---

## Chunk 6: Haptic Feedback

**Files:** `android-companion/lib/terminal/terminal_screen.dart`

**Changes:**

Add `bool _hasPassedCommitThreshold`, reset in `_onTabSwipeStart`.

In `_onTabSwipeUpdate`:
- Check if displacement exceeds 35% of terminal width
- If crossing above (and `_swipeTargetSurfaceId != null`): `HapticFeedback.lightImpact()`, set flag
- If crossing back below: reset flag (no haptic)

In `_commitTabSwitch`: `HapticFeedback.mediumImpact()`.

Import `package:flutter/services.dart`.

**Acceptance Criteria:**
- Light haptic fires exactly once when crossing 35% threshold
- No haptic on crossing back below
- Medium haptic on commit
- No haptic on cancel or rubber-band
- Velocity-only commits skip light haptic but still get medium on commit

**Dependencies:** Chunk 3

---

## Chunk 7: Polish and Edge Cases

**Files:**
- `android-companion/lib/shared/gesture_layer.dart`
- `android-companion/lib/terminal/terminal_screen.dart`
- `android-companion/lib/terminal/terminal_view.dart`

**Changes:**

**Animation interruption polish:**
In `_onTabSwipeStart`, if interrupted animation was a commit, apply tab switch immediately before new gesture. If cancel, snap offset to 0.

**Single-tab suppression:**
Verify `canSwipeTabs` recomputes reactively when surfaces change (natural from reading `surfaceState` each build).

**Spring curve tuning:**
Define named constants:
- `_commitSpringDesc = SpringDescription(mass: 1, stiffness: 500, damping: 30)` — ~300ms, slight overshoot
- `_cancelSpringDesc = SpringDescription(mass: 1, stiffness: 600, damping: 35)` — snappier return
- `_rubberBandSpringDesc = SpringDescription(mass: 1, stiffness: 700, damping: 40)` — tight bounce-back

**Text selection cleanup:**
In `_onTabSwipeStart`, increment `_scrollNotifier.value` to clear active text selection.

**Edge swipe priority:**
Verify `_isEdgeSwipe` check bypasses direction-lock entirely.

**Memory management:**
In `SurfaceNotifier.onSurfaceClosed`, also remove from `_cellSnapshots`.

**Acceptance Criteria:**
- Rapid successive swipes (3+ tabs) work without glitches or state corruption
- Closing tabs to one disables swipe seamlessly
- Spring animations feel natural (~300ms)
- Text selection cleared on swipe start
- Left-edge drawer swipe works correctly
- No memory leaks from orphaned snapshots
- No stale `_swipeTargetSurfaceId` after interrupted animations

**Dependencies:** Chunks 1-6
