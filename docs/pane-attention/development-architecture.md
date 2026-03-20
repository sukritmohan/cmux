# Pane Attention Notifications — Development Architecture

## Architecture Overview

Pane attention is a desktop-side tracking system that observes terminal surface output cadence and fires notifications through two channels: the existing desktop notification store and the Android companion bridge.

```
Terminal Surface (Ghostty)
    │ output callback (timestamp only)
    ▼
SurfaceActivityTracker (per-surface state machine)
    │ attention trigger
    ├──► TerminalNotificationStore (dock badge + sound)
    └──► BridgeEventRelay (surface.attention event)
                │
                ▼
         Android Companion (system notification + in-app badge)
```

## Key Components

### SurfaceActivityTracker (`Sources/SurfaceActivityTracker.swift`)

New class. Manages per-surface activity state machines.

- **Responsibility**: Track output timestamps per surface, run silence/idle timers, fire attention notifications
- **State**: Dictionary of `[SurfaceID: SurfaceActivityState]` where state includes current FSM state, last output timestamp, active timers
- **Threading**: Timer callbacks dispatch attention notifications on main queue (minimal work: just posting a notification)
- **No content inspection**: Only tracks *when* output occurs, never *what* the output contains

### Output Detection Hook (`GhosttyTerminalView.swift`)

The terminal surface wrapper posts a lightweight notification when new content arrives. This hooks into the existing render/content-change path — not a new polling mechanism.

### Bell Integration (`GhosttyTerminalView.swift`)

`ringBell()` additionally calls `SurfaceActivityTracker.triggerBellAttention(surfaceId:)` for immediate attention, bypassing the state machine. Subject to bell-specific cooldown.

### Bridge Event (`BridgeEventRelay.swift`)

New observer for `.surfaceAttention` notification. Emits `surface.attention` event with workspace_id, surface_id, pane_id, reason, and surface_title.

### Android Handler (`attention_notification_handler.dart`)

Receives `surface.attention` bridge events. Shows system notification via Flutter local notifications plugin. Updates workspace/surface provider state for in-app badges.

## Design Decisions

### Why desktop-side tracking (not Ghostty-level)

Tracking at the Swift/cmux layer keeps all notification logic in one place, avoids ghostty submodule changes, and makes configuration straightforward through the existing cmux config system. The output detection hook is a thin timestamp observation — the heavy lifting (timers, state machines, configuration) lives in pure Swift.

### Why no terminal content inspection

Privacy and performance. The tracker only knows *when* output occurs, not *what* it says. This avoids scanning terminal content for patterns (fragile, privacy-sensitive) and keeps the hot path to a single timestamp update.

### Why global config only in v1

Per-pane configuration adds UI surface (how do users set it?), persistence complexity (survive app restarts?), and sync questions (bridge to Android?). Global defaults are sufficient for the core use case. Per-pane can be added later with the socket V2 API already designed for it.

### Why subtle desktop notifications (no banner)

The user chose subtle mode: dock badge + sound. Attention events can be frequent (especially with the activity heuristic), and macOS banners would be disruptive. The pane tab indicator provides at-a-glance identification without interruption.

### Why WebSocket-only for Android (no FCM)

FCM push notifications require a relay server and Firebase project setup. The WebSocket bridge already exists and delivers real-time events. v1 accepts the limitation that Android must be connected. FCM can be layered on later without changing the event model.
