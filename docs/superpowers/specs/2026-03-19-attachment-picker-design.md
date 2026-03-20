# Attachment Picker (+) Button — Design Spec

**Date**: 2026-03-19
**Scope**: Mobile-only (Android companion app). Desktop `file.transfer` handler is out of scope.

---

## Overview

The modifier bar's (+) button opens a popover with Photos and Files options. Selecting either opens the native Android picker (multi-select). Picked items appear as compact tabs in a horizontal strip above the modifier bar. The user can continue typing, add more attachments, or remove existing ones. On RETURN press, attachments are uploaded to the desktop first, then file paths are pasted into the terminal one-per-line before the user's message text.

---

## User Flow

1. **Tap (+)** → existing spring-animated popover shows "Photos" and "Files"
2. **Tap "Photos"** → native Android gallery picker opens (multi-select enabled)
   **Tap "Files"** → native Android file picker opens (multi-select enabled)
3. **On selection** → selected items appear as compact attachment tabs in a horizontal strip above the modifier bar
   - Each tab: small thumbnail (28px, rounded) + truncated filename (JetBrains Mono 10px) + (X) remove button
   - Horizontally scrollable if items exceed screen width
   - User can add more files via (+), remove via (X), or type their message
4. **User presses RETURN** (modifier bar button OR keyboard Enter):
   a. Upload state shown — attachment strip pulses with "Uploading N files..." message, RETURN shows spinner
   b. Files transferred to desktop inbox one-by-one via `file.transfer` bridge RPC (stubbed for now)
   c. Desktop returns inbox path for each file (e.g., `~/.cmux/inbox/photo.jpg`)
   d. All paths pasted into terminal, one per line, BEFORE the user's message text
   e. Message text sent after paths
   f. Attachment tabs cleared, UI returns to normal
5. **If no attachments** → RETURN works as normal (sends `\r`)

---

## Attachment Tab Strip

### Position & Layout
- **Location**: horizontal row above the modifier bar, overlaying the bottom of the terminal view (not displacing it). Uses a `Stack` so the terminal content is not resized.
- **Height**: ~44px (compact)
- **Background**: matches modifier bar aesthetic — semi-transparent dark with backdrop blur
- **Horizontal scroll**: `ListView` with horizontal axis, clips at screen edges
- **Visibility**: only visible when attachments are pending (animated slide-up/slide-down)

### Individual Tab Appearance
- **Thumbnail**: 28px square, rounded corners (4px radius)
  - Images: actual image thumbnail (from file bytes)
  - Non-image files: file type icon (document, folder, etc.)
- **Filename**: JetBrains Mono 10px, truncated with ellipsis, max ~80px width
- **Remove button**: 16px (X) icon, positioned at top-right of tab
- **Tab container**: pill/capsule shape, ~36px tall, padding 4px, background `keyGroupResting` color
- **Spacing**: 6px gap between tabs, 8px horizontal padding at strip edges

### State Management
- Attachment list managed by `AttachmentService` (new Riverpod StateNotifier)
- Each attachment: `{id, filename, filePath, mimeType, thumbnailBytes}`
  - `filePath` is the local Android path; raw bytes are read on-demand during upload (not held in memory)
  - `thumbnailBytes` is a small thumbnail generated at pick time for display only (~5KB)
- State exposed as `AttachmentState` with list of `AttachmentItem`s
- Duplicates: if the same file path is picked again, it is silently ignored (no duplicate tabs)

### Limits
- **Max file size**: 50MB per file. Files exceeding this show an error toast and are not added.
- **Max attachments**: 10 files at once. Picker is disabled (grayed out) when limit reached.
- **Thumbnails**: generated at pick time as small JPEG (~5KB), not from full file bytes in memory.

---

## Upload Flow (RETURN Press with Attachments)

### Sequence
```
User presses RETURN (button or keyboard Enter)
  ↓
Check: attachments.isNotEmpty?
  ↓ yes
Disable input, show upload state
  ↓
For each attachment:
  Read file bytes from local path, base64-encode
  Send file.transfer RPC → {filename, data (base64), mime_type}
  Receive → {inbox_path: "~/.cmux/inbox/filename"}
  ↓
All succeeded? If any failed → show error, keep failed tabs, stop here.
  ↓
Collect all inbox paths
  ↓
Build payload string:
  "path1\npath2\n...pathN\n"
  ↓
Send payload via _onPaste() → bracketed paste mode → single surface.pty.write call
Then send \r via _sendInput() → submits the line (paths + whatever user already typed)
  ↓
Clear attachments, restore normal state
```

### Upload State UI
- Attachment strip: subtle blue pulse animation on all tabs
- Status text: "Uploading 3 files..." (JetBrains Mono 10px, centered in strip)
- RETURN button: replaces "RETURN" label with a small circular progress indicator
- All input disabled: modifier keys, keyboard, (+) button grayed out

