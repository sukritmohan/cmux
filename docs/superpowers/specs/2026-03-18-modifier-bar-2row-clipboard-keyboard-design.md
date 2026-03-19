# Modifier Bar: 2-Row Layout with Clipboard, Keyboard & Voice Buttons

**Date:** 2026-03-18
**Status:** Approved
**Supersedes:** 2026-03-18-modifier-bar-joystick-redesign.md (layout only; joystick behavior unchanged)

## Summary

Redesign the Android companion modifier bar from a single-row layout to a 2-row layout. Add three new buttons: Clipboard (with history bottom sheet), Keyboard (toggle soft keyboard), and Voice Recorder (placeholder). Joystick and Return get a dedicated right column with the joystick enlarged.

## Layout

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  Row 1: [esc|tab|ctrl] · [📋] · · · · · · · ·  [🎙]  ║  ⊕    │
│                                                        ║ joy   │
│  Row 2: [~ | / -    ] · · · · · · · · · · · · [⌨ ]  ║ stick │
│                                                        ║       │
│                                                        ║ [RET] │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Structure

The bar is divided into three horizontal zones:

1. **Left zone (2 rows):** Tool buttons arranged in two rows
2. **Center-right zone (stacked):** Voice recorder (top), Autocomplete toggle + Keyboard in a row (bottom), vertically centered
3. **Right column:** Joystick (50px circle) over Return pill, separated by a vertical divider

### Row 1 (top)
- **Esc+Tab+Ctrl capsule** — unchanged from current implementation (3 keys in connected rounded group)
- **Divider**
- **Clipboard button** — 38×34px rounded rect, clipboard icon with amber dot badge when history is non-empty
- **Spacer**

### Row 2 (bottom)
- **Fan-out expanded** — symbols `= ~ | / -` always visible in a connected capsule (no popover tap needed). Each symbol: 34×34px
- **Spacer**

### Center-right stack (vertically centered between rows)
- **Voice recorder** — 34×34px circular button with microphone icon, border matches joystick style. **Placeholder only** — no functionality in this spec
- **Keyboard button** — 46×34px rounded rect. Dual-function:
  - **Short tap** → toggle soft keyboard visibility (request/unfocus on hidden TextField)
  - **Long-press** → toggle autocomplete suggestions (`mediumImpact()` haptic). Toggles `autocompleteActiveNotifier.value`.
  - **Autocomplete ON (default):** blue accent gradient (`rgba(120,180,255,0.2)` → `rgba(80,140,220,0.1)`), 1px blue border, soft blue glow, blue keyboard icon (`rgba(120,180,255,0.7)`)
  - **Autocomplete OFF:** dim background `rgba(255,255,255,0.06)`, no gradient/border/glow, dim icon
  - When keyboard is active and autocomplete ON, border alpha and glow intensity are boosted

### Right column (separated by 1px vertical divider, vertically centered)
- **Joystick** — enlarged to 50×50px (up from 40×40px). Circular, same crosshair icon and gesture behavior. Border: 1.5px at `rgba(255,255,255,0.1)` (updates existing `joystickBorder` token from 0.08 to 0.1)
- **Return** — compact pill, 50×22px, same amber gradient. Font: 8px weight 700. Sits below joystick with 4px gap
- The right column content (50 + 4 + 22 = 76px) is taller than the two-row content (72px). The bar height accommodates the right column as the tallest element.

### Overall bar dimensions
- Height: ~86px (right column content 76px + 10px vertical padding, or two 34px rows + 4px gap + 10px padding — whichever is taller)
- Margin: 8px horizontal, 2px bottom (unchanged)
- Border radius: 18px
- Background: frosted glass (`rgba(16,16,24,0.92)` dark / `rgba(255,255,255,0.75)` light) with 24px blur
- Internal padding: 5px horizontal, 5px vertical
- The vertical divider (1px wide, 56px tall) is vertically centered within the bar

## Clipboard Button

### Button appearance
- Size: 38×34px
- Background: `rgba(255,255,255,0.06)` (matches other tool buttons)
- Border radius: 10px
- Icon: clipboard with lines (stroked, 14px)
- Badge: 7px amber dot (`rgba(224,160,48,0.7)`) in top-right corner when clipboard history is non-empty. 1px dark border for separation.

### Bottom sheet (tap to open)

Tapping the clipboard button opens a bottom sheet that slides up from the bottom, covering ~60% of the terminal area.

**Sheet structure:**
1. **Handle** — 36×4px rounded pill at top, `rgba(255,255,255,0.15)`. Swipe down to dismiss.
2. **Header** — "Clipboard" title (13px, weight 700) + item count on the right
3. **Search bar** — filter across all sections, 10px rounded, subtle background
4. **Scrollable list** — three sections in fixed order:
   - **Latest** — the most recently copied item, always first regardless of starred status. Blue left border accent (2px, `rgba(120,180,255,0.4)`). "just copied" badge in blue.
   - **Starred** — user-pinned items with filled amber stars. User-reorderable within this section.
   - **Recent** — chronological, most recent first. Unstarred items.

