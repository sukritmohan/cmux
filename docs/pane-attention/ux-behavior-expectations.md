# Pane Attention Notifications — UX Behavior Expectations

## Core Behavior

When a terminal pane that the user is NOT looking at requires attention, cmux alerts them on both desktop and their Android companion device.

### What Triggers Attention

1. **Terminal bell** — Immediate. Any program sending `\x07` triggers attention right away.
2. **Output silence** — An active pane goes quiet for 30 seconds. Indicates the process may be waiting for input (e.g., Claude Code permission prompt, build waiting for confirmation).
3. **Output activity** — An idle pane (quiet for ≥5 seconds) starts producing output. Indicates something started happening (e.g., CI kicked off, build started).

### What the User Sees

**Desktop:**
- Dock badge increments (shows unread attention count)
- Configured sound plays
- The pane's tab gets a visual attention dot/highlight
- No macOS notification banner (intentionally subtle)
- Focusing the specific surface within its split pane clears its attention state (selecting the workspace alone is not enough — the surface must gain focus)

**Android companion:**
- System notification in the notification shade (with vibration)
- Notification title = workspace name, body = pane title + reason
- In-app: workspace badge count increments, pane gets attention highlight
- Tapping the notification navigates to the relevant workspace/pane

### What the User Does NOT See

- No notification for focused panes (you're already looking at it)
- No repeat notifications within 60 seconds of the last one for the same pane (cooldown)
- No notification if attention tracking is disabled

### Edge Cases

- **Rapid bell spam**: Bell has its own 5-second cooldown. Rapid `\x07` sequences produce at most one notification per 5 seconds.
- **Pane closes while in attention state**: Attention is cleared, no stale notifications remain.
- **Android disconnected**: No notification delivered. No error shown to user — silent degradation.
- **User focuses then unfocuses pane quickly**: Focusing resets the state machine to IDLE. Activity tracking restarts fresh when the pane is unfocused again.
- **App loses focus entirely**: When the user switches away from cmux, all unfocused panes are eligible for tracking (same as when cmux is focused but the pane isn't).
- **Pane was already active when unfocused**: If a pane is producing output when the user switches away, it enters ACTIVE state silently (no "activity" attention) but the silence timer starts — so if it later goes quiet, "silence" attention fires normally.
- **Surface moved between panes**: Activity tracking state transfers with the surface to the new pane. Timers continue running.

## Configuration

Global settings only in v1:

- `attention.enabled` — master toggle (default: on)
- `attention.silence_threshold` — seconds of silence before "waiting" alert (default: 30)
- `attention.idle_threshold` — seconds of idle before "woke up" alert (default: 5)
- `attention.cooldown` — seconds between repeat notifications per pane (default: 60)

Configurable via `cmux attention config`, socket V2 API, or cmux config file.
