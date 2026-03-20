# Pane Attention Notifications

**Date:** 2026-03-19
**Status:** Approved

## Overview

When a terminal pane requires attention (bell signal, output activity change), cmux sends notifications on both the desktop (macOS dock badge + sound) and the Android companion app (system push notification + in-app badge). This enables users to monitor long-running tasks and respond promptly to tools waiting for input (e.g., Claude Code permission prompts, build completions).

## Triggers

### 1. Terminal Bell (`\x07`)

Immediate attention trigger. When a program sends the bell character, attention fires right away (bypasses the silence timer). Common sources: shell completion alerts, build tools, `tput bel`.

### 2. Output Silence Heuristic

An unfocused pane was actively producing output, then output stops for `silence_threshold` seconds (default: 30s). This catches the "tool is waiting for input" case — e.g., Claude Code printed a permission prompt and is now blocked on stdin.

### 3. Output Activity Heuristic

An unfocused pane was idle for ≥ `idle_threshold` seconds (default: 5s), then starts producing output. This catches the "something started happening" case — e.g., a CI job kicked off, a long build began.

## State Machine

Each terminal surface has an independent activity tracker managed by `SurfaceActivityTracker`. Focused panes are exempt — no tracking or notifications while the user is actively viewing the pane.

```
          output received (after idle_threshold)
  IDLE ──────────────────────────────────────────► ACTIVE
   ▲                                                  │
   │                                                  │ no output for silence_threshold
   │                                                  ▼
   │                                          SILENT_AFTER_ACTIVE
   │                                                  │
   └──────────────── cooldown ────────────────────────┘
```

### State Transitions

| From | To | Condition | Action |
|---|---|---|---|
| IDLE | ACTIVE (silent) | Output received AND pane was idle < `idle_threshold` | Start silence timer, **no** attention fired (pane was already busy when unfocused) |
| IDLE | ACTIVE | Output received AND pane was idle ≥ `idle_threshold` AND pane is unfocused | Fire "activity" attention, start silence timer |
| ACTIVE | ACTIVE | Output received | Reset silence timer |
| ACTIVE | SILENT_AFTER_ACTIVE | No output for `silence_threshold` AND pane is unfocused | Fire "silence" attention |
| SILENT_AFTER_ACTIVE | IDLE | After cooldown period | Ready for next attention cycle |
| Any | IDLE | Pane becomes focused | Cancel all timers, reset state |
| Any | IDLE | Surface moved between panes | Transfer state to new pane context, keep timers running |

**App focus**: When the entire cmux application loses focus (user switches to another app), all unfocused panes are eligible for tracking. The existing `AppFocusState.isAppFocused()` check applies: attention notifications are always added to the store, but sound and dock badge only fire when the app is not focused (matching existing notification store behavior).

### Bell Override

Bell (`\x07`) is an immediate attention trigger that bypasses the state machine. It fires regardless of current state, subject to a **5-second bell cooldown** (separate from the general cooldown) to prevent rapid bell spam from programs that emit repeated `\x07`.

**Surface identity for bell**: Bell attention fires from the surface-target code path in `GhosttyTerminalView.swift` (the `GHOSTTY_ACTION_RING_BELL` handler where `surfaceView` is in scope). The app-target bell handler (no surface context) does **not** trigger attention — it only handles sound and dock bounce as before.

### Cooldown

After any attention notification fires for a surface, further notifications for that surface are suppressed for `cooldown` seconds (default: 60s). This prevents notification spam from chatty processes. Bell has its own separate 5-second cooldown that runs independently of the general cooldown.

### Interaction with Standard Desktop Notifications

Attention notifications and standard desktop notifications (from `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` / OSC 777) are independent systems. A pane can fire both types in quick succession. This is intentional: they serve different purposes (automatic detection vs. explicit program notification).

## Desktop Notification Behavior

### Subtle Mode (v1)

- **Dock badge**: Increment unread attention count on the dock icon
- **Sound**: Play configured notification sound (reuses existing `TerminalNotificationStore` sound settings)
- **No macOS banner**: No `UNUserNotificationCenter` banner notification. Subtle by design.
- **Pane tab indicator**: The pane's tab in the UI gets a visual attention dot/highlight so the user can see which pane triggered

### Integration with Existing Notification Store

Attention notifications use a **separate code path** from standard notifications to avoid triggering macOS banners. Specifically:

- A new `addAttentionNotification(tabId:, surfaceId:, reason:, title:)` method is added to `TerminalNotificationStore`
- This method adds to the `notifications` array (for unread count and dock badge) but **does not** call `scheduleUserNotification` (which would create a `UNUserNotificationCenter` banner)
- Sound is played directly via the existing sound infrastructure, bypassing `UNNotificationSound`
- The `TerminalNotification` struct gets a new `kind` field: `.standard` (existing behavior) vs `.attention` (badge + sound only)

### Clearing Attention State

"Viewing the pane" means the surface becomes the focused surface within its split pane (i.e., the Bonsplit pane receives focus AND this surface is the selected tab within that pane). Simply selecting the workspace is not sufficient — the specific surface must gain focus. This maps to `markRead(tabId:, surfaceId:)` on `TerminalNotificationStore`.

## Android Companion Notification

### Bridge Event

A new bridge event `surface.attention` is emitted when attention triggers:

```json
{
  "type": "event",
  "event": "surface.attention",
  "data": {
    "workspace_id": "<UUID string — Tab.id, same as tabId in other bridge events>",
    "surface_id": "<UUID string — TerminalSurface.id>",
    "pane_id": "<String — Bonsplit pane identifier, same as BridgeNotificationKey.paneId>",
    "reason": "bell|silence|activity",
    "surface_title": "vim ~/project/main.rs"
  },
  "timestamp": "2026-03-19T14:32:00Z"
}
```

All IDs use the same types as existing bridge events (`workspace.selected`, `pane.focused`, etc.).

### System Notification

- Android system notification via Flutter local notifications plugin
- Appears in notification shade even when the companion app is backgrounded (requires active WebSocket connection)
- Vibration enabled
- Notification title: workspace name
- Notification body: `"[pane title] — [reason description]"` (e.g., "vim ~/project — Output stopped (may need input)")

### In-App State

- Workspace badge: increment attention count
- Pane highlight: visual indicator on the affected pane in the companion UI
- Tapping the system notification opens the companion app and navigates to the relevant workspace/pane

### Limitation (v1)

Android notifications only work while the WebSocket bridge connection is active. If the companion app is fully killed by the OS or Tailscale is disconnected, no notification is delivered. FCM-based push notifications can be added in a future version.

## Configuration (v1: Global Only)

All thresholds are global in v1. Per-pane overrides are deferred to a future version.

| Setting | Default | Unit | Description |
|---|---|---|---|
| `attention.enabled` | `true` | bool | Master toggle for attention tracking |
| `attention.silence_threshold` | `30` | seconds | How long after output stops before "waiting" attention fires |
| `attention.idle_threshold` | `5` | seconds | How long a pane must be idle before "woke up" attention fires |
| `attention.cooldown` | `60` | seconds | Suppress repeat notifications for a surface after firing |
| `attention.bell_cooldown` | `5` | seconds | Suppress repeat bell attention for a surface (separate from general cooldown) |

### Configuration Hot-Reload

When configuration values change at runtime (via CLI or socket API), changes take effect on the **next state transition**. Active timers are not cancelled mid-flight — they complete with the value they were started with. New timers use the updated values.

### Configuration Interfaces

- **cmux config file**: Set defaults in the cmux configuration
- **CLI**: `cmux attention [enable|disable]`, `cmux attention config --silence-threshold 10`
- **Socket V2 API**: `attention.configure { enabled, silence_threshold, idle_threshold, cooldown }`
- **Socket V2 API**: `attention.status` — returns current config and per-surface states:

```json
{
  "config": {
    "enabled": true,
    "silence_threshold": 30,
    "idle_threshold": 5,
    "cooldown": 60,
    "bell_cooldown": 5
  },
  "surfaces": [
    {
      "surface_id": "<UUID>",
      "workspace_id": "<UUID>",
      "state": "idle|active|silent_after_active",
      "last_output_at": "2026-03-19T14:32:00Z",
      "in_cooldown": false
    }
  ]
}
```

## Implementation: Key Files

### New Files

| File | Purpose |
|---|---|
| `Sources/SurfaceActivityTracker.swift` | State machine, per-surface activity tracking, timer management |
| `android-companion/lib/notifications/attention_notification_handler.dart` | Handles `surface.attention` bridge events, triggers system notifications |

### Modified Files

| File | Change |
|---|---|
| `Sources/GhosttyTerminalView.swift` | Hook output detection callback, integrate `ringBell()` with attention system |
| `Sources/Bridge/BridgeEventRelay.swift` | Add observer and emitter for `surface.attention` event |
| `Sources/TerminalNotificationStore.swift` | Add attention notification type (badge + sound, no banner) |
| `Sources/TerminalController.swift` | Add V2 API commands: `attention.configure`, `attention.status` |
| `CLI/cmux.swift` | Add `cmux attention` subcommand |
| `android-companion/lib/state/event_handler.dart` | Route `surface.attention` events to notification handler |
| `android-companion/lib/state/workspace_provider.dart` | Add attention count/state to workspace and surface models |

## Output Detection Mechanism

The output detection hooks into the Ghostty surface's `wakeup_cb` callback, which fires when the terminal has new content to render. Since `wakeup_cb` can fire for reasons beyond output (e.g., cursor blink, resize), the tracker uses a lightweight heuristic: it checks if the surface's content generation counter has incremented since the last wakeup. If no suitable content-change counter exists in the Ghostty API, an alternative approach is to add a small hook in the `read` path of the pty wrapper that posts a notification when bytes are read from the child process.

**Implementation note**: The exact Ghostty API hook point needs investigation during implementation. The spec acknowledges that a thin bridging callback may need to be added to the Ghostty surface wrapper. This should be a single line that posts a timestamp — no content inspection.

### Timer Implementation

Timers use `DispatchSource.makeTimerSource` on a **dedicated serial dispatch queue** (not the main queue, per the project's socket command threading policy). Timer fire callbacks dispatch minimal work (posting a notification) to the main queue via `DispatchQueue.main.async`. Timer scheduling, cancellation, and state machine transitions all happen on the dedicated queue.

## Testing Strategy

- **Unit tests**: `SurfaceActivityTracker` state machine transitions, timer behavior, cooldown logic
- **Integration tests**: Socket V2 API commands (`attention.configure`, `attention.status`)
- **CLI tests**: `cmux attention` subcommand parsing
- **Manual validation**: Trigger bell in a background pane, verify dock badge + sound + Android notification