**Clipboard item layout:**
- Left: text content (12px monospace, single line truncated with ellipsis) + metadata line below (9px, timestamp + char count)
- Right: star toggle icon (14px, tap to star/unstar)
  - Active: filled amber (`rgba(224,160,48,0.8)`)
  - Inactive: stroked faint (`rgba(255,255,255,0.15)`)

**Interactions:**
- **Tap item** → paste text directly into terminal (write to PTY), dismiss sheet
- **Tap star** → toggle starred status; starred items move to Starred section, unstarred items move to Recent
- **Swipe down on handle** → dismiss sheet
- **Search** → filters across all sections, preserving section grouping

### Empty state
When clipboard history is empty (no items copied yet), the sheet shows a centered message:
- Clipboard icon (24px, `rgba(255,255,255,0.15)`)
- "No clipboard history" text (12px, `rgba(255,255,255,0.3)`)
- "Copy text from the terminal to see it here" subtitle (10px, `rgba(255,255,255,0.15)`)

### No results state
When search yields no matches:
- "No matches" text centered in the list area (12px, `rgba(255,255,255,0.3)`)

### Search behavior
- Debounce: 200ms after last keystroke
- Searches text content only (not timestamps/metadata)
- Minimum query length: 1 character
- Results preserve section grouping (Latest → Starred → Recent)

### Multiline paste safety
When pasting text that contains newlines, use **bracketed paste mode** (`\x1b[200~...\x1b[201~`) to prevent unintended command execution. The terminal will interpret the content as pasted text rather than typed commands. No confirmation prompt needed — bracketed paste is the standard safety mechanism.

### Data model
- **Source:** terminal copies only (via selection handles + copy pill). Does NOT track system clipboard.
- **Capacity:** 100 items max. When full, oldest unstarred items are evicted first. Starred items are never auto-evicted.
- **Persistence:** stored locally on device using `SharedPreferences` (JSON-serialized list). Survives app restarts. Keyed per connection using the connection's `serverId` (the same identifier used in `WorkspaceProvider` for server identity).
- **Deduplication:** if the same text is copied again, move it to Latest (update timestamp) rather than creating a duplicate entry. Preserve starred status if it was starred.

## Keyboard Button

### Button appearance
- Size: 46×34px
- Background: blue accent gradient `linear-gradient(135deg, rgba(120,180,255,0.2), rgba(80,140,220,0.1))`
- Border: 1px solid `rgba(120,180,255,0.15)`
- Glow: `box-shadow: 0 0 12px rgba(120,180,255,0.08)`
- Border radius: 10px
- Icon: keyboard outline with key rectangles, stroked in `rgba(120,180,255,0.7)`

### Behavior
- **Tap** → toggle soft keyboard visibility
  - If keyboard is hidden: request focus on the hidden TextField to bring up the soft keyboard
  - If keyboard is visible: unfocus to dismiss the soft keyboard
- **Visual state:** when keyboard is active/visible, increase border opacity and glow intensity to indicate "on" state
- **Haptic:** `lightImpact()` on tap

## Autocomplete Toggle (via Keyboard Button Long-Press)

Autocomplete toggling is merged into the keyboard button rather than having a separate button.

### Behavior
- **Long-press keyboard button** → toggle `autocompleteActiveNotifier.value`
- **ON (default)** → hidden TextField has `enableSuggestions: true`, `autocorrect: true` (enables keyboard suggestion strip and swipe/gesture typing). Keyboard button shows blue accent style.
- **OFF** → hidden TextField has `enableSuggestions: false`, `autocorrect: false` (raw terminal mode). Keyboard button shows dim style.
- **Haptic:** `mediumImpact()` on long-press
- **Default:** ON (suggestions enabled) — resets to ON each app launch, no persistence
- **Implementation detail:** Toggling requires recreating the TextField with a new `ValueKey` to force Android to create a fresh `InputConnection` with updated `EditorInfo` flags

### Semantics
- Keyboard button label includes autocomplete state: "Show keyboard, autocomplete on, long press to toggle"

## Voice Recorder Button (Placeholder)

### Button appearance
- Size: 34×34px circular
- Background: `rgba(255,255,255,0.06)`
- Border: 1px solid `rgba(255,255,255,0.08)`
- Border radius: 50% (circle)
- Icon: microphone outline, 14px, stroked in `rgba(255,255,255,0.45)`

### Behavior
- **No functionality in this iteration.** Button is rendered but non-interactive (or shows a "Coming soon" tooltip on tap).
- Voice recording feature will be designed in a separate spec.

## Fan-out Changes

