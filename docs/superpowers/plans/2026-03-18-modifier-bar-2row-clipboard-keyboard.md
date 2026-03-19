# Implementation Plan: Modifier Bar 2-Row Layout with Clipboard, Keyboard & Voice

**Date:** 2026-03-18
**Spec:** `docs/superpowers/specs/2026-03-18-modifier-bar-2row-clipboard-keyboard-design.md`
**Source:** Expert council synthesis (Claude + Gemini)

## Executive Summary

Redesign the `ModifierBar` from a single-row horizontal layout to a 2-row layout with three horizontal zones (left tools, center-right stack, right column). Create four new widget files (clipboard button/sheet, keyboard button, voice button, symbol capsule), a clipboard history data model with SharedPreferences persistence, add 13 new color tokens, and rewire TerminalScreen to connect clipboard copy flow and keyboard focus sharing.

## Task Dependency Graph

```
Task 1 (colors) ──┬── Task 4 (symbol capsule) ──────┐
                   ├── Task 5 (keyboard button) ──────┤
                   ├── Task 6 (voice button) ──────────┤
                   └── Task 7 (clipboard button+sheet)─┤
                                                       │
Task 2 (pubspec) ── Task 3 (clipboard data model) ────┤
                                                       │
Task 8 (joystick/return resize) ───────────────────────┤
                                                       │
                                              Task 9 (modifier bar 2-row layout)
                                                       │
                                              Task 10 (wire into terminal screens)
                                                       │
                                              Task 11 (connection-keyed init)
```

**Parallelism:** Tasks 1, 2, 8 can start simultaneously. Tasks 4, 5, 6, 7 can run in parallel after Task 1. Task 3 depends on Task 2. Task 9 is the integration bottleneck. Tasks 10-11 are sequential.

---

## Task 1: Add Color Tokens

**File:** `lib/app/colors.dart`

**Changes:**
- Add 13 new fields to `AppColorScheme` (constructor + field declarations):
  - `clipboardBadge`, `clipboardBadgeBorder`, `clipboardLatestBorder`, `clipboardLatestBadge`
  - `keyboardBtnGradientStart`, `keyboardBtnGradientEnd`, `keyboardBtnBorder`, `keyboardBtnGlow`, `keyboardBtnIcon`
  - `sheetBg`, `sheetHandle`, `sheetSearch`, `sheetSearchBorder`
- Add exact color values from spec to both `AppColors.dark` and `AppColors.light` const instances
- Update existing `joystickBorder` token from `0x14FFFFFF` (0.08) to `0x1AFFFFFF` (0.10) in dark scheme

**Dependencies:** None

**Checkpoint:** Colors compile, no regressions in existing UI.

---

## Task 2: Add `shared_preferences` Dependency

**File:** `pubspec.yaml`

**Changes:**
- Add `shared_preferences: ^2.3.4` under `dependencies`
- Run `flutter pub get`

**Dependencies:** None

---

## Task 3: Create Clipboard History Data Model and Provider

**New file:** `lib/terminal/clipboard_history.dart`

**What to create:**

1. **`ClipboardItem` data class:**
   - `String id` (UUID-based)
   - `String text`
   - `DateTime copiedAt`
   - `bool isStarred`
   - `fromJson` / `toJson` factory methods

2. **`ClipboardHistoryState` immutable class:**
   - `List<ClipboardItem> items` (all items)
   - `String searchQuery`
   - Computed getters: `latestItem`, `starredItems`, `recentItems`
   - `filteredItems(String query)` preserving section grouping
   - `bool get isNotEmpty`

3. **`ClipboardHistoryNotifier extends StateNotifier<ClipboardHistoryState>`:**
   - Constructor takes `String connectionKey` for per-connection persistence
   - `add(String text)` — dedup, enforce 100-item cap, evict oldest unstarred
   - `toggleStar(String id)`
   - `reorderStarred(String id, int newIndex)`
   - `search(String query)` / `clearSearch()`
   - `_save()` / `_load()` — SharedPreferences JSON persistence
   - **Async init pattern:** Constructor initializes empty state, `load()` called imperatively from TerminalScreen (matches `WorkspaceNotifier.fetchWorkspaces()` pattern)

4. **Riverpod provider:**
   ```dart
   final clipboardHistoryProvider =
       StateNotifierProvider<ClipboardHistoryNotifier, ClipboardHistoryState>((ref) {
     return ClipboardHistoryNotifier(connectionKey: 'default');
   });
   ```

