# Pane Attention Notifications — UX Behavior Expectations

## Core Behavior

When a terminal pane that the user is NOT looking at requires attention, cmux alerts them on both desktop and their Android companion device.

### What Triggers Attention (v1)

1. **Terminal bell** — Immediate. Any program sending `\x07` triggers attention right away, but only for unfocused panes.
2. **Claude Code idle/stop** — When Claude Code finishes a turn and is waiting for input, a notification fires via the existing Claude hook handler.
3. **Claude Code notification** — When Claude Code explicitly requests attention (e.g., asking for approval), the notification hook fires.

### What the User Sees

**Desktop:**
- Dock badge increments (shows unread attention count)
- Configured sound plays
- The pane's tab gets a visual attention dot/highlight
- No macOS notification banner (intentionally subtle)
- Focusing the specific surface within its split pane clears its attention state (selecting the workspace alone is not enough — the surface must gain focus)

**Android companion:**
- System notification in the notification shade
- Notification title = workspace/pane title, body = reason description
- In-app: workspace badge count increments
- Repeated attention from the same surface replaces the previous notification (no stacking)

### What the User Does NOT See

- No notification for focused panes (you're already looking at it)
- No notification if the app is focused AND the pane is the active surface (suppressed by existing `shouldSuppressExternalDelivery` logic)

### Edge Cases

- **Rapid bell spam**: The notification store replaces previous notifications for the same tab+surface, so rapid bells produce only one active notification at a time.
- **Pane closes while in attention state**: Attention is cleared via normal notification lifecycle.
- **Android disconnected**: No notification delivered. No error shown to user — silent degradation.
- **App loses focus entirely**: When the user switches away from cmux, all panes become "unfocused" for notification purposes.

## Configuration (v1)

No configuration in v1. Bell notifications fire for all unfocused panes. Claude Code notifications follow existing hook configuration.

## Deferred to v2

- Output silence/activity heuristics (state machine, per-surface tracking)
- Per-pane configuration toggles
- `cmux attention` CLI subcommand
- Configurable thresholds (silence, idle, cooldown)
- Notification filtering (subtle mode vs full banner)