The fan-out button is replaced by an **always-expanded symbol capsule**:
- Symbols: `~`, `|`, `/`, `-`
- Each symbol: 34×34px in a connected capsule group (like esc/tab/ctrl)
- 1px dividers between symbols (`rgba(255,255,255,0.06)`)
- Capsule background: `rgba(255,255,255,0.03)`
- Font: JetBrains Mono, 15px, weight 500, `rgba(255,255,255,0.45)`
- Tap → send the character, same `onInput` callback. Symbols always bypass Ctrl modifier (raw character sent regardless of Ctrl state, Ctrl is not auto-released).
- The fan-out popover overlay is no longer needed

## Color Tokens (new additions)

### Dark theme
```
clipboardBadge: Color(0xB3E0A030)        // rgba(224,160,48,0.7)
clipboardBadgeBorder: Color(0xE6101018)  // rgba(16,16,24,0.9)
clipboardLatestBorder: Color(0x6678B4FF) // rgba(120,180,255,0.4)
clipboardLatestBadge: Color(0x9978B4FF)  // rgba(120,180,255,0.6)
keyboardBtnGradientStart: Color(0x3378B4FF) // rgba(120,180,255,0.2)
keyboardBtnGradientEnd: Color(0x1A508CDC)   // rgba(80,140,220,0.1)
keyboardBtnBorder: Color(0x2678B4FF)     // rgba(120,180,255,0.15)
keyboardBtnGlow: Color(0x1478B4FF)       // rgba(120,180,255,0.08)
keyboardBtnIcon: Color(0xB378B4FF)       // rgba(120,180,255,0.7)
sheetBg: Color(0xFA14141E)              // rgba(20,20,30,0.98)
sheetHandle: Color(0x26FFFFFF)           // rgba(255,255,255,0.15)
sheetSearch: Color(0x0AFFFFFF)           // rgba(255,255,255,0.04)
sheetSearchBorder: Color(0x0FFFFFFF)     // rgba(255,255,255,0.06)
```

### Light theme
```
clipboardBadge: Color(0xB3C08020)        // warm amber
clipboardBadgeBorder: Color(0xE6F8F8FA)  // light background
clipboardLatestBorder: Color(0x664080C0) // blue accent
clipboardLatestBadge: Color(0x994080C0)  // blue accent
keyboardBtnGradientStart: Color(0x264080C0)
keyboardBtnGradientEnd: Color(0x1A3060A0)
keyboardBtnBorder: Color(0x264080C0)
keyboardBtnGlow: Color(0x144080C0)       // blue glow
keyboardBtnIcon: Color(0xB34080C0)
sheetBg: Color(0xFAF8F8FA)
sheetHandle: Color(0x26000000)
sheetSearch: Color(0x0A000000)
sheetSearchBorder: Color(0x0F000000)
```

## Dependency injection

`ModifierBar` constructor gains these new parameters:
- `clipboardHistory: ClipboardHistoryNotifier` — Riverpod notifier managing the clipboard history state. Provided via `Provider` from `terminal_screen.dart`.
- `keyboardFocusNode: FocusNode` — the same focus node used by the hidden `TextField` in `TerminalView`. Keyboard button calls `focusNode.requestFocus()` / `focusNode.unfocus()` to toggle the soft keyboard.
- `onInput: ValueChanged<String>` — unchanged, existing callback

The `ClipboardHistoryNotifier` is a `ChangeNotifier` (or Riverpod `StateNotifier`) that:
- Exposes `List<ClipboardItem> items` (ordered: latest, starred, recent)
- Provides `add(String text)`, `toggleStar(String id)`, `reorder(String id, int newIndex)`, `search(String query)` methods
- Handles persistence internally via `SharedPreferences`

## Accessibility

- All buttons have `Semantics` labels using localized strings: `String(localized: "modifier.clipboard", defaultValue: "Clipboard, %d items")`, `String(localized: "modifier.keyboard", defaultValue: "Show keyboard")`, `String(localized: "modifier.voice", defaultValue: "Voice recorder, coming soon")`
- Clipboard items announce: "Paste: [truncated text], [time ago]"
- Star toggle announces: localized "Star item" / "Unstar item"
- Bottom sheet uses `showModalBottomSheet` for proper focus trapping and screen reader announcement

## Files affected

- `lib/terminal/modifier_bar.dart` — 2-row layout, new button slots, autocomplete notifier
- `lib/terminal/fan_out_button.dart` → refactor to `symbol_capsule.dart` (expanded inline symbols, `=` removed)
- `lib/terminal/autocomplete_button.dart` — **deleted**: autocomplete toggle merged into keyboard button long-press
- `lib/terminal/clipboard_button.dart` — new: button + bottom sheet
- `lib/terminal/clipboard_history.dart` — new: data model, persistence, dedup
- `lib/terminal/keyboard_button.dart` — new: keyboard toggle
- `lib/terminal/voice_button.dart` — new: placeholder button
- `lib/app/colors.dart` — new color tokens
- `lib/terminal/terminal_view.dart` — wire autocomplete notifier to TextField suggestions
- `lib/terminal/terminal_screen.dart` — wire clipboard history provider, keyboard focus control, autocomplete notifier
