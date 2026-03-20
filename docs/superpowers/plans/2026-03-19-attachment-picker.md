# Attachment Picker — Implementation Plan

**Date**: 2026-03-19
**Spec**: `docs/superpowers/specs/2026-03-19-attachment-picker-design.md`
**Scope**: Mobile-only. Desktop `file.transfer` handler is NOT part of this plan.

---

## Chunk 1: Add Dependencies + AttachmentService (State Layer)

### Description
Create the `AttachmentService` Riverpod StateNotifier (following the `clipboard_history.dart` pattern) and add the `image_picker` and `file_picker` packages to `pubspec.yaml`.

### Files to Create
- `android-companion/lib/terminal/attachment_service.dart`

### Files to Modify
- `android-companion/pubspec.yaml`

### Specific Changes

**pubspec.yaml** — Add under `dependencies`:
```yaml
image_picker: ^1.1.2
file_picker: ^8.1.6
```

**attachment_service.dart** — New file containing:

1. **`AttachmentItem` data class** with fields:
   - `id` (String, microseconds-since-epoch like `ClipboardItem`)
   - `filename` (String)
   - `filePath` (String — local Android path)
   - `mimeType` (String)
   - `thumbnailBytes` (Uint8List? — small JPEG ~5KB for display)
   - `hasError` (bool, default false — marks failed uploads)
   - `copyWith()` method

2. **`AttachmentState` immutable class** with:
   - `items` (List<AttachmentItem>)
   - `isUploading` (bool, default false)
   - `uploadProgress` (String?, e.g., "Uploading 3 files...")
   - Computed getters: `isNotEmpty`, `hasErrors`, `count`, `isAtLimit` (count >= 10)
   - `copyWith()` method

3. **`AttachmentNotifier extends StateNotifier<AttachmentState>`** with methods:
   - `add(AttachmentItem item)` — appends if not duplicate (by filePath), enforces max 10 limit
   - `addAll(List<AttachmentItem> items)` — batch add with dedup and limit enforcement
   - `remove(String id)` — removes by id
   - `clear()` — clears all attachments
   - `markError(String id)` — sets `hasError = true` on a specific item
   - `clearErrors()` — resets all `hasError` flags
   - `setUploading(bool uploading, {String? progress})` — sets upload state
   - `uploadAll()` — core upload method (owns the upload logic, not terminal_screen):
     - For each item: read file bytes via `compute` (Isolate), base64-encode, call stubbed RPC
     - Returns `List<String>` of inbox paths on success, or throws/returns partial results on failure
     - Uses `compute` for file I/O and base64 encoding to keep UI responsive (50MB files would freeze main thread)
   - `removeSuccessful(Set<String> ids)` — removes items whose IDs are in the set
   - No persistence (attachments are ephemeral, not persisted across sessions)

4. **`attachmentProvider`** — global `StateNotifierProvider<AttachmentNotifier, AttachmentState>`

### Dependencies
None — this is the foundation chunk.

### Verification
- File compiles with no errors (`flutter analyze`)
- `AttachmentItem` and `AttachmentState` constructors work correctly
- `AttachmentNotifier` add/remove/clear/dedup logic is correct
- Max-10 limit is enforced (11th item rejected)
- Duplicate filePath detection works

---

## Chunk 2: Wire AttachmentButton to Native Pickers

### Description
Replace the placeholder `onPhotos` / `onFiles` callbacks in `AttachmentButton` with actual native picker invocations using `image_picker` and `file_picker`. Convert to `ConsumerWidget` for Riverpod access. Generate thumbnails for picked items. Add file-size validation (50MB limit).

### Files to Modify
- `android-companion/lib/terminal/attachment_button.dart`

### Specific Changes

1. **Add imports**: `image_picker`, `file_picker`, `dart:io` (for File), `dart:typed_data`, `flutter_riverpod`, `attachment_service.dart`.

2. **Convert `AttachmentButton` from `StatefulWidget` to `ConsumerStatefulWidget`** so it can read/write the `attachmentProvider`.

3. **Add `onAttachmentsAdded` callback** (optional `VoidCallback?`) so the parent knows items were added.

4. **Add `isDisabled` parameter** (bool) — when true (attachment limit reached), the button is visually grayed out and taps are ignored.

5. **Implement `_onPhotos()` method**:
   - Call `ImagePicker().pickMultiImage(limit: remainingSlots)` where `remainingSlots = 10 - currentCount`
   - For each picked `XFile`:
     - Check file size via `File(xfile.path).lengthSync()` — skip if > 50MB, show error toast
     - Generate thumbnail: read bytes, decode with `instantiateImageCodec`, resize to ~56px wide, encode as JPEG
     - Create `AttachmentItem(filename, filePath, mimeType, thumbnailBytes)`
   - Call `notifier.addAll(items)`

