# Tab Notification Dots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the desktop blue notification dot that never appears on tabs, and add a blue notification dot to Android tab chips.

**Architecture:** Two independent workstreams. Desktop: diagnose and fix the ID mismatch or timing issue in the bell-to-badge pipeline (`GhosttyTerminalView` -> `TerminalNotificationStore` -> `WorkspaceContentView.syncBonsplitNotificationBadges` -> bonsplit `TabItemView`). Android: add `hasUnreadNotification` state to the `Surface` model, wire `surface.attention` bridge events to set it, render a blue dot in `_TabChip`, clear on tab select and app resume.

**Tech Stack:** Swift/SwiftUI (desktop), Dart/Flutter with Riverpod (Android)

**Design spec:** `/Users/sm/code/cmux/docs/superpowers/specs/2026-03-21-tab-notification-dots-design.md`

---

## File Map

### Desktop (bug fix)

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/GhosttyTerminalView.swift:2066-2091` | Modify | Bell handler that creates the notification — add diagnostic logging, then fix |
| `Sources/WorkspaceContentView.swift:152-180` | Modify | `syncBonsplitNotificationBadges()` — add diagnostic logging to trace ID matching |
| `Sources/TerminalNotificationStore.swift:844` | Read-only | `addNotification` — understand what gets stored |
| `Sources/Workspace.swift:5240-5242` | Read-only | `panelIdFromSurfaceId` — understand the bonsplit TabID -> panel UUID mapping |
| `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:460-466` | Read-only | Blue dot rendering — already implemented, just needs `showsNotificationBadge = true` |

### Android (new feature)

| File | Action | Responsibility |
|------|--------|---------------|
| `android-companion/lib/state/surface_provider.dart` | Modify | Add `hasUnreadNotification` to `Surface` model + notifier methods |
| `android-companion/lib/state/event_handler.dart:99-106` | Modify | Route `surface.attention` to surface notifier |
| `android-companion/lib/terminal/tab_bar_strip.dart` | Modify | Render blue notification dot in `_TabChip`, pass from `_buildSurfaceTabs` |
| `android-companion/lib/terminal/terminal_screen.dart:62` | Modify | Add `WidgetsBindingObserver` for app resume -> clear focused surface notification |

---

## Part 1: Desktop Bug Fix

### Task 1: Add diagnostic logging to trace the bell-to-badge pipeline

**Files:**
- Modify: `Sources/GhosttyTerminalView.swift:2066-2091`
- Modify: `Sources/WorkspaceContentView.swift:152-180`

The blue dot rendering in bonsplit's `TabItemView` is already correct (6px blue circle when `tab.showsNotificationBadge == true`). The bug is upstream: either the notification is not created with the right IDs, or `syncBonsplitNotificationBadges()` fails to match them.

Key insight: The callback context at `GhosttyTerminalView.swift:811-819` stores `surfaceId` as a non-weak `let` (captured at init), but the bell handler at line 2068 reads `surfaceView.terminalSurface?.id` through two weak references (`callbackContext?.surfaceView` then `.terminalSurface?.id`). If either weak ref is nil, `bellSurfaceId` becomes nil and the notification is stored with `surfaceId: nil`. The sync function's `compactMap { $0.surfaceId }` then drops it from `unreadFromNotifications`, so the badge never matches.

- [ ] **Step 1: Add NSLog to the RING_BELL handler**

In `Sources/GhosttyTerminalView.swift`, inside the `case GHOSTTY_ACTION_RING_BELL:` block (line 2066), add logging after the captures and before `performOnMain`. This logs whether the IDs are nil and what values they have:

```swift
case GHOSTTY_ACTION_RING_BELL:
    let bellTabId = surfaceView.tabId
    let bellSurfaceId = surfaceView.terminalSurface?.id
    let contextSurfaceId = callbackContext?.surfaceId  // ADD THIS — non-weak fallback
    NSLog("bell.capture tabId=\(bellTabId?.uuidString ?? "nil") bellSurfaceId=\(bellSurfaceId?.uuidString ?? "nil") contextSurfaceId=\(contextSurfaceId?.uuidString ?? "nil")")
    performOnMain {
```

This compares the weak-resolved `bellSurfaceId` against the non-weak `contextSurfaceId`. If they differ (or `bellSurfaceId` is nil while `contextSurfaceId` is not), we have found the bug.

Note: `callbackContext` is declared at line 2000, already in scope for this switch case.

- [ ] **Step 2: Add NSLog to syncBonsplitNotificationBadges**

In `Sources/WorkspaceContentView.swift`, add logging inside `syncBonsplitNotificationBadges()` after building `unreadFromNotifications` (after line 157):

```swift
private func syncBonsplitNotificationBadges() {
    let unreadFromNotifications: Set<UUID> = Set(
        notificationStore.notifications
            .filter { $0.tabId == workspace.id && !$0.isRead }
            .compactMap { $0.surfaceId }
    )
    let manualUnread = workspace.manualUnreadPanelIds

    // --- ADD diagnostic logging ---
    let allNotifs = notificationStore.notifications.filter { $0.tabId == workspace.id }
    let unreadNotifs = allNotifs.filter { !$0.isRead }
    NSLog("syncBadges ws=\(workspace.id.uuidString.prefix(8)) totalNotifs=\(allNotifs.count) unreadNotifs=\(unreadNotifs.count) unreadSurfaceIds=\(unreadFromNotifications.map { $0.uuidString.prefix(8) }) nilSurfaceCount=\(unreadNotifs.filter { $0.surfaceId == nil }.count)")

    for paneId in workspace.bonsplitController.allPaneIds {
        for tab in workspace.bonsplitController.tabs(inPane: paneId) {
            let panelId = workspace.panelIdFromSurfaceId(tab.id)
            // --- ADD per-tab logging ---
            NSLog("syncBadges.tab tabId=\(tab.id.id.uuidString.prefix(8)) panelId=\(panelId?.uuidString.prefix(8) ?? "nil") inUnread=\(panelId.map { unreadFromNotifications.contains($0) } ?? false) currentBadge=\(tab.showsNotificationBadge)")
```

- [ ] **Step 3: Build and test**

```bash
./scripts/reload.sh --tag notif-dots
```

Then in the running app:
1. Open two terminal tabs in the same workspace
2. Switch to the second tab
3. In the first tab (now background), have a process trigger a bell: `sleep 2 && echo -e '\a'`
4. Check Console.app (filter by "bell." and "syncBadges") for the log output

- [ ] **Step 4: Analyze logs and identify root cause**

Expected findings (most likely scenario based on code analysis):

**Scenario A — `bellSurfaceId` is nil, `contextSurfaceId` is non-nil:** The weak reference chain broke. Fix: use `callbackContext?.surfaceId` instead of `surfaceView.terminalSurface?.id`.

**Scenario B — Both IDs are non-nil and match, but `nilSurfaceCount > 0` in syncBadges:** The notification was stored with `surfaceId: nil` (race between capture and `performOnMain`). Fix: same as A.

**Scenario C — IDs are present in notification but `panelId` is nil in syncBadges:** The `surfaceIdToPanelId` mapping does not contain the bonsplit TabID. This would be a registration bug.

**Scenario D — IDs match, badge should show, but `currentBadge` is already correct:** The sync IS working but something else clears it immediately (e.g., `markRead` called on focus).

- [ ] **Step 5: Commit diagnostic logging**

```bash
git add Sources/GhosttyTerminalView.swift Sources/WorkspaceContentView.swift
git commit -m "debug: add diagnostic logging for bell notification badge pipeline"
```

---

### Task 2: Fix the bell handler to use non-weak surface ID

**Files:**
- Modify: `Sources/GhosttyTerminalView.swift:2066-2091`

Based on code analysis, the most probable root cause is Scenario A: the weak reference chain `surfaceView.terminalSurface?.id` resolves to nil because `GhosttyNSView.terminalSurface` (weak var at line 3727) or `GhosttySurfaceCallbackContext.surfaceView` (weak var at line 812) has been deallocated by the time the Ghostty callback fires on its background thread.

The fix is to use `callbackContext?.surfaceId` (a non-weak `let UUID` captured at context creation, line 814/819) instead of the weak-resolved `surfaceView.terminalSurface?.id`.

- [ ] **Step 1: Fix the bell handler**

In `Sources/GhosttyTerminalView.swift`, replace the weak-reference chain with the pre-captured ID:

**Before** (lines 2066-2091):
```swift
case GHOSTTY_ACTION_RING_BELL:
    let bellTabId = surfaceView.tabId
    let bellSurfaceId = surfaceView.terminalSurface?.id
```

**After:**
```swift
case GHOSTTY_ACTION_RING_BELL:
    let bellTabId = surfaceView.tabId
    // Use the non-weak surfaceId captured at callback context creation time.
    // surfaceView.terminalSurface?.id traverses two weak references that can
    // be nil if the surface is deallocated before this Ghostty callback fires.
    let bellSurfaceId = callbackSurfaceId ?? surfaceView.terminalSurface?.id
```

`callbackSurfaceId` is already declared at line 2002: `let callbackSurfaceId = callbackContext?.surfaceId` and is in scope for the entire switch statement. It reads from the non-weak `GhosttySurfaceCallbackContext.surfaceId` (line 814).

- [ ] **Step 2: Also fix bellTabId for consistency**

Apply the same pattern to `bellTabId` — use the pre-captured `callbackTabId` (line 2001):

```swift
case GHOSTTY_ACTION_RING_BELL:
    let bellTabId = callbackTabId ?? surfaceView.tabId
    let bellSurfaceId = callbackSurfaceId ?? surfaceView.terminalSurface?.id
```

- [ ] **Step 3: Update the diagnostic log to reflect the fix**

Update the NSLog added in Task 1 to show which source was used:

```swift
NSLog("bell.capture tabId=\(bellTabId?.uuidString ?? "nil") surfaceId=\(bellSurfaceId?.uuidString ?? "nil") fromContext=\(callbackSurfaceId != nil)")
```

- [ ] **Step 4: Build and test**

```bash
./scripts/reload.sh --tag notif-dots
```

Repeat the test from Task 1 Step 3. Check Console.app for:
- `bell.capture` log shows non-nil `surfaceId`
- `syncBadges` log shows the surfaceId appears in `unreadSurfaceIds`
- `syncBadges.tab` log shows `inUnread=true` for the correct tab
- The blue dot visually appears on the background tab

- [ ] **Step 5: If the dot still does not appear, check for immediate markRead**

If logs show the badge IS set (`inUnread=true`) but the dot flickers or never renders, the issue may be that `syncUnreadBadgeStateForPanel` (called from `Workspace.swift:8773` during focus reconciliation) immediately clears the badge. Add a log:

In `Sources/Workspace.swift`, inside `syncUnreadBadgeStateForPanel` (around line 5415):

```swift
private func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
    guard let tabId = surfaceIdFromPanelId(panelId) else { return }
    let shouldShowUnread = Self.shouldShowUnreadIndicator(
        hasUnreadNotification: hasUnreadNotification(panelId: panelId),
        isManuallyUnread: manualUnreadPanelIds.contains(panelId)
    )
    NSLog("syncUnreadBadge panel=\(panelId.uuidString.prefix(8)) shouldShow=\(shouldShowUnread) hasUnread=\(hasUnreadNotification(panelId: panelId)) isManual=\(manualUnreadPanelIds.contains(panelId))")
    if let existing = bonsplitController.tab(tabId), existing.showsNotificationBadge == shouldShowUnread {
        return
    }
    bonsplitController.updateTab(tabId, showsNotificationBadge: shouldShowUnread)
}
```

- [ ] **Step 6: Remove diagnostic logging, commit fix**

After confirming the fix works, remove all `NSLog` statements added in Tasks 1-2 (they are noisy for production):

- Remove NSLog from `GhosttyTerminalView.swift` RING_BELL case
- Remove NSLog from `WorkspaceContentView.swift` `syncBonsplitNotificationBadges()`
- Remove NSLog from `Workspace.swift` `syncUnreadBadgeStateForPanel()` (if added)

Keep the actual fix (using `callbackSurfaceId` / `callbackTabId`).

```bash
git add Sources/GhosttyTerminalView.swift Sources/WorkspaceContentView.swift Sources/Workspace.swift
git commit -m "fix(desktop): use non-weak surface ID in bell handler so notification badge matches

The RING_BELL callback captured surfaceId via surfaceView.terminalSurface?.id,
traversing two weak references that could be nil by the time Ghostty's
background thread fires the callback. This caused the notification to be
stored with surfaceId=nil, which syncBonsplitNotificationBadges() then
dropped via compactMap, so the blue dot never appeared.

Fix: use callbackContext.surfaceId (a non-weak let captured at context
creation time) as the primary source, falling back to the weak chain."
```

---

## Part 2: Android Feature

### Task 3: Add `hasUnreadNotification` to the Surface model

**Files:**
- Modify: `android-companion/lib/state/surface_provider.dart`

- [ ] **Step 1: Add field to Surface class**

In `android-companion/lib/state/surface_provider.dart`, add `hasUnreadNotification` to the `Surface` class:

```dart
class Surface {
  final String id;
  final String title;
  final String workspaceId;
  final bool hasRunningProcess;
  final bool hasUnreadNotification;

  const Surface({
    required this.id,
    required this.title,
    required this.workspaceId,
    this.hasRunningProcess = false,
    this.hasUnreadNotification = false,
  });

  Surface copyWith({
    String? id,
    String? title,
    String? workspaceId,
    bool? hasRunningProcess,
    bool? hasUnreadNotification,
  }) {
    return Surface(
      id: id ?? this.id,
      title: title ?? this.title,
      workspaceId: workspaceId ?? this.workspaceId,
      hasRunningProcess: hasRunningProcess ?? this.hasRunningProcess,
      hasUnreadNotification: hasUnreadNotification ?? this.hasUnreadNotification,
    );
  }
}
```

This is a direct replacement of the existing `Surface` class (lines 28-53). The only additions are the `hasUnreadNotification` field, its constructor parameter, and its `copyWith` parameter.

- [ ] **Step 2: Verify no compile errors**

```bash
cd /Users/sm/code/cmux/android-companion && flutter analyze lib/state/surface_provider.dart
```

Expected: no errors. All existing callers of `Surface()` and `copyWith()` use named parameters with defaults, so they continue to work without changes.

- [ ] **Step 3: Commit**

```bash
git add android-companion/lib/state/surface_provider.dart
git commit -m "feat(android): add hasUnreadNotification field to Surface model"
```

---

### Task 4: Add notifier methods for attention events and notification clearing

**Files:**
- Modify: `android-companion/lib/state/surface_provider.dart`

- [ ] **Step 1: Add `onSurfaceAttention` method to SurfaceNotifier**

Add after the `onSurfaceMoved` method (after line 166):

```dart
/// Whether the app is currently in the background (paused/hidden).
///
/// Set by [setAppBackgrounded] / [setAppResumed] from the lifecycle
/// observer. Used to decide whether the focused surface should still
/// receive a notification dot (it should when the app is backgrounded,
/// because the user is not looking at it).
bool _isAppBackgrounded = false;

/// Called when the app enters the background (paused/hidden).
void setAppBackgrounded() {
  _isAppBackgrounded = true;
}

/// Called when the app resumes to the foreground.
void setAppResumed() {
  _isAppBackgrounded = false;
}

/// Handle surface.attention event — mark the surface as having an unread notification.
///
/// Sets hasUnreadNotification=true for the matching surface. Suppressed if the
/// surface is currently focused AND the app is in the foreground (user is
/// looking at it). If the app is backgrounded, the dot shows even on the
/// focused surface — it will be cleared on app resume.
void onSurfaceAttention(Map<String, dynamic> data) {
  final surfaceId = data['surface_id'] as String?;
  if (surfaceId == null || surfaceId.isEmpty) return;

  // Only suppress when the user is actively looking at this surface:
  // focused AND app is in the foreground.
  if (surfaceId == state.focusedSurfaceId && !_isAppBackgrounded) return;

  final updated = state.surfaces.map((s) {
    if (s.id == surfaceId) return s.copyWith(hasUnreadNotification: true);
    return s;
  }).toList();

  state = state.copyWith(surfaces: updated);
}
```

- [ ] **Step 2: Modify `focusSurface` to clear notification on the focused surface**

Replace the existing `focusSurface` method (lines 178-180):

**Before:**
```dart
void focusSurface(String surfaceId) {
  state = state.copyWith(focusedSurfaceId: surfaceId);
}
```

**After:**
```dart
/// Focus a specific surface by ID.
///
/// Also clears hasUnreadNotification on the newly focused surface —
/// switching to a tab is equivalent to "reading" its notification.
void focusSurface(String surfaceId) {
  final updated = state.surfaces.map((s) {
    if (s.id == surfaceId && s.hasUnreadNotification) {
      return s.copyWith(hasUnreadNotification: false);
    }
    return s;
  }).toList();
  state = SurfaceState(
    surfaces: updated,
    focusedSurfaceId: surfaceId,
  );
}
```

- [ ] **Step 3: Modify `onSurfaceFocused` to also clear notification**

Replace the existing `onSurfaceFocused` method (lines 124-128):

**Before:**
```dart
void onSurfaceFocused(Map<String, dynamic> data) {
  final surfaceId = data['surface_id'] as String?;
  if (surfaceId == null) return;
  state = state.copyWith(focusedSurfaceId: surfaceId);
}
```

**After:**
```dart
/// Handle surface.focused event from the desktop bridge.
///
/// Clears any unread notification on the newly focused surface since the
/// desktop user has now switched to it (cross-device implicit read).
void onSurfaceFocused(Map<String, dynamic> data) {
  final surfaceId = data['surface_id'] as String?;
  if (surfaceId == null) return;

  final updated = state.surfaces.map((s) {
    if (s.id == surfaceId && s.hasUnreadNotification) {
      return s.copyWith(hasUnreadNotification: false);
    }
    return s;
  }).toList();

  state = SurfaceState(
    surfaces: updated,
    focusedSurfaceId: surfaceId,
  );
}
```

- [ ] **Step 4: Modify `setSurfaces` to preserve notification state**

Replace the existing `setSurfaces` method (lines 116-121):

**Before:**
```dart
void setSurfaces(List<Surface> surfaces, {String? focusedId}) {
  state = SurfaceState(
    surfaces: surfaces,
    focusedSurfaceId: focusedId ?? surfaces.firstOrNull?.id,
  );
}
```

**After:**
```dart
/// Replace all surfaces (e.g. after fetching workspace panels).
///
/// Preserves hasUnreadNotification from the previous state by matching
/// on surface ID, so a workspace refresh does not silently clear dots.
void setSurfaces(List<Surface> surfaces, {String? focusedId}) {
  final previousNotifications = <String, bool>{};
  for (final s in state.surfaces) {
    if (s.hasUnreadNotification) {
      previousNotifications[s.id] = true;
    }
  }

  final merged = surfaces.map((s) {
    if (previousNotifications.containsKey(s.id)) {
      return s.copyWith(hasUnreadNotification: true);
    }
    return s;
  }).toList();

  state = SurfaceState(
    surfaces: merged,
    focusedSurfaceId: focusedId ?? merged.firstOrNull?.id,
  );
}
```

- [ ] **Step 5: Add `clearNotificationForFocusedSurface` for app resume**

Add after the `previousSurfaceId` method (before line 200):

```dart
/// Clear unread notification on the currently focused surface.
///
/// Called when the app resumes from background — the user returning to the
/// app is equivalent to "seeing" the active tab, so its dot should clear.
void clearNotificationForFocusedSurface() {
  final focusedId = state.focusedSurfaceId;
  if (focusedId == null) return;

  final hasDot = state.surfaces.any(
    (s) => s.id == focusedId && s.hasUnreadNotification,
  );
  if (!hasDot) return;

  final updated = state.surfaces.map((s) {
    if (s.id == focusedId) {
      return s.copyWith(hasUnreadNotification: false);
    }
    return s;
  }).toList();

  state = state.copyWith(surfaces: updated);
}
```

- [ ] **Step 6: Verify no compile errors**

```bash
cd /Users/sm/code/cmux/android-companion && flutter analyze lib/state/surface_provider.dart
```

- [ ] **Step 7: Commit**

```bash
git add android-companion/lib/state/surface_provider.dart
git commit -m "feat(android): add notification state methods to SurfaceNotifier

- onSurfaceAttention: sets hasUnreadNotification on matching surface
- focusSurface/onSurfaceFocused: clears notification on focused surface
- setSurfaces: preserves notification state across workspace refreshes
- clearNotificationForFocusedSurface: clears on app resume
- setAppBackgrounded/setAppResumed: tracks lifecycle for suppression logic"
```

---

### Task 5: Wire the event handler to set notification state

**Files:**
- Modify: `android-companion/lib/state/event_handler.dart:99-106`

- [ ] **Step 1: Update `_handleSurfaceAttention` to call surface notifier**

In `android-companion/lib/state/event_handler.dart`, replace the existing `_handleSurfaceAttention` method (lines 99-106):

**Before:**
```dart
void _handleSurfaceAttention(Map<String, dynamic> data) {
  final workspaceId = data['workspace_id'] as String? ?? '';

  // Increment the workspace's notification badge.
  // System notification is shown by ConnectionManager._handleAttentionEvent
  // which fires regardless of whether this screen is active.
  _ref.read(workspaceProvider.notifier).incrementNotificationCount(workspaceId);
}
```

**After:**
```dart
void _handleSurfaceAttention(Map<String, dynamic> data) {
  final workspaceId = data['workspace_id'] as String? ?? '';

  // Increment the workspace's notification badge.
  // System notification is shown by ConnectionManager._handleAttentionEvent
  // which fires regardless of whether this screen is active.
  _ref.read(workspaceProvider.notifier).incrementNotificationCount(workspaceId);

  // Mark the specific surface as having an unread notification so the tab
  // chip shows a blue dot. The surface notifier suppresses the dot if the
  // user is already looking at that surface.
  _ref.read(surfaceProvider.notifier).onSurfaceAttention(data);
}
```

- [ ] **Step 2: Verify no compile errors**

```bash
cd /Users/sm/code/cmux/android-companion && flutter analyze lib/state/event_handler.dart
```

- [ ] **Step 3: Commit**

```bash
git add android-companion/lib/state/event_handler.dart
git commit -m "feat(android): route surface.attention to surface notifier for tab dot"
```

---

### Task 6: Render the blue notification dot in the tab chip

**Files:**
- Modify: `android-companion/lib/terminal/tab_bar_strip.dart`

- [ ] **Step 1: Add `showNotificationDot` parameter to `_TabChip`**

In `android-companion/lib/terminal/tab_bar_strip.dart`, add the parameter to the `_TabChip` class (around line 296-314):

```dart
class _TabChip extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isActive;
  final Color accentColor;
  final bool showConnectionDot;
  final bool showNotificationDot;

  /// Opacity of the amber underline indicator (0.0-1.0). Interpolated during
  /// swipe gestures to create a crossfade between the current and target tabs.
  final double underlineOpacity;

  const _TabChip({
    required this.title,
    required this.icon,
    required this.isActive,
    required this.accentColor,
    this.showConnectionDot = false,
    this.showNotificationDot = false,
    this.underlineOpacity = 0.0,
  });
```

- [ ] **Step 2: Replace the dot rendering in `_TabChip.build`**

Replace the connection dot section (lines 334-344) with priority-based dot logic:

**Before:**
```dart
// Connection dot (5px green circle before active tab title)
if (showConnectionDot)
  Container(
    width: 5,
    height: 5,
    margin: const EdgeInsets.only(right: 6),
    decoration: BoxDecoration(
      color: c.connectedColor,
      shape: BoxShape.circle,
    ),
  ),
```

**After:**
```dart
// Notification dot (6px blue) takes priority over connection dot (5px green).
// They never show simultaneously — blue replaces green when active.
if (showNotificationDot)
  Container(
    width: 6,
    height: 6,
    margin: const EdgeInsets.only(right: 6),
    decoration: const BoxDecoration(
      color: Color(0xFF3B82F6),
      shape: BoxShape.circle,
    ),
  )
else if (showConnectionDot)
  Container(
    width: 5,
    height: 5,
    margin: const EdgeInsets.only(right: 6),
    decoration: BoxDecoration(
      color: c.connectedColor,
      shape: BoxShape.circle,
    ),
  ),
```

- [ ] **Step 3: Pass `showNotificationDot` from `_buildSurfaceTabs`**

In `_buildSurfaceTabs` (around line 235-242), add the new parameter:

**Before:**
```dart
child: _TabChip(
  title: surface.title,
  icon: Icons.terminal,
  isActive: isActive,
  accentColor: c.accent,
  showConnectionDot: isActive && surface.hasRunningProcess,
  underlineOpacity: underlineOpacity,
),
```

**After:**
```dart
child: _TabChip(
  title: surface.title,
  icon: Icons.terminal,
  isActive: isActive,
  accentColor: c.accent,
  showConnectionDot: isActive && surface.hasRunningProcess,
  showNotificationDot: surface.hasUnreadNotification,
  underlineOpacity: underlineOpacity,
),
```

- [ ] **Step 4: Verify no compile errors**

```bash
cd /Users/sm/code/cmux/android-companion && flutter analyze lib/terminal/tab_bar_strip.dart
```

- [ ] **Step 5: Commit**

```bash
git add android-companion/lib/terminal/tab_bar_strip.dart
git commit -m "feat(android): render blue notification dot on tab chips

6px #3B82F6 blue dot in leading position (before title). Takes priority
over the green connection dot — they never show simultaneously."
```

---

### Task 7: Clear notification dot on app resume

**Files:**
- Modify: `android-companion/lib/terminal/terminal_screen.dart`

- [ ] **Step 1: Add `WidgetsBindingObserver` mixin to `_TerminalScreenState`**

In `android-companion/lib/terminal/terminal_screen.dart`, add the mixin to the class declaration (line 62-63):

**Before:**
```dart
class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with TickerProviderStateMixin {
```

**After:**
```dart
class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
```

- [ ] **Step 2: Register and unregister the observer**

Find the existing `initState` and `dispose` methods. Add observer registration.

In `initState`, add:
```dart
WidgetsBinding.instance.addObserver(this);
```

In `dispose`, add (before `super.dispose()`):
```dart
WidgetsBinding.instance.removeObserver(this);
```

- [ ] **Step 3: Add `didChangeAppLifecycleState` override**

Add the lifecycle callback method to `_TerminalScreenState`:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  final notifier = ref.read(surfaceProvider.notifier);
  switch (state) {
    case AppLifecycleState.paused:
    case AppLifecycleState.hidden:
      // Track background state so onSurfaceAttention allows dots on the
      // focused surface while the user is not looking at the app.
      notifier.setAppBackgrounded();
    case AppLifecycleState.resumed:
      // User returned to the app — clear the notification dot on the
      // currently focused surface since the user is now "seeing" that tab.
      notifier.setAppResumed();
      notifier.clearNotificationForFocusedSurface();
    default:
      break;
  }
}
```

- [ ] **Step 4: Verify no compile errors**

```bash
cd /Users/sm/code/cmux/android-companion && flutter analyze lib/terminal/terminal_screen.dart
```

- [ ] **Step 5: Commit**

```bash
git add android-companion/lib/terminal/terminal_screen.dart
git commit -m "feat(android): clear notification dot on currently focused tab when app resumes

When the user returns from background, the focused tab's blue dot clears
since the user is now looking at it."
```

---

## Testing Checklist

### Desktop

- [ ] Trigger bell (`echo -e '\a'`) in a **background** tab -> blue dot appears on that tab
- [ ] Switch to the tab with the blue dot -> dot disappears (notification marked read)
- [ ] Trigger bell in the **focused** tab while app is in foreground -> no dot (suppressed)
- [ ] Trigger bell while app is not focused -> dot appears, system notification fires
- [ ] Multiple bells in different background tabs -> each shows its own dot
- [ ] Close tab with active dot -> no crash, dot state cleaned up
- [ ] Manual unread (mark-unread feature) + bell notification -> both dots coexist (dirty + blue)

### Android

- [ ] Receive `surface.attention` for inactive tab -> blue dot appears before tab title
- [ ] Tap the tab with the blue dot -> dot clears, green connection dot returns if process running
- [ ] Receive `surface.attention` for the focused tab while app is foregrounded -> no dot
- [ ] Receive `surface.attention` for the focused tab while app is backgrounded -> dot appears
- [ ] Return to app (resume) with a dot on the focused tab -> dot clears
- [ ] Workspace refresh (setSurfaces) while dots are active -> dots preserved
- [ ] Desktop user switches to a tab (surface.focused event) -> dot clears on Android too