### Error Handling
- **Partial success**: tabs for successfully uploaded files are removed, failed ones remain with a red error indicator. Error toast shows "Failed to send photo.jpg". Successfully uploaded paths are NOT pasted yet — the message is only sent when ALL attachments succeed.
- **Retry**: user can tap RETURN again to retry only the remaining (failed) attachments.
- **Timeout**: 30 second per-file timeout, treat as failure.
- **Connection loss during upload**: cancel the in-progress upload, show error toast "Connection lost", keep all remaining tabs. Successfully transferred files remain on the desktop inbox (idempotent). User retries after reconnection — duplicate files on desktop are acceptable (overwritten by filename).
- **Cancel all**: long-press the (+) button clears all pending attachments.

---

## RETURN Interception

Both RETURN paths must be intercepted:

### Modifier Bar RETURN Button
- In `modifier_bar.dart`, the `_ReturnKey` `onTap` callback must check attachment state
- If attachments exist → trigger upload flow instead of sending `\r`

### Keyboard Enter Key
- In `terminal_view.dart`, the Enter key handler (`_handleKeyEvent`) must check attachment state
- If attachments exist → trigger upload flow instead of sending `\r`

### Integration Point
- `terminal_screen.dart` orchestrates: it holds the `AttachmentService` provider and defines an `_onSubmit()` method
- `_onSubmit()` checks for attachments, handles upload, then sends the composed message via `_onPaste()`
- Both the modifier bar's `_ReturnKey` and `TerminalView`'s Enter key handler call `_onSubmit()` instead of sending `\r` directly
- `TerminalView` gains a new `onSubmitOverride` callback: when non-null, Enter invokes it instead of the default `\r` send. `terminal_screen.dart` sets this callback only when attachments are pending.

### Message Text
- The "message text" is whatever the user has typed into the terminal since attaching files. Since the terminal sends keystrokes character-by-character (no local buffer), the file paths are pasted first via `_onPaste()`, then a `\r` (Enter) is sent via `_sendInput()` to submit the line. The user's typed characters are already in the terminal's line buffer on the desktop side.

---

## Bridge RPC (Stubbed)

### Request
```json
{
  "id": N,
  "method": "file.transfer",
  "params": {
    "filename": "photo.jpg",
    "data": "<base64-encoded file bytes>",
    "mime_type": "image/jpeg"
  }
}
```

### Response (expected when desktop handler is implemented)
```json
{
  "id": N,
  "ok": true,
  "result": {
    "inbox_path": "~/.cmux/inbox/photo.jpg"
  }
}
```

### Stub Behavior
For now, the mobile app will:
- Still read and base64-encode the file bytes (to exercise the real codepath)
- Simulate a 500ms delay per file (instead of actual WebSocket send)
- Return a synthetic path: `~/.cmux/inbox/{filename}`
- Log a warning that the desktop handler is not yet implemented

---

## Terminal Output Format

When attachments + message are sent, the terminal receives:

```
~/.cmux/inbox/photo1.jpg
~/.cmux/inbox/document.pdf
user's typed message here
```

Each path on its own line (using `\n` newlines within the paste payload), followed by the message text. The entire payload (paths + message) is constructed as a single string and sent via the existing `_onPaste()` method in `terminal_screen.dart`, which wraps it in bracketed paste mode (`\x1b[200~` ... `\x1b[201~`) and sends it as a single `surface.pty.write` call. No trailing `\r` is added — the bracketed paste itself handles the submission.

---

## New Files

| File | Purpose |
|------|---------|
| `attachment_service.dart` | Riverpod StateNotifier managing attachment list (add, remove, clear, upload) |
| `attachment_strip.dart` | Horizontal tab strip widget showing pending attachments above modifier bar |

## Modified Files

| File | Changes |
|------|---------|
| `attachment_button.dart` | Wire Photos → `image_picker`, Files → `file_picker` package; add `ValueChanged<List<AttachmentItem>>` callback; convert to `ConsumerWidget` if needed for Riverpod access |
| `modifier_bar.dart` | Mount attachment strip above bar; intercept RETURN for upload flow |
| `terminal_screen.dart` | Orchestrate attachment state; provide `onSubmit` callback; modify message sending |
| `terminal_view.dart` | Intercept Enter key to check attachment state before sending `\r` |
| `pubspec.yaml` | Add `image_picker` and `file_picker` dependencies |

## New Packages

| Package | Purpose |
|---------|---------|
| `image_picker` | Native Android gallery access (multi-select) |
| `file_picker` | Native Android file system access (multi-select) |

---

## Design Decisions

1. **Staged compose over immediate send**: User explicitly confirmed wanting attachment tabs + compose flow, not instant file transfer. This allows reviewing/removing attachments before sending.

2. **Path paste over base64**: All file types get the same treatment — transferred to inbox, path pasted. This mirrors terminal drag-and-drop behavior. The receiving CLI app handles file interpretation.

3. **Paths before message**: File paths appear on separate lines before the message text. This matches how CLI tools expect file arguments before the prompt/message.

4. **Bracketed paste mode**: The entire payload (paths + message) is wrapped in bracketed paste sequences so the terminal knows it's pasted content, not character-by-character typing.

5. **Mobile-only scope**: Desktop `file.transfer` handler will be implemented separately. Mobile stubs the RPC call with simulated responses for now.

6. **Multi-select for both Photos and Files**: Both pickers support selecting multiple items in a single picker session.