6. **Implement `_onFiles()` method**:
   - Call `FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any)`
   - For each `PlatformFile`:
     - Check file size — skip if > 50MB, show error toast
     - Generate thumbnail: for images, same as above; for non-images, set `thumbnailBytes = null`
     - Create `AttachmentItem(filename, filePath, mimeType, thumbnailBytes)`
   - Call `notifier.addAll(items)`

7. **Wire `_ActionSheet`**: `onPhotos` calls `_onPhotos()` then `_closeSheet()`, `onFiles` calls `_onFiles()` then `_closeSheet()`.

8. **Add long-press on (+) button** to clear all attachments (spec: "long-press the (+) button clears all pending attachments").

9. **Determine MIME type**: use file extension mapping (a simple switch/map for common types: jpg, png, gif, mp4, pdf, txt, etc., default `application/octet-stream`).

### Dependencies
- Chunk 1 (AttachmentService must exist)

### Verification
- Tapping Photos opens the Android gallery picker with multi-select
- Tapping Files opens the Android file picker with multi-select
- Picked files appear in `attachmentProvider` state (verify via debug print)
- Files > 50MB are rejected with a toast/snackbar
- Duplicate files (same path) are silently ignored
- Long-press on (+) clears all attachments
- Button is grayed out when 10 attachments are already staged

---

## Chunk 3: Attachment Strip Widget

### Description
Create the `AttachmentStrip` widget — a horizontal scrollable row of compact attachment tabs that slides up above the modifier bar when attachments are pending.

### Files to Create
- `android-companion/lib/terminal/attachment_strip.dart`

### Specific Changes

**attachment_strip.dart** — New file containing:

1. **`AttachmentStrip` widget** (ConsumerWidget or StatelessWidget receiving state as params):
   - **Inputs**: `AttachmentState state`, `VoidCallback? onRemove(String id)`
   - **Layout**: `AnimatedSlide` + `AnimatedOpacity` for slide-up/down entry/exit
   - **Container**: 44px height, semi-transparent dark background matching modifier bar aesthetic (`modifierBarBg` color token), with `BackdropFilter` blur
   - **Content**: horizontal `ListView.builder` with `scrollDirection: Axis.horizontal`
   - **Padding**: 8px horizontal at strip edges, 6px gap between tabs

2. **`_AttachmentTab` widget** (private, per-item):
   - **Container**: pill/capsule shape, ~36px tall, `keyGroupResting` background, 4px padding
   - **Thumbnail**: 28px square, 4px border radius
     - If `thumbnailBytes != null`: `Image.memory(thumbnailBytes, width: 28, height: 28, fit: BoxFit.cover)`
     - If `thumbnailBytes == null`: file type icon (Icons.description_outlined) in 28px box
   - **Filename**: `Text` with JetBrains Mono 10px, `TextOverflow.ellipsis`, max width ~80px via `ConstrainedBox`
   - **Remove (X) button**: 16px `Icons.close_rounded` icon at top-right of tab, positioned via `Stack` or `Row` — taps call `onRemove(item.id)`
   - **Error state**: if `item.hasError`, add a red tint/border to the tab

3. **Upload state overlay**:
   - When `state.isUploading`:
     - All tabs get a subtle blue pulse animation (use `AnimatedContainer` with a repeating color tween on the tab background)
     - A centered status text replaces the tab row: "Uploading 3 files..." in JetBrains Mono 10px
   - Tabs are still visible behind the overlay text (semi-transparent)

### Dependencies
- Chunk 1 (AttachmentState and AttachmentItem types)

### Verification
- Strip appears (slides up) when attachments list is non-empty
- Strip disappears (slides down) when attachments are cleared
- Each tab shows thumbnail + truncated filename + (X) button
- Tapping (X) removes the attachment
- Strip scrolls horizontally when tabs exceed screen width
- Upload state shows pulsing animation and status text
- Error tabs have a red indicator

---

## Chunk 4: Mount Attachment Strip in Terminal Screen

### Description
Integrate the `AttachmentStrip` into the terminal screen layout, positioned above the modifier bar using a `Stack` so it overlays the bottom of the terminal view without displacing it.

### Files to Modify
- `android-companion/lib/terminal/terminal_screen.dart`

### Specific Changes

1. **Add import** for `attachment_service.dart` and `attachment_strip.dart`.

2. **Watch `attachmentProvider`** in the `build()` method to get current `AttachmentState`.

3. **Restructure the bottom of the `Column`** to use a `Stack` or `Column` arrangement:
   - The modifier bar and attachment strip are wrapped together. The attachment strip sits directly above the modifier bar.
   - Use a `Column` within the bottom area:
     ```
     AttachmentStrip(...)   // only shown when attachments.isNotEmpty
     ModifierBar(...)
     ```
   - The `AttachmentStrip` is wrapped in `AnimatedSize` or conditional rendering with slide animation.

