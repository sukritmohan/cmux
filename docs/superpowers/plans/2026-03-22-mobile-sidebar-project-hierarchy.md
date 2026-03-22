# Mobile Sidebar Project Hierarchy — Implementation Plan

**Date:** 2026-03-22
**Spec:** [Mobile Sidebar Project Hierarchy Design](../specs/2026-03-22-mobile-sidebar-project-hierarchy-design.md)
**Branch:** `feature/mobile-sidebar-hierarchy`

## Executive Summary

The mobile sidebar project hierarchy requires changes on two sides: (1) a Swift bridge API on the desktop (`project.list` command + `project.updated` event) that serializes the existing `SidebarProjectManager` tree with inline workspace details from `TabManager` and notification counts from `TerminalNotificationStore`, and (2) a Dart rewrite of the Android companion's drawer to consume this tree and render a three-level hierarchy (Project > Branch > Workspace). The implementation is broken into 5 ordered chunks: bridge API, Dart data models + provider, drawer skeleton with project/branch rows, workspace/linked-terminal rows with active state, and finally search + notification badge bubbling.

---

## Chunk 1: Swift Bridge API (`project.list` + `project.updated`)

**Files to modify:**

- `Sources/TerminalController.swift` — Add `project.list` case to v2 dispatch switch, implement `v2ProjectList()` handler
- `Sources/Bridge/BridgeEventRelay.swift` — Add `bridgeProjectUpdated` notification, register observer
- `Sources/SidebarProjectManager.swift` — Post notification at end of `rebuild()`
- `Sources/AppDelegate.swift` — Add `sidebarProjectManagerFor(tabManager:)` helper

**Steps:**

1. In `BridgeEventRelay.swift`, add notification name:
   ```swift
   static let bridgeProjectUpdated = Notification.Name("bridge.project.updated")
   ```

2. In `SidebarProjectManager.swift`, at the end of `rebuild()` (after `projects = newProjects`), post the notification:
   ```swift
   NotificationCenter.default.post(name: .bridgeProjectUpdated, object: nil)
   ```
   This fires after the coalesced rebuild, not on every `scheduleRebuild()`.

3. In `BridgeEventRelay.swift` `registerObservers()`, add observer for `bridgeProjectUpdated`. The observer serializes the full tree and emits via `emit(event: "project.updated", data: <serialized tree>)`.

4. In `AppDelegate.swift`, add helper to look up SidebarProjectManager from TabManager:
   ```swift
   func sidebarProjectManagerFor(tabManager: TabManager) -> SidebarProjectManager? {
       mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.sidebarProjectManager
   }
   ```

5. In `TerminalController.swift`, add dispatch case (after workspace block ~line 2088):
   ```swift
   case "project.list":
       return v2Result(id: id, self.v2ProjectList(params: params))
   ```
   Add `"project.list"` to the available commands array.

6. Implement `v2ProjectList(params:)`:
   - Resolve TabManager via `v2ResolveTabManager(params:)`
   - Access SidebarProjectManager via `AppDelegate.shared.sidebarProjectManagerFor(tabManager:)`
   - Iterate `sidebarProjectManager.projects` and `.otherProject`
   - For each workspace UUID in a branch's `workspaceIds`, look up workspace from `tabManager.tabs` to get title, panels
   - Query `TerminalNotificationStore.shared.unreadCount(forTabId:)` for each workspace
   - Return `active_workspace_id` from `tabManager.selectedTabId`
   - Follow manual dict construction pattern (matching `v2WorkspaceList`)

**Verification:**
- Connect to tagged debug build socket, send `{"id":1,"method":"project.list"}`
- Verify response contains projects, branches, workspaces with notification counts
- Verify `other_project` populated for non-git workspaces
- Verify `project.updated` event fires when switching branches or creating workspaces

**Dependencies:** None (first chunk).

---

## Chunk 2: Dart Data Models + Provider

**Files to create:**

- `android-companion/lib/state/project_hierarchy_provider.dart` — Models, state, notifier, provider

**Files to modify:**

- `android-companion/lib/state/event_handler.dart` — Add `project.updated` case

**Steps:**

1. Create model classes in `project_hierarchy_provider.dart`:
   - `SidebarProject`: `id`, `name`, `repoPath`, `isExpanded`, `isAutoCreated`, `order`, `branches`, `isOtherSection`. Factory `fromJson`.
   - `SidebarBranch`: `name`, `isDirty`, `isExpanded`, `workspaces` (list of `Workspace` from existing provider), `linkedTerminals`. Factory `fromJson`.
   - `LinkedTerminalEntry`: `id`, `owningWorkspaceId`, `owningProjectName`, `owningWorkspaceName`, `panelId`. Factory `fromJson`.

2. Create `ProjectHierarchyState`:
   - `projects` (list), `otherProject` (nullable), `activeWorkspaceId`, `loading`, `hasLoaded`

