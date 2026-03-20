# Terminal Swipe-to-Switch-Tabs Design Spec

**Date:** 2026-03-19
**Status:** Approved

## Overview

Add horizontal swipe gestures to the terminal surface that switch between tabs with interactive drag tracking and slide animations. The gesture is scoped exclusively to the terminal surface — it does not activate on the keyboard, modifier bar, tab bar, or non-terminal panes (browser, files, overview).

## Gesture Mechanics

### Direction Lock

The first ~10px of finger movement determines the gesture axis:

- **Horizontal wins** → tab swipe gesture begins; vertical movement is ignored for the remainder of this touch
- **Vertical wins** → terminal scroll (existing behavior); horizontal movement is ignored

This extends the existing `GestureLayer` `onScaleStart/Update/End` infrastructure with new direction-lock logic. The direction lock is determined by comparing `abs(deltaX)` vs `abs(deltaY)` once cumulative displacement exceeds the 10px dead zone. Currently, `GestureLayer` routes all single-finger movement to `onScroll` — the new code adds a direction-lock phase before routing.

### Single-Tab Behavior

When only one tab exists, the horizontal swipe gesture is entirely suppressed — no direction lock, no tracking, no rubber-band. The gesture falls through to the existing vertical scroll handler as if the tab swipe feature does not exist.

### Interactive Drag

Once direction-locked to horizontal:

- The current terminal view translates horizontally following the finger position
- The adjacent terminal (next or previous tab) peeks in from the corresponding screen edge
- Movement is 1:1 with finger position (no dampening during normal range)

### Commit vs Cancel

- **Drag threshold:** If the finger releases past ~35% of the terminal surface width, the tab switch commits
- **Flick threshold:** If horizontal velocity exceeds ~800 px/s at release, the switch commits regardless of displacement (enables quick flick gestures)
- **Cancel:** Below both thresholds, the current terminal snaps back to center with a spring animation

### Animation Interruption

If a new touch begins while a commit or cancel animation is in flight:

- The in-flight animation **snaps immediately to its end state** (no partial positions)
- The new gesture starts fresh from the snapped state
- This prevents stale animation state and allows rapid successive swipes (e.g., swiping through 3 tabs quickly)

### Edge Behavior (Rubber-Band Bounce)

When on the first or last tab with no adjacent tab in the swipe direction:

- The terminal drags with dampening (e.g., 0.3x finger displacement) to create a rubber-band feel
- On release, it springs back to center
- No tab switch occurs

## Visual Behavior

### Slide Animation

- **During drag:** Current terminal translates `offsetX` pixels. Adjacent terminal is positioned at `screenWidth + offsetX` (coming from right) or `-screenWidth + offsetX` (coming from left)
- **On commit:** Both terminals animate to their final positions with a spring curve (~300ms duration, slight overshoot)
- **On cancel:** Current terminal animates back to center; peeking terminal slides back off-screen

### Tab Bar Sync

The tab bar strip at the top synchronizes with the swipe gesture:

- The active tab underline indicator interpolates position between current and target tab proportionally to swipe progress (`swipeProgress = offsetX / screenWidth`)
- If the target tab is off-screen in the tab strip, the `ListView` auto-scrolls to reveal it as the gesture progresses past ~20% displacement
- On commit, the indicator settles on the new tab; on cancel, it returns to the original tab

## State Integration

### Tab Order

Tab order is derived from `SurfaceState.surfaces` (the ordered list in `surface_provider.dart`). Given the currently focused surface:

- **Swipe left** (finger moves left → content slides left) → next tab in list
- **Swipe right** (finger moves right → content slides right) → previous tab in list

### State Update

On commit:

1. Call `ref.read(surfaceProvider.notifier).focusSurface(targetSurfaceId)`
2. This triggers the existing reactive rebuild pipeline: `SurfaceState` updates → `TerminalView` subscribes to new surface cells
3. The slide animation should complete visually before or concurrently with the state update to avoid flicker

### Pre-rendering the Adjacent Terminal