**Dependencies:** Task 2

**Checkpoint:** Unit-testable data model with persistence.

---

## Task 4: Create Symbol Capsule (replaces Fan-Out)

**New file:** `lib/terminal/symbol_capsule.dart`

**What to create:**

- `SymbolCapsule` stateless widget: 5 symbols `=`, `~`, `|`, `/`, `-` in a connected capsule group
- Each symbol: 34×34px, JetBrains Mono 15px weight 500, `c.keyGroupText` color
- 1px dividers between symbols (`c.border`)
- Capsule background: `rgba(255,255,255,0.03)`
- Tap fires `onInput(symbol)` with `HapticFeedback.selectionClick()`
- **Critical:** Symbols bypass Ctrl. Use `widget.onInput` directly, NOT the `_onInput` wrapper that auto-releases sticky Ctrl
- Follow `_KeyGroupCapsule` pattern from modifier_bar.dart

**After this task:** Delete `lib/terminal/fan_out_button.dart`

**Dependencies:** Task 1

---

## Task 5: Create Keyboard Toggle Button

**New file:** `lib/terminal/keyboard_button.dart`

**What to create:**

- `KeyboardButton` stateful widget
- Constructor: `required FocusNode keyboardFocusNode`
- Size: 46×34px, border radius 10px
- Background: blue accent `LinearGradient(135deg)` using `c.keyboardBtnGradientStart` → `c.keyboardBtnGradientEnd`
- Border: 1px solid `c.keyboardBtnBorder`, glow: `c.keyboardBtnGlow` blurRadius 12
- Icon: keyboard outline, 18px, `c.keyboardBtnIcon`
- Tap: `focusNode.hasFocus ? focusNode.unfocus() : focusNode.requestFocus()`
- Active state: listen to `focusNode` changes, increase border opacity + glow when active
- Haptic: `HapticFeedback.lightImpact()`
- Semantics: localized "Show keyboard" / "Hide keyboard"

**Dependencies:** Task 1

---

## Task 6: Create Voice Recorder Placeholder

**New file:** `lib/terminal/voice_button.dart`

**What to create:**

- `VoiceButton` stateless widget
- Size: 34×34px circular
- Background: `c.keyGroupResting`, border: `c.joystickBorder`
- Icon: `Icons.mic_none_rounded`, 14px, `c.keyGroupText`
- Tap: no-op or show "Coming soon" SnackBar
- Semantics: localized "Voice recorder, coming soon"

**Dependencies:** Task 1

---

## Task 7: Create Clipboard Button and Bottom Sheet

**New file:** `lib/terminal/clipboard_button.dart`

**What to create:**

### A. `ClipboardButton` widget
- Size: 38×34px, border radius 10px, `c.keyGroupResting` background
- Icon: clipboard with lines (14px, stroked, `c.keyGroupText`)
- Badge: 7px amber dot (`c.clipboardBadge`) + `c.clipboardBadgeBorder`, shown when `history.isNotEmpty`
- Tap: opens `ClipboardHistorySheet` via `showModalBottomSheet`
- Semantics: localized "Clipboard, N items"

### B. `ClipboardHistorySheet` widget
- Covers ~60% of screen, frosted glass background (`c.sheetBg`)
- Handle: 36×4px pill, `c.sheetHandle`
- Header: "Clipboard" (13px, weight 700) + item count
- Search bar: TextField, `c.sheetSearch` bg, `c.sheetSearchBorder` border, 200ms debounce
- Three sections via `ListView.builder`:
  - **Latest:** blue left border (2px, `c.clipboardLatestBorder`), "just copied" badge (`c.clipboardLatestBadge`)
  - **Starred:** filled amber stars, user-reorderable
  - **Recent:** chronological unstarred items
- Each item: monospace text (12px, ellipsis) + metadata (9px) + star toggle (14px)
- Tap item: paste via bracketed paste mode (`\x1b[200~$text\x1b[201~`), dismiss sheet
- Tap star: `notifier.toggleStar(id)`
- Empty state: centered icon + "No clipboard history" + subtitle
- No results: centered "No matches"

**Dependencies:** Tasks 1, 3

**Checkpoint:** Bottom sheet renders with mock data.

---

## Task 8: Resize Joystick and Compact Return Key