4. **Pass callbacks to `AttachmentStrip`**:
   - `onRemove: (id) => ref.read(attachmentProvider.notifier).remove(id)`

5. **Pass `isDisabled` to `AttachmentButton`** (via ModifierBar) when attachment limit is reached:
   - This requires threading the `isAtLimit` flag through to the button.

### Dependencies
- Chunk 1 (AttachmentService provider)
- Chunk 3 (AttachmentStrip widget)

### Verification
- Attachment strip appears above modifier bar when files are picked
- Strip disappears when all attachments are removed
- Terminal view is NOT resized/displaced — strip overlays the bottom
- Removing an attachment via (X) updates the strip immediately
- (+) button grays out when 10 attachments are staged

---

## Chunk 5: Upload Flow + RETURN Interception

### Description
Implement the core upload flow: intercept RETURN (both modifier bar button and keyboard Enter), read file bytes, call the stubbed `file.transfer` RPC, compose the path payload, and paste it into the terminal.

### Files to Modify
- `android-companion/lib/terminal/terminal_screen.dart`
- `android-companion/lib/terminal/modifier_bar.dart`
- `android-companion/lib/terminal/terminal_view.dart`

### Specific Changes

**terminal_screen.dart**:

1. **Add `_onSubmit()` method** — the central submit handler:
   ```
   Future<void> _onSubmit() async:
     - Read attachmentProvider state
     - If empty → send '\r' via _sendInput() (normal Enter)
     - If not empty:
       a. Call notifier.uploadAll() — upload logic lives on the service (not here)
       b. On success: collect inbox paths, build payload, call _onPaste(), clear attachments
       c. On failure: service handles marking errors; show toast here
   ```
   The upload logic (file I/O, base64 encoding, RPC calls) lives on `AttachmentNotifier.uploadAll()`, not here. This method orchestrates the UI response.

2. **Modify ModifierBar instantiation**: replace the inline `onInput('\r')` on RETURN with a new `onSubmit` callback.

4. **Add `onSubmitOverride` callback to `TerminalView`**: a `VoidCallback?` that, when non-null, is called instead of sending `\r` when Enter is pressed. Set this callback in `terminal_screen.dart` only when attachments are pending.

**modifier_bar.dart**:

1. **Add `onSubmit` parameter** to `ModifierBar` (VoidCallback).
2. **Add `isUploading` parameter** to `ModifierBar` (bool).
3. **Modify `_ReturnKey`**:
   - Accept `isUploading` bool
   - When `isUploading`: replace "RETURN" text with a small `SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))` spinner
   - The `onTap` callback now calls `widget.onSubmit` instead of `widget.onInput('\r')`
4. **When `isUploading`**: disable all modifier keys, (+) button, keyboard button (gray them out, ignore taps). Add an `isInputDisabled` parameter that propagates to child widgets.

**terminal_view.dart**:

1. **Add `onSubmitOverride` callback** (`VoidCallback?`) to `TerminalView` constructor.
2. **In `_handleKeyEvent`**: when `key == LogicalKeyboardKey.enter` and `widget.onSubmitOverride != null`, call `widget.onSubmitOverride!()` instead of `_sendInput('\r')`.
3. **In `_onTextChanged`**: when newline is detected and `widget.onSubmitOverride != null`, call `widget.onSubmitOverride!()` instead of sending `\r`.

### Dependencies
- Chunk 1 (AttachmentService)
- Chunk 2 (Picker wiring — so files can be staged)
- Chunk 3 (AttachmentStrip — for visual feedback)
- Chunk 4 (Strip mounted in screen)

### Verification
- With no attachments: RETURN (button and keyboard) sends `\r` as before — no regression
- With attachments staged:
  - RETURN triggers upload flow
  - RETURN button shows spinner during upload
  - All input is disabled during upload
  - After upload completes: paths are pasted into terminal via bracketed paste
  - Attachment strip is cleared
  - Debug log shows the stub warning message
  - File bytes are actually read and base64-encoded (verify via debug print of base64 length)

---

## Chunk 6: Error Handling + Retry + Cancel

### Description
Implement the error handling, retry, and cancel behaviors described in the spec.

### Files to Modify
- `android-companion/lib/terminal/terminal_screen.dart`
- `android-companion/lib/terminal/attachment_strip.dart`
- `android-companion/lib/terminal/attachment_service.dart`

### Specific Changes

**terminal_screen.dart**:

1. **Partial failure handling in `_onSubmit()`**:
   - Track which items succeeded vs failed
   - On partial failure: remove successful items from state, keep failed ones with `hasError = true`
   - Show error toast via `ScaffoldMessenger`: "Failed to send photo.jpg"
   - Do NOT paste any paths on partial failure — all-or-nothing

2. **Retry behavior**: when RETURN is pressed again with remaining error items, `_onSubmit()` clears errors first and retries only those items.

