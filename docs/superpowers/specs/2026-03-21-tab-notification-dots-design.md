# Tab Notification Dots

**Date:** 2026-03-21
**Status:** Approved

## Problem

When a tab triggers a notification (bell, command completion, attention heuristic), the bell icon in the sidebar shows the count and marks it seen when that tab becomes active. However, there is no visual indicator *on the tab itself* to show which tab needs attention.

On desktop, the blue dot implementation exists in `TabItemView.swift` but is not functioning due to a bug in the badge sync logic. On Android, there is no per-tab notification indicator at all.

## Design Decisions

### Desktop (macOS) — Bug Fix

The notification dot rendering code already exists:
- `TabItemView.swift:460-466` renders a 6px blue circle when `tab.showsNotificationBadge` is true
- `Workspace.swift:5415-5425` has `syncUnreadBadgeStateForPanel()` to update the badge
- `WorkspaceContentView.swift:152-180` has `syncBonsplitNotificationBadges()` triggered by notification store changes

**Bug:** The badge sync in `WorkspaceContentView.syncBonsplitNotificationBadges()` builds `unreadFromNotifications` from `notification.surfaceId` values, then checks `panelIdFromSurfaceId(bonsplitTabId)` against that set.

The bell code path (`GhosttyTerminalView.swift:2068`) stores `surfaceView.terminalSurface?.id` (a Ghostty-level terminal surface UUID) as the notification's `surfaceId`. However, `panelIdFromSurfaceId()` maps from bonsplit `TabID` to panel UUID via `surfaceIdToPanelId`. If these UUID spaces differ, the lookup never matches.

Note: Other notification paths (socket commands, Claude hook paths via `GHOSTTY_ACTION_NOTIFY`) may correctly pass panel IDs. The bell path (`GHOSTTY_ACTION_RING_BELL`) is the primary suspect.

**Fix approach:**
1. Add debug logging in `syncBonsplitNotificationBadges()` to confirm the ID mismatch — log the `unreadFromNotifications` set and each `panelId` from `panelIdFromSurfaceId()` to see if they're in different UUID spaces
2. Fix the bell path to store the correct panel UUID as `surfaceId`, OR fix the badge sync to translate between the two ID spaces
3. Verify the dot appears on background tabs after a bell event

### Android — New Feature

#### Visual Design

- **Indicator:** 6px blue circle (#3B82F6)
- **Position:** Leading (before tab title text), in the same slot as the green connection dot
- **Priority:** Notification dot (blue) replaces connection dot (green) when both conditions are active. When notification clears, green connection dot returns if the surface still has a running process.
- **Color note:** Desktop uses `NSColor.systemBlue` which varies with user accent settings. Android uses a fixed `#3B82F6`. This is intentional — each platform follows its own design language rather than trying to match exact hex values.

#### Behavior

| Scenario | Dot shown? | Clears when? |
|----------|-----------|--------------|
| Notification on inactive tab | Yes (blue dot) | User taps/switches to that tab |
| Notification on active tab, app backgrounded | Yes (blue dot, replaces green) | User returns to app and the tab is still focused (cleared via `WidgetsBindingObserver.didChangeAppLifecycleState` on resume) |
| Notification on active tab, app foregrounded | No (suppressed, user is looking at it) | N/A |
| Notification cleared, process running | No blue dot; green connection dot returns | N/A |

#### Data Model Changes

**`Surface` model** (`surface_provider.dart`):
```dart
class Surface {
  final String id;
  final String title;
  final String workspaceId;
  final bool hasRunningProcess;
  final bool hasUnreadNotification;  // NEW — default false
  ...
}
```

**Important:** `Surface.copyWith()` must be updated to include `hasUnreadNotification` so that existing callers (e.g., `onSurfaceTitleChanged`) don't silently reset the flag to false.

**`SurfaceNotifier`** changes:
- Add `onSurfaceAttention(data)` — sets `hasUnreadNotification = true` for the surface matching `data['surface_id']`
- Modify `focusSurface()` / `onSurfaceFocused()` — clears `hasUnreadNotification` for the newly focused surface
- Modify `setSurfaces()` — when replacing the surface list (e.g., after workspace fetch), preserve `hasUnreadNotification` state from the previous list by matching on surface ID

#### Tab Chip Rendering Changes

**`_TabChip` widget** (`tab_bar_strip.dart`):
- Add `bool showNotificationDot` parameter
- Dot rendering logic:
  - If `showNotificationDot` is true → show blue dot (6px, `#3B82F6`)
  - Else if `showConnectionDot` is true → show green dot (5px, `connectedColor`)
  - Else → no dot
- Blue dot replaces green dot; they never show simultaneously

**`TabBarStrip._buildSurfaceTabs()`:**
- Pass `showNotificationDot: surface.hasUnreadNotification` to `_TabChip`

#### Bridge Event Payload

The desktop emits `surface.attention` events via `BridgeEventRelay.swift:265-281` with this JSON payload:

```json
{
  "workspace_id": "<UUID string>",
  "surface_id": "<UUID string or empty>",
  "reason": "bell|notification|silence|activity",
  "title": "<notification title string>"
}
```

Keys are string-typed. `surface_id` may be empty string if the notification is workspace-level.

#### Bridge Event Integration

The Android `EventHandler._handleSurfaceAttention()` at `event_handler.dart:88-95` currently only reads `workspace_id` and increments the workspace badge. It needs to also:
1. Read `data['surface_id']` from the event payload
2. Call `surfaceNotifier.onSurfaceAttention(data)` to set `hasUnreadNotification = true` on the matching surface
3. The existing `AttentionNotificationHandler` continues to show system notifications independently
4. The existing workspace-level `incrementNotificationCount` call remains unchanged

#### Clear Flow

1. User taps a tab → `onSurfaceSelected(surface.id)` fires
2. `SurfaceNotifier.focusSurface(surfaceId)` clears `hasUnreadNotification` for that surface
3. Tab chip re-renders without the blue dot

**App lifecycle handling:** When the app resumes from background (`WidgetsBindingObserver.didChangeAppLifecycleState` → `resumed`), clear `hasUnreadNotification` on the currently focused surface. This handles the case where a notification fired on the active tab while the app was backgrounded — the user returning to the app is equivalent to "seeing" the tab.

**Desktop sync (deferred):** Sending a socket command back to desktop to mark the notification as read is out of scope for this spec. The desktop's own notification-marking-read logic handles the desktop side independently. If cross-device read-sync becomes a user need, it should be a separate spec.

## Platform Comparison

| Aspect | Desktop (macOS) | Android |
|--------|----------------|---------|
| Dot color | System blue (6px) | #3B82F6 blue (6px) |
| Position | Trailing (close button area) | Leading (before title) |
| Shows on active tab | No | Yes (if app was backgrounded) |
| Clears when | Tab selected/focused | Tab selected/focused (or app resume) |
| Coexists with | Dirty indicator (side by side) | Connection dot (replaces it) |

## Out of Scope

- Notification count badges on individual tabs (only the sidebar/bell shows counts)
- Custom notification dot colors per notification type
- Animation on dot appearance (keep it simple, instant show/hide)
- Cross-device read-sync (desktop ↔ Android notification state)
