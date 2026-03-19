# Modifier Bar & Joystick Arrow Key Redesign

**Date:** 2026-03-18
**Status:** Implemented
**Visual companion:** `docs/mobile-ux/pane-type-switcher-final.html` (existing spec), brainstorm mockups in `.superpowers/brainstorm/`

## Problem

The current arrow key cluster in the mobile modifier bar uses a compact inverted-T layout with 26×14px cells and 10px font. These are too small for comfortable touch targets on a mobile device, especially for heavy use in both shell editing (cursor movement, history recall) and TUI app navigation (vim, htop, tmux).

## Design Direction

Inspired by the Echo SSH app's crosshair button — replace the discrete arrow key cluster with a **circular joystick button** that handles all directional input through swipe and hold+drag gestures. This frees horizontal space in the bar for system modifier keys that were previously impossible to fit.

## Modifier Bar Layout

Left to right:

| Position | Element | Size | Purpose |
|----------|---------|------|---------|
| 1 | `esc ctrl` | 2 keys, each 44px wide × 34px tall, in connected capsule | Essential modifiers — paired for quick access |
| — | Divider | 1×16px | Visual separator |
| 2 | Fan-out `⌇` | 38×34px, rounded rect | Quick-access symbol keys (~ \| / -) |
| — | Flex space | auto | Generous gap — the bar breathes |
| 3 | Joystick `✥` | 40×40px, circular | Arrow key input via swipe/drag |
| — | Divider | 1×16px | Visual separator |
| 4 | `return` | auto×34px, rounded rect | Return/Enter — amber accent, rightmost |

The joystick uses `margin-left: auto` to push itself and Return to the right end of the bar, creating a natural visual separation between the left-side tools and the right-side actions.

### Bar Container

- Floating capsule with 18px border radius
- Frosted glass: `backdrop-filter: blur(24px) saturate(150%)`
- Dark: `rgba(16, 16, 24, 0.82)` with inset highlights and drop shadow
- Light: `rgba(255, 255, 255, 0.75)` with inset highlights and drop shadow
- Margin: `0 8px 2px` from screen edges
- Sits above the home indicator

## Joystick Button

### Visual Design

A **circular** button (40×40px) with a crosshair icon (✥) matching the Echo SSH reference. Visually distinct from the rectangular modifier keys through its round shape.

- **Dark mode:** `rgba(255,255,255,0.06)` fill, `1.5px` border at `rgba(255,255,255,0.08)`, subtle inset highlight and drop shadow for a physical, pressable look
- **Light mode:** `rgba(0,0,0,0.04)` fill, `1.5px` border at `rgba(0,0,0,0.06)`, white inset highlight
- **Crosshair icon:** Four arrow-tipped arms radiating from a center dot, rendered in the button's text color

### Crosshair Icon

The crosshair is a **custom-drawn icon** (not a Unicode character), matching the Echo SSH reference. Four arrow-tipped arms radiating from a center dot. In Flutter, render as a `CustomPainter` or an SVG asset.

### Interaction: Quick Swipe (Single Arrow)

1. User flicks/swipes from the joystick button in any cardinal direction (up/down/left/right)
2. One arrow key event fires in that direction
3. Touch can end anywhere — it's the swipe origin and direction that matter
4. **Minimum swipe distance:** 8px from touch-down point (to distinguish from a tap)
5. **Haptic:** `HapticFeedback.lightImpact()`
6. **Visual:** Button briefly flashes amber in the swipe direction, then returns to resting state

### Diagonal Input Handling

Cardinal sectors are 90° each, centered on the axis (i.e., ±45° from each cardinal direction). A swipe or drag at exactly 45° snaps to the axis closer to the dominant movement component. If the swipe distance is below the minimum threshold (8px for swipe, 12px for drag), no direction is registered.

### Interaction: Press + Hold + Drag (Arrow Repeat)

1. User presses and holds the joystick button for >200ms without significant movement (<4px)
2. Button enters **drag-ready** state — contracts to 92% scale, crosshair glows amber
3. **Haptic:** `HapticFeedback.mediumImpact()` on entering drag-ready state
4. User drags thumb past a 12px threshold in any cardinal direction
5. First arrow key fires immediately
6. Arrow key **repeats on a timer** while the thumb remains past the threshold:
   - Initial repeat interval: **200ms**
   - Accelerates linearly to: **40ms** (over ~1 second of sustained hold)
7. **Haptic:** `HapticFeedback.selectionClick()` on each repeat event
8. **Direction change:** Drag back through center and out in a new direction. The old direction stops repeating; the new direction starts immediately.
9. **Center crossing haptic:** `HapticFeedback.selectionClick()` when passing through center during direction change
10. **Release:** Lift thumb — repeat stops instantly, button springs back to resting state with a 0.2s ease-out-expo animation (not spring — the 400ms spring duration is reserved for larger UI transitions)

