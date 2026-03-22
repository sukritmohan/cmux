# Mobile Sidebar Project Hierarchy Design

**Date:** 2026-03-22
**Status:** Approved
**Relates to:** [Desktop Sidebar Project Hierarchy](2026-03-21-sidebar-project-hierarchy-design.md)

## Problem Statement

The Android companion app's workspace drawer shows a flat list of workspaces. The desktop now groups workspaces into a Project -> Branch -> Workspace tree hierarchy. The mobile sidebar should match the desktop layout with mobile-adapted visual hierarchy.

## Decisions

- **Data source:** New `project.list` bridge API returns pre-grouped tree with workspace details inline (no separate `workspace.list` call needed for drawer)
- **Linked terminals:** Included — full parity with desktop
- **Expand/collapse:** Same disclosure triangles on both projects and branches, tap to toggle
- **New workspace:** Persistent (+) button on each branch row (replaces bottom "+" button)
- **Visual hierarchy:** Five-channel differentiation (font family, size, weight, color opacity, iconography)

---

## 1. Bridge API

### New command: `project.list`

Returns the full project hierarchy from `SidebarProjectManager` with workspace details embedded inline.

**Response shape:**

```json
{
  "projects": [
    {
      "id": "<uuid>",
      "name": "cmux",
      "repo_path": "/Users/sm/code/cmux",
      "is_expanded": true,
      "is_auto_created": false,
      "order": 0,
      "branches": [
        {
          "name": "main",
          "is_dirty": false,
          "is_expanded": true,
          "workspaces": [
            {
              "id": "<ws-uuid>",
              "title": "dev server",
              "notification_count": 2,
              "panels": [
                {"id": "<panel-uuid>", "type": "terminal", "title": "zsh"}
              ]
            }
          ],
          "linked_terminals": [
            {
              "id": "<uuid>",
              "owning_workspace_id": "<ws-uuid>",
              "owning_project_name": "cmux",
              "owning_workspace_name": "dev server",
              "panel_id": "<panel-uuid>"
            }
          ]
        }
      ]
    }
  ],
  "other_project": null,
  "active_workspace_id": "<ws-uuid>"
}
```

### New event: `project.updated`

Pushed via `BridgeEventRelay` whenever `SidebarProjectManager.rebuild()` completes. Payload is the full `project.list` response (tree is small — full replacement is simpler than diffing).

### Implementation notes (Swift side)

- Add `project.list` handler in `TerminalController.swift` alongside existing `v2WorkspaceList()`
- Serialize `SidebarProjectManager.shared.projects` and `.otherProject` into the response shape above
- **Notification counts:** `SidebarProjectManager` does not track notification counts. The `project.list` handler must query `TerminalNotificationStore` by workspace ID to populate `notification_count` for each workspace entry.
- **`project.updated` notification coalescing:** `SidebarProjectManager.rebuild()` is coalesced via `scheduleRebuild()` with `DispatchQueue.main.async`. The bridge notification must fire after the coalesced rebuild completes, not on every `scheduleRebuild()` call. Post the notification at the end of `rebuild()`, not in `scheduleRebuild()`.
- Register `project.updated` observer in `BridgeEventRelay.registerObservers()`

### `other_project` shape (when non-null)

Same shape as a regular project entry. The "Other" section has a single branch with an empty-string name (`""`). Mobile must skip rendering the branch row when `branch.name.isEmpty` and render workspaces directly under the project header.

```json
{
  "other_project": {
    "id": "<uuid>",
    "name": "Other",
    "repo_path": "",
    "is_expanded": true,
    "is_auto_created": false,
    "is_other_section": true,
    "order": 999,
    "branches": [
      {
        "name": "",
        "is_dirty": false,
        "is_expanded": true,
        "workspaces": [
          {"id": "<ws-uuid>", "title": "scratch pad", "notification_count": 0, "panels": []}
        ],
        "linked_terminals": []
      }
    ]
  }
}
```

---

## 2. Mobile Data Model (Dart)

### New models