To show the adjacent terminal during the swipe, capture a snapshot of the adjacent terminal's last known cell state and render it as a static `CustomPainter` during the drag. On commit, swap to the live `TerminalView` subscribed to the new surface.

This avoids keeping multiple live terminal subscriptions active simultaneously (which would require significant changes to the widget tree since `TerminalView` is currently keyed by `surfaceId` and recreated on focus change). The snapshot approach is simpler and sufficient — the adjacent terminal content only needs to look correct for the ~300ms of the swipe gesture.

### Desktop Sync

The swipe-triggered tab switch must send the same RPC command to the desktop as a tap-triggered switch. If `focusSurface()` already sends a socket command (e.g., `surface.focus`), no additional work is needed. If it only updates local state, the swipe commit must also send the appropriate socket command to keep desktop and mobile in sync.

### Haptic Feedback

- **Light haptic** when the swipe crosses the commit threshold (35% displacement) in either direction
- **Medium haptic** on commit (tab switch completes)
- No haptic on cancel or rubber-band

### Scroll State Reset

When a tab switch commits, reset `_scrollRemainder` to 0 to prevent stale scroll accumulation from the previous tab's context carrying over.

## Scope Boundaries

### Where the gesture activates

- Only on the `GestureLayer` wrapping `TerminalView` within `terminal_screen.dart`
- Only when the current pane type is Terminal (not Browser, Files, or Overview)

### Where it does NOT activate

- **Modifier bar** (`modifier_bar.dart`) — has its own gesture handlers (joystick, button taps)
- **Keyboard area** — below the terminal surface, handled by system
- **Tab bar strip** (`tab_bar_strip.dart`) — has its own horizontal scroll and tap handlers
- **Top bar** (`top_bar.dart`) — tap targets for pane type dropdown
- **Attachment strip** — tap targets for staged files

### Interaction with existing gestures

| Existing Gesture | Conflict? | Resolution |
|---|---|---|
| Vertical scroll (single-finger) | Yes | Direction lock (first 10px) |
| Left-edge drawer swipe | Partial | Edge swipe (x < 20px) takes priority over tab swipe |
| Two-finger pinch (minimap) | No | Pointer count >= 2 already routes to pinch handler |

## Implementation Notes

### Files to Modify

1. **`shared/gesture_layer.dart`** — Add horizontal direction lock state, swipe progress tracking, and callbacks (`onTabSwipeStart`, `onTabSwipeUpdate`, `onTabSwipeEnd`)
2. **`terminal/terminal_screen.dart`** — Orchestrate the slide animation using swipe callbacks, manage adjacent terminal pre-rendering, connect to `surfaceProvider` for tab switching
3. **`terminal/tab_bar_strip.dart`** — Accept a `swipeProgress` parameter to animate the active tab indicator and auto-scroll during gesture
4. **`state/surface_provider.dart`** — Add helper methods: `nextSurface()`, `previousSurface()` to get adjacent surface IDs from the ordered list

### Animation Stack

- Use `AnimationController` + `Tween` for the slide transitions
- Spring simulation (`SpringDescription`) for commit/cancel/rubber-band animations
- `ValueNotifier<double>` for swipe progress to avoid rebuilding the full widget tree on every frame

### Performance Considerations

- Adjacent terminal cell rendering should be lightweight — subscribe to cell stream but throttle repaints if not visible
- Swipe progress updates at 60fps — use `ValueListenableBuilder` or `AnimatedBuilder` to limit rebuilds to the translating containers only
- Avoid triggering `surfaceProvider` state changes during the drag — only on commit

## Testing

- Gesture recognition: direction lock correctly distinguishes horizontal vs vertical
- Edge detection: left-edge drawer swipe still works and takes priority
- Commit/cancel: threshold-based and velocity-based switching
- Rubber-band: correct dampening and bounce at first/last tab
- Tab bar sync: indicator position matches swipe progress
- State: correct surface is focused after commit
- Single-tab: no gesture activation when only one tab exists