3. Create `ProjectHierarchyNotifier` (StateNotifier):
   - `fetchProjectHierarchy()`: calls `manager.sendRequest('project.list')`, parses response, applies local expand/collapse overrides
   - `onProjectUpdated(Map<String, dynamic> data)`: full tree replacement, preserves local expand overrides. **Race condition mitigation:** do not reset scroll position or disturb in-flight animations when applying updates.
   - `toggleProjectExpanded(String projectId)`: stores in local `Map<String, bool>` override keyed by project ID
   - `toggleBranchExpanded(String projectId, String branchName)`: stores in `Map<String, bool>` keyed by `"$projectId:$branchName"`
   - On first fetch: use desktop's `is_expanded` values. On subsequent updates: preserve local overrides for known projects, use desktop values for newly-appearing projects.

4. Define provider:
   ```dart
   final projectHierarchyProvider =
       StateNotifierProvider<ProjectHierarchyNotifier, ProjectHierarchyState>((ref) {
     return ProjectHierarchyNotifier(ref);
   });
   ```

5. In `event_handler.dart`, add case:
   ```dart
   case 'project.updated':
     _ref.read(projectHierarchyProvider.notifier).onProjectUpdated(data);
   ```

**Verification:**
- Unit test `fromJson` factories with sample JSON matching spec response shape
- Test `toggleProjectExpanded` preserves state across `onProjectUpdated` calls
- Test "Other" section parsing (empty branch name, `is_other_section: true`)

**Dependencies:** Chunk 1 (bridge API must exist).

---

## Chunk 3: Drawer Skeleton — Project Rows + Branch Rows

**Files to create:**

- `android-companion/lib/workspace/project_row.dart` — Project header with monogram icon, chevron, separator
- `android-companion/lib/workspace/branch_row.dart` — Branch row with fork icon, dirty dot, (+) button

**Files to modify:**

- `android-companion/lib/workspace/workspace_drawer.dart` — Rewrite from flat list to nested tree
- `android-companion/lib/terminal/terminal_screen.dart` — Update WorkspaceDrawer constructor call

**Steps:**

1. Create `project_row.dart`:
   - 22x22px monogram icon (JetBrains Mono 700, 11px, uppercase first letter, 5px radius)
   - Animated chevron (16px, `AnimatedRotation` for -90deg collapse, 200ms cubic-bezier(0.4, 0, 0.2, 1))
   - Font: JetBrains Mono, 13px, weight 600, letter-spacing -0.2
   - 1px separator above non-first projects
   - "Other" variant: weight 500, 35% opacity, 3% monogram bg
   - `onTap` -> `toggleProjectExpanded`

2. Create `branch_row.dart`:
   - Fork icon (12px), chevron (14px, same animation)
   - Font: IBM Plex Mono, 11.5px, weight 500, 48% opacity
   - Dirty dot: 5x5 amber circle with `BoxShadow(0, 0, 4, rgba(224,160,48,0.4))`
   - (+) button: 18x18, 4px radius, 30% opacity text
   - `onTap` -> `toggleBranchExpanded`
   - (+) calls `workspace.create` with `cwd` set to project's `repoPath`

3. Rewrite `workspace_drawer.dart`:
   - Remove `workspaces` and `activeWorkspaceId` constructor params (now from `projectHierarchyProvider`)
   - Header: "PROJECTS" with search icon toggle
   - Build flat widget list by iterating projects > branches > workspaces
   - "Other" section: skip branch row when `branch.name.isEmpty`
   - Loading: if `!state.hasLoaded`, show 3 shimmer skeleton rows
   - Fallback: if project.list failed, render flat list from `workspaceProvider`
   - Call `fetchProjectHierarchy()` on first build

4. Update `terminal_screen.dart` WorkspaceDrawer instantiation: remove old `workspaces:` / `activeWorkspaceId:` params.

**Verification:**
- Build and connect to desktop with multiple repos
- Projects appear with monogram icons and separators
- Branches indented under projects with fork icons
- Tap toggles expand/collapse with smooth chevron animation
- (+) creates new workspace
- "Other" shows non-git workspaces without branch level
- Shimmer on initial load

**Dependencies:** Chunk 2.

---

## Chunk 4: Workspace Rows, Linked Terminal Rows, Active State

**Files to create:**

- `android-companion/lib/workspace/linked_terminal_row.dart` — Italic linked terminal entry

**Files to modify:**

- `android-companion/lib/workspace/workspace_tile.dart` — Refactor to new visual spec
- `android-companion/lib/workspace/workspace_drawer.dart` — Wire tap interactions

**Steps:**