```dart
class SidebarProject {
  final String id;
  final String name;
  final String repoPath;
  bool isExpanded;
  final bool isAutoCreated;
  final int order;
  final List<SidebarBranch> branches;
  final bool isOtherSection;

  factory SidebarProject.fromJson(Map<String, dynamic> json);
}

class SidebarBranch {
  final String name;
  bool isDirty;
  bool isExpanded;
  final List<Workspace> workspaces;
  final List<LinkedTerminalEntry> linkedTerminals;

  factory SidebarBranch.fromJson(Map<String, dynamic> json);
}

class LinkedTerminalEntry {
  final String id;
  final String owningWorkspaceId;
  final String owningProjectName;
  final String owningWorkspaceName;
  final String panelId;

  factory LinkedTerminalEntry.fromJson(Map<String, dynamic> json);
}
```

### Riverpod provider

New `ProjectHierarchyNotifier` (StateNotifier):
- Fetches via `project.list` on connect
- Updates on `project.updated` events from bridge
- Stores expand/collapse state locally (mobile can toggle independently of desktop)
- Exposes `activeWorkspaceId` for highlight

Existing `WorkspaceNotifier` continues to handle active workspace tracking, PTY subscription, and panel management. `ProjectHierarchyNotifier` is purely for drawer rendering. Selecting a workspace in the drawer calls `workspaceProvider.selectWorkspace()` as before.

**Initialization:** On connect, the mobile app calls `project.list` (for drawer tree) and `workspace.list` (for PTY/panel management). Both calls are needed — they serve different purposes. `project.list` is the drawer's data source; `workspace.list` populates the workspace notifier for terminal interaction.

**Expand/collapse sync:** Mobile uses the desktop's `is_expanded` values as initial state on first load, then stores overrides locally. If the user collapses a project on mobile, that state persists on mobile even if the desktop has it expanded. Desktop state is only used when a brand-new project appears that mobile hasn't seen before.

**Loading state:** While `project.list` is pending, the drawer shows a subtle shimmer placeholder (3 skeleton rows at project/branch/workspace indents). If `project.list` fails or is unavailable (older desktop version), fall back to flat `workspace.list` rendering (existing behavior).

---

## 3. Drawer UI Structure

```
+-----------------------------+
| PROJECTS              [mag] |  <- Header + search toggle
+-----------------------------+
| [v] [C] cmux               |  <- Project: chevron + monogram + name
|   [v] Y main            [+]|  <- Branch: chevron + fork + name + add
|     * dev server        [2] |  <- Workspace: dot + name + badge (ACTIVE)
|     * frontend work         |  <- Workspace: dot + name
|   [>] Y feature/sidebar o +|  <- Branch: collapsed, dirty dot
|-----------------------------|  <- 1px separator
| [v] [C] conductor          |
|   [v] Y main            [+]|
|     * workspace 1           |
|     link shared from cmux/..|  <- Linked terminal
|   [v] Y fix/auth        o +|
|     * auth testing          |
|-----------------------------|
| [v] [O] Other               |  <- "Other" section (de-emphasized)
|     * scratch pad           |
+-----------------------------+
|  [Dark] [Light]             |  <- Theme toggle (unchanged)
|  gear Settings              |  <- Settings (unchanged)
+-----------------------------+
```

### What stays the same
- Frosted glass backdrop blur (40px sigma, saturation 1.3)
- 280px drawer width (matches existing implementation in `theme.dart`)
- Dark/Light toggle
- Settings button
- Overall color scheme and typography system

### What changes
- Header: "WORKSPACES" -> "PROJECTS"
- Flat workspace list -> nested project/branch/workspace tree
- Bottom "+" New Workspace button removed (replaced by per-branch (+))
- Search bar becomes a toggle (search icon in header, tap to expand search field)

---

## 4. Visual Hierarchy Specification

Five-channel differentiation across the three hierarchy levels:

### Level 1: Project Row

| Property | Value |
|---|---|
| Font family | JetBrains Mono |
| Font size | 13px |
| Font weight | 600 |
| Letter spacing | -0.2px |
| Color (dark) | `#E8E8EE` (100% textPrimary) |
| Color (light) | `#1A1A1F` (100% textPrimary) |
| Left padding | 8px (from list edge) |
| Vertical padding | 10px top, 8px bottom |
| Min height | 38px (implicit from padding + icon) |
| Border radius | 6px |

