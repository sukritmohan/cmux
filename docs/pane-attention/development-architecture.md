# Pane Attention Notifications — Development Architecture

## v1 Architecture (Simplified)

v1 uses three small wiring changes — no state machines, no PTY observers, no new classes. Attention notifications flow through the existing `TerminalNotificationStore` and bridge event relay.

```
Terminal Bell (Ghostty RING_BELL action)     Claude Code hooks (stop/idle/notification)
    │                                              │
    │ (unfocused pane only)                        │ (already wired via notify_target)
    ▼                                              ▼
TerminalNotificationStore.addNotification()
    │
    ├──► Desktop notification (existing path: dock badge + sound)
    └──► NotificationCenter post (.bridgeSurfaceAttention)
                │
                ▼
         BridgeEventRelay observer #13
                │
                ▼
         surface.attention event → WebSocket → Android Companion
                                                    │
                                                    ├──► System notification (flutter_local_notifications)
                                                    └──► Workspace badge count increment
```

## Key Components

### Bell → Notification (`GhosttyTerminalView.swift`)

The `GHOSTTY_ACTION_RING_BELL` handler (in `performAction`) calls `ringBell()` as before, then also fires `TerminalNotificationStore.shared.addNotification()` — but only when the surface is NOT the focused pane in the active workspace. This avoids notifications for bells the user can already see.

### Claude Code Hooks (`CLI/cmux.swift`)

The `stop`/`idle` hook handler already calls `notify_target` (which routes to `addNotification`). The `notification`/`notify` handler also already calls `notify_target`. No new code was needed — v1 piggybacks on the existing Claude hook notification path.

### Bridge Event Relay (`BridgeEventRelay.swift`)

Observer #13 listens for `.bridgeSurfaceAttention` (posted by `addNotification`) and emits a `surface.attention` event with `workspace_id`, `surface_id`, `reason`, and `title`.

### Notification Store Bridge Post (`TerminalNotificationStore.swift`)

After every `addNotification` call (line ~883), a `NotificationCenter.default.post` fires `.bridgeSurfaceAttention` with the tab/surface IDs and notification title. This ensures ALL notification sources (bell, Claude hooks, `cmux notify` CLI) automatically forward to Android.

### Android Handler (`attention_notification_handler.dart`)

New `AttentionNotificationHandler` singleton. Initializes `flutter_local_notifications` plugin. `showAttention()` displays an Android system notification. Notification ID is a hash of workspace+surface so repeated attention from the same source replaces the previous notification.

### Android Event Routing (`event_handler.dart`)

New `surface.attention` case calls `WorkspaceNotifier.incrementNotificationCount()` for the badge, then `AttentionNotificationHandler.instance.showAttention()` for the system notification.

## Design Decisions

### Why v1 is three changes, not the full state machine

The original plan included `SurfaceActivityTracker` with per-surface state machines, output silence/activity heuristics, and a `cmux attention` CLI. That's deferred to v2. v1 covers the two highest-value triggers (bell and Claude Code idle) with minimal code by piggybacking on existing infrastructure.

### Why post from addNotification (not per call site)

Posting the bridge event inside `addNotification` means every notification source automatically forwards to Android — bell, Claude hooks, `cmux notify` CLI, future sources. Single point of integration, zero per-source wiring.

### Why WebSocket-only for Android (no FCM)

FCM push notifications require a relay server and Firebase project setup. The WebSocket bridge already exists and delivers real-time events. v1 accepts the limitation that Android must be connected. FCM can be layered on later without changing the event model.

### Why no bell cooldown in v1

The existing `TerminalNotificationStore.addNotification` already replaces previous notifications for the same tab+surface (line ~847: `removeAll` matching tab/surface). Rapid bell spam replaces rather than stacks. v2 can add explicit cooldown timers if needed.

## What's Deferred to v2

- `SurfaceActivityTracker` — per-surface state machine for output silence/activity detection
- PTY output timestamp observer
- Per-pane configuration (`AttentionConfiguration`)
- `cmux attention` CLI subcommand
- Notification filtering (subtle mode vs full banner)
- Bell-specific cooldown timer (5s)
- Output silence threshold (30s)
- Output activity threshold (5s)
- Cooldown between repeat notifications (60s)

## Files Modified (v1)

| File | Change |
|---|---|
| `Sources/GhosttyTerminalView.swift` | Bell → addNotification for unfocused panes |
| `Sources/TerminalNotificationStore.swift` | Post `.bridgeSurfaceAttention` after addNotification |
| `Sources/Bridge/BridgeEventRelay.swift` | New notification name, keys, observer #13 |
| `android-companion/lib/notifications/attention_notification_handler.dart` | New: Android notification handler |
| `android-companion/lib/state/event_handler.dart` | Route surface.attention to handler + badge |
| `android-companion/lib/state/workspace_provider.dart` | `incrementNotificationCount()` method |
| `android-companion/lib/main.dart` | Initialize notification handler |
| `android-companion/pubspec.yaml` | Add flutter_local_notifications |
| `android-companion/android/app/src/main/AndroidManifest.xml` | POST_NOTIFICATIONS permission |