**Files:**
- `lib/terminal/joystick_button.dart` — change width/height from 40 to 50
- `lib/terminal/modifier_bar.dart` (`_ReturnKey`) — width 50px (fixed), height 22px, font 8px weight 700, border radius 8px

**Dependencies:** None (parallel with Tasks 4-7)

---

## Task 9: Rewrite ModifierBar to 2-Row Layout

**File:** `lib/terminal/modifier_bar.dart`

**Constructor changes:**
- Add `ClipboardHistoryNotifier clipboardHistory` (or use `Consumer`)
- Add `FocusNode keyboardFocusNode`
- Add `ValueChanged<String> onPaste` callback (bracketed paste)
- Keep existing `onInput`, `ctrlActiveNotifier`

**New layout structure:**
```
Container (height: 86, borderRadius: 18, frosted glass)
  Row(
    // Left zone: 2-row Column (flex: 1)
    Expanded(
      Column(
        Row 1: [EscTabCtrl] [divider] [ClipboardButton] [Spacer]
        Row 2: [SymbolCapsule] [Spacer]
      )
    ),
    // Center-right: vertically centered Column
    Column(
      mainAxisAlignment: center,
      [VoiceButton]
      [SizedBox(height: 4)]
      [KeyboardButton]
    ),
    // Vertical divider (1px × 56px, centered)
    Container(width: 1, height: 56, ...)
    // Right column: vertically centered Column
    Column(
      mainAxisAlignment: center,
      [JoystickButton 50×50]
      [SizedBox(height: 4)]
      [ReturnKey 50×22]
    ),
  )
```

**Critical detail:** `SymbolCapsule` must use `widget.onInput` directly (bypass Ctrl auto-release), not `_onInput`.

**Remove:** Import of `fan_out_button.dart`, replace `FanOutButton` with `SymbolCapsule`.

**Dependencies:** Tasks 4, 5, 6, 7, 8

**Checkpoint:** App compiles, 2-row layout renders correctly.

---

## Task 10: Wire Clipboard and Keyboard into TerminalScreen/TerminalView

**Files:**
- `lib/terminal/terminal_screen.dart`
- `lib/terminal/terminal_view.dart`

**TerminalScreen changes:**
- Create a `FocusNode` for keyboard toggle, pass to both `TerminalView` and `ModifierBar`
- Read `clipboardHistoryProvider` via Riverpod
- Add `_onPaste(String text)` that sends `\x1b[200~$text\x1b[201~` via `_sendInput`
- Pass `onPaste` and `clipboardHistory` to `ModifierBar`

**TerminalView changes:**
- Accept `FocusNode` as constructor parameter (replacing internally created one)
- Attach `onKeyEvent` handler to the externally-provided FocusNode
- In `_copySelection()`, after `Clipboard.setData(...)`, call `ref.read(clipboardHistoryProvider.notifier).add(text)` to record in clipboard history

**Dependencies:** Tasks 3, 9

---

## Task 11: Connection-Keyed Clipboard Init

**Files:**
- `lib/terminal/clipboard_history.dart`
- `lib/terminal/terminal_screen.dart`

**Changes:**
- After loading pairing credentials in `TerminalScreen._initConnection()`, reinitialize `ClipboardHistoryNotifier` with the connection's `host` as the key
- Use a Riverpod family provider: `clipboardHistoryProvider.family<String>` with host parameter, OR override the default provider with the correct key during init
- Call `notifier.load()` to async-load persisted history

**Dependencies:** Task 10

**Checkpoint:** Clipboard history persists across app restarts, isolated per connection.

---

## Cleanup

After all tasks complete:
- Delete `lib/terminal/fan_out_button.dart`
- Remove any unused imports
- Verify both dark and light themes render correctly

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| FocusNode sharing between TerminalView and KeyboardButton | Medium — changing TerminalView's internal FocusNode to external | Accept FocusNode as constructor param, attach `onKeyEvent` in initState |
| SharedPreferences async load | Low — constructor can't await | Init with empty state, call `load()` imperatively from TerminalScreen (matches existing patterns) |
| Bar height increase (50→86px) | Medium — reduces terminal rows on small phones | Monitor during testing, acceptable trade-off per user approval |
| Symbol capsule Ctrl bypass | Low but subtle — symbols must NOT auto-release Ctrl | Use `widget.onInput` directly, add code comment explaining why |
| Clipboard bottom sheet focus conflict | Low — modal sheet creates route barrier | `showModalBottomSheet` handles focus trapping automatically |