**Monogram icon:**
- Size: 22x22px, border-radius 5px
- Font: JetBrains Mono 700, 11px, uppercase first letter
- Dark: `rgba(232,232,238,0.06)` bg, `rgba(232,232,238,0.50)` text
- Light: `rgba(26,26,31,0.06)` bg, `rgba(26,26,31,0.45)` text
- Margin-right: 8px

**Chevron:**
- Width: 16px, font-size: 8px
- Dark: `rgba(232,232,238,0.25)`, Light: `rgba(26,26,31,0.25)`
- Collapsed: rotate(-90deg), transition 0.2s cubic-bezier(0.4, 0, 0.2, 1)

**Project separator:**
- 1px rule above non-first projects
- Margin: 10px horizontal, 2px bottom
- Dark: `rgba(255,255,255,0.05)`, Light: `rgba(0,0,0,0.04)`

**"Other" section variant:**
- Font weight: 500 (lighter)
- Dark: `rgba(232,232,238,0.35)`, Light: `rgba(26,26,31,0.35)`
- Monogram icon bg at 3% opacity (more subtle)

### Level 2: Branch Row

| Property | Value |
|---|---|
| Font family | IBM Plex Mono |
| Font size | 11.5px |
| Font weight | 500 |
| Color (dark) | `rgba(232,232,238,0.48)` |
| Color (light) | `rgba(26,26,31,0.48)` |
| Left padding | 24px |
| Vertical padding | 5px top, 5px bottom |
| Min height | 30px |
| Border radius | 5px |

**Fork icon (Y):**
- Font size: 12px, margin-right: 4px
- Dark: `rgba(232,232,238,0.30)`, Light: `rgba(26,26,31,0.30)`

**Chevron:**
- Width: 14px (smaller than project), font-size: 7px
- Dark: `rgba(232,232,238,0.20)`, Light: `rgba(26,26,31,0.20)`

**Dirty dot:**
- Size: 5x5px, color: `#E0A030`
- Box-shadow: `0 0 4px rgba(224,160,48,0.4)` (subtle glow)
- Margin-left: 5px

**Add (+) button:**
- Size: 18x18px, border-radius: 4px
- Font: IBM Plex Sans 400, 13px
- Opacity: 0.5
- Dark text: `rgba(232,232,238,0.30)`, Light: `rgba(26,26,31,0.30)`

### Level 3: Workspace Row

| Property | Value |
|---|---|
| Font family | IBM Plex Sans |
| Font size | 13px |
| Font weight (inactive) | 400 |
| Font weight (active) | 600 |
| Color inactive (dark) | `rgba(232,232,238,0.50)` |
| Color inactive (light) | `rgba(26,26,31,0.50)` |
| Color active (dark) | `#E8E8EE` (100% textPrimary) |
| Color active (light) | `#1A1A1F` (100% textPrimary) |
| Left padding | 42px |
| Vertical padding | 8px |
| Min height | 36px |
| Border radius | 5px (inactive), 0 5px 5px 0 (active) |

**Active state:**
- 3px amber left border (`#E0A030`)
- Background: `rgba(224,160,48,0.06)` (both themes)
- Padding-left compensated: 39px (42 - 3)

**Dot indicator (before workspace name):**
- Size: 4x4px circle, margin-right: 8px
- Active (dark): `#E0A030` with `box-shadow: 0 0 6px rgba(224,160,48,0.5)`
- Active (light): `#B07810`
- Inactive (dark): `rgba(232,232,238,0.15)`
- Inactive (light): `rgba(26,26,31,0.12)`

**Notification badge:**
- Min-width: 18px, height: 18px, border-radius: 9px
- Background: `#E0A030`, color: white
- Font: IBM Plex Sans 700, 10px
- Padding: 0 5px (pill shape for 2+ digit counts)

### Level 3b: Linked Terminal Row