### Interaction with Ctrl

- Tap `ctrl` to sticky-toggle it (lights up amber)
- Then swipe or hold+drag the joystick — sends modified arrow (e.g., `Ctrl+→`)
- Ctrl auto-releases after being consumed by the arrow event
- Double-tap `ctrl` to lock it (stays active across multiple inputs)

### Escape Sequences

Arrow keys follow the **xterm** standard. The joystick sends the appropriate CSI sequence based on whether Ctrl is active:

| Direction | No modifier | +Ctrl |
|-----------|-------------|-------|
| Up | `\x1b[A` | `\x1b[1;5A` |
| Down | `\x1b[B` | `\x1b[1;5B` |
| Right | `\x1b[C` | `\x1b[1;5C` |
| Left | `\x1b[D` | `\x1b[1;5D` |

- **Modifier parameter** follows xterm convention: `1;5` for Ctrl.
- **Standalone ctrl tap** (without a subsequent key) does nothing — it is a pure combiner. Ctrl enters sticky state and waits for the next input event.

## Esc + Ctrl Capsule

- **Layout:** Two keys (`esc` and `ctrl`) in a single connected capsule with a 1px gap. `esc` gets left border radius (10px); `ctrl` gets right border radius (10px).
- **Size:** Each key 44×34px
- **Esc behavior:** Tap sends `\x1b` (ESC byte). No sticky state.
- **Ctrl behavior:** Tap to sticky-toggle. Active state shows amber background and text. Double-tap to lock.
- **Sticky visual (single tap):** Solid amber fill, no additional indicator
- **Locked visual (double tap):** Same amber fill + a 2px amber underline bar at the bottom of the key to distinguish from sticky
- **Dark resting:** `rgba(255,255,255,0.06)` background, `rgba(255,255,255,0.45)` text
- **Dark active (ctrl only):** `rgba(224,160,48,0.15)` background, `#F0C060` text
- **Light resting:** `rgba(0,0,0,0.04)` background, `rgba(0,0,0,0.38)` text
- **Light active (ctrl only):** `rgba(224,160,48,0.12)` background, `#B07810` text
- **Haptic:** `HapticFeedback.mediumImpact()` for esc, `HapticFeedback.selectionClick()` for ctrl toggle
- **Rationale:** Esc and Ctrl are the two most critical non-printable keys for terminal use (vim escape, Ctrl+C, Ctrl+D, Ctrl+Z). Shift, Opt, and Cmd are removed to keep the bar spacious — they can be added back later if needed.

## Fan-out Symbol Button

A compact button with a fan icon (three rays radiating from a point) that reveals four common terminal symbols on tap.

- **Position:** Between the esc/ctrl capsule and the joystick
- **Size:** 38×34px, rounded rect (10px radius)
- **Icon:** Three lines radiating upward from a base dot at ±30° and 0° — a custom-drawn fan/spread icon. Not a Unicode character.
- **Dark resting:** `rgba(255,255,255,0.06)` fill, `rgba(255,255,255,0.40)` icon color
- **Dark active:** `rgba(224,160,48,0.12)` fill, `#F0C060` icon color
- **Light resting:** `rgba(0,0,0,0.04)` fill, `rgba(0,0,0,0.35)` icon color
- **Light active:** `rgba(224,160,48,0.10)` fill, `#B07810` icon color

### Fan-out Popover

- **Trigger:** Tap the fan button
- **Direction:** Fans **upward** from the button
- **Content:** Four symbol keys in a horizontal row: `~` `|` `/` `-`
- **Symbol key size:** 48×42px each — full HIG touch targets
- **Symbol key typography:** 18px, JetBrains Mono, weight 500
- **Container:** Frosted glass pill (`backdrop-filter: blur(24px) saturate(150%)`) with 14px border radius. Connected to the button by a small triangular stem.
- **Dark popover:** `rgba(20, 20, 30, 0.95)` background, drop shadow
- **Light popover:** `rgba(255, 255, 255, 0.92)` background, drop shadow
- **Animation:** Spring open with `0.2s ease-out-expo`, scale from 0.95 → 1.0, translate from 6px below → 0
- **Dismissal:** Tap a symbol → inserts the character and auto-dismisses. Tap the fan button again → closes. Tap anywhere outside → closes.
- **Haptic:** `HapticFeedback.lightImpact()` on open, `HapticFeedback.selectionClick()` on symbol selection
- **Sends:** The literal character (`~`, `|`, `/`, or `-`) to the terminal input