3. **Per-file timeout**: wrap each file transfer call in `.timeout(Duration(seconds: 30))`, catch `TimeoutException`, treat as failure.

4. **Connection loss during upload**: catch WebSocket/connection errors during upload. Show toast "Connection lost". Keep all remaining tabs. Mark in-progress item as error.

**attachment_service.dart**:

1. **Add `removeSuccessful(Set<String> ids)` method** — removes items whose IDs are in the set (for partial success cleanup).
2. **Add `errorItems` getter** — returns only items with `hasError == true`.
3. **Add `retryableItems` getter** — alias for `errorItems` (for clarity at call sites).

**attachment_strip.dart**:

1. **Error indicator on tabs**: when `item.hasError`, apply a red border (`Colors.red.withAlpha(128)`) and a small red dot badge.
2. **Ensure error tabs are visually distinct** from normal tabs.

### Dependencies
- Chunk 5 (Upload flow must exist to add error handling)

### Verification
- Simulate failure (e.g., by modifying stub to fail on specific filenames): failed tabs remain with red indicator
- Tapping RETURN again retries only failed items
- Toast message appears on failure with the failed filename
- 30-second timeout per file works (can test by increasing stub delay)
- Connection loss during upload keeps tabs and shows toast

---

## Chunk 7: Design Tokens + Visual Polish

### Description
Add any missing color tokens for the attachment feature and ensure visual consistency with the spec. Add the blue pulse upload animation.

### Files to Modify
- `android-companion/lib/app/colors.dart`
- `android-companion/lib/terminal/attachment_strip.dart`

### Specific Changes

**colors.dart**:

1. **Add tokens** to both dark and light `AppColorScheme`:
   - `attachmentStripBg` — matches `modifierBarBg` (can reuse, but having a dedicated token allows independent tuning)
   - `attachmentTabBg` — `keyGroupResting` (reuse)
   - `attachmentTabError` — red error border/tint
   - `attachmentUploadPulse` — subtle blue for upload pulse animation
   - `attachmentStatusText` — text color for "Uploading N files..." status

2. **Update `AppColorScheme` constructor** with the new fields.

**attachment_strip.dart**:

1. **Upload pulse animation**: use `AnimationController` with `repeat(reverse: true)` to oscillate tab background opacity between normal and the `attachmentUploadPulse` color. Apply via `ColorTween`.

2. **Slide animation**: `AnimatedSlide` with `offset: Offset(0, state.isNotEmpty ? 0 : 1)` for smooth entry/exit of the strip.

### Dependencies
- Chunk 3 (AttachmentStrip must exist)
- Chunk 6 (Error states must be wired)

### Verification
- Upload pulse animation is smooth and subtle
- Strip slides up/down smoothly
- Colors match the modifier bar aesthetic in both dark and light themes
- Error tabs have a distinct red indicator visible in both themes

---

## Summary

| Chunk | Title | New Files | Modified Files | Depends On |
|-------|-------|-----------|----------------|------------|
| 1 | State Layer | `attachment_service.dart` | `pubspec.yaml` | — |
| 2 | Native Pickers | — | `attachment_button.dart` | 1 |
| 3 | Strip Widget | `attachment_strip.dart` | — | 1 |
| 4 | Mount Strip | — | `terminal_screen.dart` | 1, 3 |
| 5 | Upload + RETURN | — | `terminal_screen.dart`, `modifier_bar.dart`, `terminal_view.dart` | 1-4 |
| 6 | Error + Retry | — | `terminal_screen.dart`, `attachment_strip.dart`, `attachment_service.dart` | 5 |
| 7 | Visual Polish | — | `colors.dart`, `attachment_strip.dart` | 3, 6 |

### Key Patterns Followed
- **Riverpod StateNotifier**: same pattern as `ClipboardHistoryNotifier` / `clipboardHistoryProvider`
- **Widget structure**: `ConsumerStatefulWidget` for widgets needing Riverpod + animation controllers
- **Color tokens**: all colors via `AppColors.of(context)`, new tokens added to both dark/light schemes
- **Callbacks**: parent-owned callbacks passed down (same as `onInput`, `onPaste` pattern in ModifierBar)
- **No persistence**: attachments are ephemeral (unlike clipboard history which persists via SharedPreferences)
- **Font**: JetBrains Mono for all text (matches existing terminal UI)
- **Haptics**: `HapticFeedback.lightImpact()` on interactive elements (matches existing pattern)
- **Compute isolates**: file I/O and base64 encoding run in isolates via `compute()` to avoid UI freezes on large files (up to 50MB)

### Out of Scope (Explicit)
- Desktop `file.transfer` RPC handler — mobile stubs it with 500ms delay + synthetic path
- Persistence of attachments across sessions
- Drag-and-drop reordering of attachment tabs