| Property | Value |
|---|---|
| Font family | IBM Plex Sans |
| Font size | 11px |
| Font style | italic |
| Font weight | 400 |
| Color (dark) | `rgba(232,232,238,0.22)` |
| Color (light) | `rgba(26,26,31,0.22)` |
| Left padding | 42px (same as workspace) |
| Min height | 28px |
| Gap | 6px (between icon and text) |

**Link icon:**
- Font size: 10px, opacity: 0.7
- Dark: `rgba(232,232,238,0.20)`, Light: `rgba(26,26,31,0.20)`

### Indent Rhythm

```
  8px    Project (monogram icon provides visual mass)
 24px    Branch (+16px step)
 42px    Workspace (+18px step)
```

The slight increase at workspace level compensates for the visual weight of the project monogram icon.

---

## 5. Search Behavior

- Search icon in header toggles a search field below the header
- Active search icon: amber-tinted background `rgba(224,160,48,0.15)`, amber color
- Search field: 32px height, `bgSurface` fill, `borderStrong` border, 6px radius
- Filters across all levels: project names, branch names, workspace titles
- Case-insensitive substring matching (e.g., "cm" matches "cmux", "auth" matches "fix/auth")
- Shows matching subtrees: when a workspace matches, its parent branch and project are shown. When a branch matches, all its workspaces are shown.
- Match text highlighted in accent color (`#E0A030` dark, `#B07810` light)
- Debounced at 150ms to avoid excessive rebuilds during fast typing
- Clearing search restores full tree with preserved expand/collapse state

---

## 6. Notification Badge Bubbling

When a project or branch is collapsed, notification counts from child workspaces bubble up:
- Collapsed project: shows aggregate notification badge on the project row
- Collapsed branch: shows aggregate notification badge on the branch row
- Counts are summed from all descendant workspaces
- Bubbling is computed in the UI layer by summing child workspace `notification_count` values — no extra fields needed in the data model

---

## 7. Interactions

| Action | Behavior |
|---|---|
| Tap project row | Toggle expand/collapse |
| Tap branch row | Toggle expand/collapse |
| Tap workspace row | Select workspace, close drawer, switch to that workspace |
| Tap linked terminal | Select owning workspace, close drawer, focus the linked panel's tab |
| Tap branch (+) | Create new workspace via `workspace.create` with `cwd` set to the project's `repo_path`. **Known limitation:** the desktop `workspace.create` command does not accept a branch parameter — the new workspace will open a shell in the repo root and the branch will be whatever the repo is currently on. |
| Tap search icon | Toggle search field visibility |

---

## 8. File Changes

### Swift (bridge side)
- `Sources/TerminalController.swift` — Add `project.list` command handler, query `TerminalNotificationStore` for workspace notification counts
- `Sources/Bridge/BridgeEventRelay.swift` — Register `project.updated` observer
- `Sources/SidebarProjectManager.swift` — Post notification after coalesced `rebuild()` completes

### Dart (mobile side)
- `lib/state/project_hierarchy_provider.dart` — New: Riverpod notifier + state + models
- `lib/workspace/workspace_drawer.dart` — Rewrite: project hierarchy tree replaces flat list
- `lib/workspace/workspace_tile.dart` — Kept but only used within hierarchy context
- `lib/workspace/project_row.dart` — New: project header with monogram icon
- `lib/workspace/branch_row.dart` — New: branch row with fork icon, dirty dot, (+) button
- `lib/workspace/linked_terminal_row.dart` — New: linked terminal entry
- `lib/state/event_handler.dart` — Handle `project.updated` events

---

## 9. Visual Reference

Approved mockup: `.superpowers/brainstorm/sidebar-hierarchy-v2.html`

---

## 10. Deferred Features

- **Drag-to-reorder projects:** Desktop supports manual project reordering via drag. Mobile reorder (long-press-to-reorder) is deferred to a future iteration.
- **Branch-targeted workspace creation:** The (+) button creates a workspace with the project's `repo_path` as cwd, but cannot target a specific branch. If the repo is on a different branch than the one shown, the new workspace will appear under whichever branch the shell reports.