1. Refactor `workspace_tile.dart`:
   - Remove two-line layout (name + metadata + branch badge). Replace with: dot indicator (4x4) + workspace name
   - Left padding: 42px (active: 39px compensating for 3px border)
   - Active: 3px amber left border, `rgba(224,160,48,0.06)` bg, weight 600, full-opacity text
   - Active dot: amber with glow `BoxShadow(0, 0, 6, rgba(224,160,48,0.5))`
   - Inactive dot: 15% (dark) / 12% (light) opacity
   - Font: IBM Plex Sans, 13px, 400 inactive / 600 active
   - Notification badge: min-width 18px, height 18px, pill shape, amber bg, white text, 10px
   - Border radius: 5px inactive, `BorderRadius.only(topRight: 5, bottomRight: 5)` active

2. Create `linked_terminal_row.dart`:
   - Font: IBM Plex Sans, 11px, italic, 400, 22% opacity
   - Link icon: Icons.link, 10px, 70% of 20% color
   - Text: "shared from {owningProjectName}/{owningWorkspaceName}", ellipsis
   - Left padding: 42px, min height: 28px
   - `onTap`: select `owningWorkspaceId`, close drawer

3. Wire interactions in `workspace_drawer.dart`:
   - Workspace tap: `workspaceProvider.selectWorkspace(ws.id)`, send `workspace.select` via bridge, close drawer
   - Linked terminal tap: same but with `owningWorkspaceId`

**Verification:**
- Active workspace has amber left border and glowing dot
- Tapping workspace switches and closes drawer
- Linked terminals show italic text with link icon
- Tapping linked terminal navigates to owning workspace
- Notification badges appear correctly

**Dependencies:** Chunk 3.

---

## Chunk 5: Search + Notification Badge Bubbling

**Files to modify:**

- `android-companion/lib/workspace/workspace_drawer.dart` — Search toggle, field, filtering, highlighting
- `android-companion/lib/workspace/project_row.dart` — Aggregate notification badge when collapsed
- `android-companion/lib/workspace/branch_row.dart` — Aggregate notification badge when collapsed

**Steps:**

1. Search toggle in drawer header:
   - Tapping search icon shows/hides search field below header (animated slide-in)
   - Active icon: amber-tinted bg `rgba(224,160,48,0.15)`, amber color
   - Search field: 32px height, `bgSurface` fill, `borderStrong` border, 6px radius

2. Search filtering in `_WorkspaceDrawerState`:
   - `_searchQuery` with 150ms `Timer` debounce
   - Case-insensitive substring matching across project names, branch names, workspace titles
   - Subtree logic: workspace match -> show parent branch + project. Branch match -> show all its workspaces. Project match -> show all branches + workspaces.
   - Clearing restores full tree with preserved expand/collapse

3. Match highlighting:
   - `highlightQuery` parameter passed to ProjectRow, BranchRow, WorkspaceTile
   - Helper `_buildHighlightedText(text, query, baseStyle, highlightColor)` splits and colorizes matches
   - Highlight color: `#E0A030` dark, `#B07810` light

4. Notification badge bubbling:
   - `project_row.dart`: when `!project.isExpanded`, sum all descendant workspace `notification_count`. Show badge if > 0.
   - `branch_row.dart`: when `!branch.isExpanded`, sum branch's workspace `notification_count`. Show badge if > 0.

**Verification:**
- Search "cm" highlights "cmux", "auth" highlights "fix/auth" and "auth testing"
- Clear search restores full tree
- Collapse project with 3 total unread -> shows "3" badge on project row
- Collapse branch with notifications -> aggregate badge on branch row
- Expand again -> individual workspace badges visible

**Dependencies:** Chunk 4.

---

## Risks & Concerns

1. **Per-window SidebarProjectManager.** The mobile app assumes a single window. `v2ResolveTabManager` can resolve to any window. If user has multiple windows, mobile sees only one. Matches existing `workspace.list` behavior — acceptable.

2. **Notification count source.** Mobile also tracks counts via `WorkspaceNotifier.incrementNotificationCount()` from `surface.attention` events. The project hierarchy uses bridge-provided counts. These could diverge. Mitigation: `project.updated` triggers full refresh with fresh desktop counts.

3. **Race condition on updates.** A `project.updated` event during user interaction (e.g., mid-scroll, mid-collapse) could cause UI jank. Mitigation: apply tree updates without resetting scroll position; preserve local expand/collapse overrides.

4. **Expand/collapse persistence.** Local overrides are lost on app force-close. Desktop `is_expanded` values are reasonable defaults. Acceptable for v1.

5. **Font cold-start.** IBM Plex Sans/Mono via `google_fonts` may not be available offline on first launch. Existing risk, not new — system fonts used as fallback.

---

## Execution Order

```
Chunk 1 (Swift API)
    |
    v
Chunk 2 (Dart models + provider)
    |
    v
Chunk 3 (Drawer skeleton)
    |
    v
Chunk 4 (Workspace rows + interactions)
    |
    v
Chunk 5 (Search + badge bubbling)
```

All chunks are sequential. Each builds on the previous.