## Return Key

The signature button — the only colored element in the bar.

- **Position:** Rightmost
- **Size:** `auto×34px` with `14px` horizontal padding
- **Typography:** 9px, weight 700, uppercase, 1px letter-spacing
- **Dark:** Warm amber gradient (`rgba(224,160,48,0.28)` → `rgba(224,160,48,0.12)` at 145deg), `#F0C060` text, subtle amber glow (`0 0 20px rgba(224,160,48,0.08)`), inset top highlight
- **Light:** Softer amber gradient, `#B07810` text, softer glow
- **Inner shine:** A top-half gradient overlay (`rgba(255,255,255,0.06)` → transparent) gives it a tactile, physical button quality
- **Haptic:** `HapticFeedback.mediumImpact()`
- **Sends:** `\r` (carriage return)

## Terminal Scrolling

Vertical swipe on the terminal surface remains reserved for **terminal scrolling**. The joystick button is the sole mechanism for arrow key input — no gesture zones or swipe-on-terminal interactions conflict with scroll.

## Design Tokens

All colors, radii, and motion curves use the existing cmux design token system defined in `docs/mobile-ux/pane-type-switcher-final.html`. Existing tokens from `colors.dart` are reused where they match. New tokens listed below must be added to `AppColorScheme`.

### Existing tokens (already in `colors.dart`)

- Accent: `#E0A030` / `Color(0xFFE0A030)`
- Accent text on dark: `#F0C060` / `Color(0xFFF0C060)`
- Accent text on light: `#B07810` / `Color(0xFFB07810)`
- Bar bg dark: `Color(0xD1101018)` — `rgba(16,16,24,0.82)`
- Bar bg light: `Color(0xBFFFFFFF)` — `rgba(255,255,255,0.75)`
- Bar border radius: `18px`
- Bar margin: `EdgeInsets.fromLTRB(8, 0, 8, 2)`

### New tokens to add to `colors.dart`

| Token name | Dark value | Light value |
|---|---|---|
| `keyGroupResting` | `rgba(255,255,255,0.06)` | `rgba(0,0,0,0.04)` |
| `keyGroupText` | `rgba(255,255,255,0.45)` | `rgba(0,0,0,0.38)` |
| `keyGroupActive` | `rgba(224,160,48,0.15)` | `rgba(224,160,48,0.12)` |
| `fanBtnResting` | `rgba(255,255,255,0.06)` | `rgba(0,0,0,0.04)` |
| `fanBtnActive` | `rgba(224,160,48,0.12)` | `rgba(224,160,48,0.10)` |
| `fanPopoverBg` | `rgba(20,20,30,0.95)` | `rgba(255,255,255,0.92)` |
| `symKeyResting` | `rgba(255,255,255,0.06)` | `rgba(0,0,0,0.04)` |
| `joystickFill` | `rgba(255,255,255,0.06)` | `rgba(0,0,0,0.04)` |
| `joystickBorder` | `rgba(255,255,255,0.08)` | `rgba(0,0,0,0.06)` |
| `joystickPressed` | `rgba(224,160,48,0.12)` | `rgba(224,160,48,0.10)` |
| `joystickPressedBorder` | `rgba(224,160,48,0.25)` | `rgba(224,160,48,0.20)` |
| `returnGradientStart` | `rgba(224,160,48,0.28)` | `rgba(224,160,48,0.22)` |
| `returnGradientEnd` | `rgba(224,160,48,0.12)` | `rgba(224,160,48,0.08)` |
| `returnGlow` | `rgba(224,160,48,0.08)` | `rgba(224,160,48,0.06)` |

### Motion

- Ease: `cubic-bezier(0.16, 1, 0.3, 1)` (ease-out-expo) — used for button transitions
- Fast duration: `150ms` — button state transitions
- Joystick release: `200ms` ease-out-expo — nub returning to resting state

## Scope

- **Portrait only** for v1. Landscape behavior is deferred.
- **Accessibility:** Each button needs `Semantics` labels. The joystick: "Arrow key joystick. Swipe for single arrow, press and hold then drag for repeat." Ctrl states: "Control, active" / "Control, locked" / "Control, inactive." Fan button: "Symbol shortcuts. Double tap to open."

## What This Replaces

The current modifier bar had three zones: `actions | arrows | enter`

- `+` (new tab) button → **removed from bar** (available elsewhere in UI via tab strip)
- `⎘` (clipboard) button → **removed from bar** (system paste gesture or long-press)
- Arrow cluster (inverted-T, 26×14px cells) → **replaced by joystick button**
- `return` button → **kept, redesigned with amber accent**

New zones: `esc ctrl | fan | ——— | joystick | return`
