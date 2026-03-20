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

- **Responsibility**: Track output timestamps per surface, run silence check timers, fire attention notifications
- **State**: Dictionary of `[SurfaceID: SurfaceActivityState]` where state includes current FSM state, `lastOutputAt` timestamp, focus state, active timers
- **All panes tracked**: Both focused and unfocused panes are tracked. Focus state only gates notification delivery, not state transitions. This ensures accurate idle/active state is always known when a pane becomes unfocused.
- **Output hot path**: When a surface is active and streaming output, the only per-output work is a single `lastOutputAt = now` timestamp write. No timer manipulation per output event.
- **Silence check**: A fixed-interval polling timer (~5s) fires and checks `now - lastOutputAt >= silenceThreshold`. Created once on IDLE→ACTIVE, cancelled on ACTIVE→SILENT_AFTER_ACTIVE.
- **Threading**: Timers and state transitions run on a dedicated serial dispatch queue. Notification delivery dispatches to main queue via `async`.
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

### Why track all panes (not just unfocused)

If only unfocused panes were tracked, we'd have no baseline when a pane loses focus — was it idle or actively streaming? We'd have to guess (defaulting to IDLE), which produces false "activity" notifications when a user unfocuses a busy pane. Tracking all panes means the state machine always has accurate state. Focus only gates notification delivery.

### Why polling timer instead of per-output timer reset

A streaming terminal can produce hundreds of output events per second. Cancelling and recreating a timer on each event would be wasteful. Instead, the output hot path is a single timestamp write (`lastOutputAt = now`). A fixed-interval polling timer (~5s) independently checks `now - lastOutputAt >= silenceThreshold`. This makes the per-output cost O(1) with negligible overhead regardless of output rate.

### Why no terminal content inspection

Privacy and performance. The tracker only knows *when* output occurs, not *what* it says. This avoids scanning terminal content for patterns (fragile, privacy-sensitive) and keeps the hot path to a single timestamp update.

### Why global config only in v1

Per-pane configuration adds UI surface (how do users set it?), persistence complexity (survive app restarts?), and sync questions (bridge to Android?). Global defaults are sufficient for the core use case. Per-pane can be added later with the socket V2 API already designed for it.

### Why subtle desktop notifications (no banner)

The user chose subtle mode: dock badge + sound. Attention events can be frequent (especially with the activity heuristic), and macOS banners would be disruptive. The pane tab indicator provides at-a-glance identification without interruption.

### Why WebSocket-only for Android (no FCM)

FCM push notifications require a relay server and Firebase project setup. The WebSocket bridge already exists and delivers real-time events. v1 accepts the limitation that Android must be connected. FCM can be layered on later without changing the event model.
