# Sidebar Project Hierarchy — Implementation Plan

## Overview

Transform the sidebar from a flat workspace list into a **Project → Branch → Workspace** tree hierarchy. This is a presentation-layer mapping on top of the existing `TabManager`/`Workspace` model, which remains unchanged.

**Spec:** `docs/superpowers/specs/2026-03-21-sidebar-project-hierarchy-design.md`

## Key Architecture Decision

The shell integration already reports `report_pwd` (directory) and `report_git_branch` (branch + dirty status) via the socket. Workspaces already have `currentDirectory` and `gitBranch` populated. The `SidebarProjectManager` groups workspaces using this **existing data** — no filesystem scanning or `git` process spawning needed.

**Git root derivation:** When a workspace reports its `currentDirectory` and `gitBranch`, we need the git root path to group it under a project. We use `git -C <dir> rev-parse --show-toplevel` (cached per directory) only for the initial mapping. Once a workspace is placed, subsequent updates come from the shell integration events.

## Files Summary

**New files (2):**
- `Sources/SidebarProjectModel.swift` — `SidebarProject`, `SidebarBranch`, `SidebarLinkedTerminalEntry`, session snapshot structs
- `Sources/SidebarProjectManager.swift` — core mapping logic, rebuild, caching

**Modified files:**
- `Sources/ContentView.swift` — replace flat ForEach (line ~7958) with nested project tree; add `SidebarProjectRow`, `SidebarBranchRow`, `SidebarLinkedTerminalRow` views
- `Sources/AppDelegate.swift` — add `SidebarProjectManager` to `MainWindowContext`, wire into session save/restore
- `Sources/TabManager.swift` — add `tab(for:)` lookup helper
- `Sources/SessionPersistence.swift` — add optional `projectHierarchy` to `SessionWindowSnapshot`
- `Sources/Localizable.xcstrings` — add localization keys for new UI strings
- `GhosttyTabs.xcodeproj/project.pbxproj` — add new source files
- `Resources/Info.plist` — add `com.cmux.sidebar-project-reorder` UTType for drag

---

## Chunk 1: Data Models + Xcode Config

### Task 1.1: Create SidebarProjectModel.swift

**File:** Create `Sources/SidebarProjectModel.swift`

**Contents:**
```swift
class SidebarProject: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String                    // repo folder name
    @Published var repoPath: String                // absolute path to git root
    @Published var isExpanded: Bool = true
    @Published var branches: [SidebarBranch]
    @Published var order: Int
    var isAutoCreated: Bool = false                 // true for linked-terminal auto-projects
    var isOtherSection: Bool = false                // true for non-git "Other" section
}

/// Value-type: mutations require replacing in parent array for @Published detection
struct SidebarBranch: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isDirty: Bool
    var isExpanded: Bool = true
    var workspaceIds: [UUID]
    var linkedTerminals: [SidebarLinkedTerminalEntry]
}

struct SidebarLinkedTerminalEntry: Identifiable, Equatable {
    let id: UUID
    let owningWorkspaceId: UUID
    let owningProjectName: String
    let owningWorkspaceName: String
    let panelId: UUID
}

// Session persistence snapshots (Codable)
struct SessionProjectSnapshot: Codable, Sendable {
    var name: String
    var repoPath: String
    var isExpanded: Bool
    var order: Int
    var isAutoCreated: Bool
    var branches: [SessionBranchSnapshot]
}

struct SessionBranchSnapshot: Codable, Sendable {
    var name: String
    var isExpanded: Bool
    var workspaceIndices: [Int]  // indices into SessionTabManagerSnapshot.workspaces
}
```

### Task 1.2: Add files to Xcode project

**File:** `GhosttyTabs.xcodeproj/project.pbxproj`
- Add `SidebarProjectModel.swift` and `SidebarProjectManager.swift` to Sources group and build phase

**File:** `Resources/Info.plist`
- Add `com.cmux.sidebar-project-reorder` UTType under `UTExportedTypeDeclarations`

**Complexity:** Small
**Dependencies:** None

---

## Chunk 2: SidebarProjectManager (Core Logic)

### Task 2.1: Create SidebarProjectManager.swift

**File:** Create `Sources/SidebarProjectManager.swift`

**Core class (~250-300 lines):**

```swift
class SidebarProjectManager: ObservableObject {
    @Published var projects: [SidebarProject] = []
    @Published var otherProject: SidebarProject?   // non-git workspaces

    private var gitRootCache: [String: String?] = [:]
    private var workspaceSubscriptions: [UUID: AnyCancellable] = [:]
    private var tabManagerSubscription: AnyCancellable?
    private weak var tabManager: TabManager?
}
```

**Key methods:**

- `attach(to: TabManager)` — subscribes to `tabManager.$tabs` and per-workspace `$gitBranch`, `$currentDirectory` via Combine. Each change triggers `rebuildIfNeeded()`.

- `rebuildIfNeeded()` — the core mapping:
  1. For each workspace, determine git root from `currentDirectory` (use cache, fall back to `git rev-parse`). Git root folder name = project name.
  2. Determine branch from `workspace.gitBranch?.branch`.
  3. Find or create `SidebarProject` for repo path. Preserve existing expand/collapsed state and order.
  4. Find or create `SidebarBranch` within project. Preserve expand state.
  5. Add workspace ID to branch's `workspaceIds`.
  6. No git root → "Other" section.
  7. Multi-repo detection: for workspaces with `panelDirectories` pointing to different git roots, primary panel determines project. Create auto-projects with linked terminal entries for others.
  8. Clean up: remove branches with no workspaces, projects with no branches.

- `gitRootPath(for directory: String) -> String?` — checks cache first. Cache miss: run `git -C <dir> rev-parse --show-toplevel` on a background queue, dispatch result to main. Cache by directory path.

- `location(for workspaceId: UUID) -> (SidebarProject, SidebarBranch)?`

- `flatWorkspaceOrder() -> [UUID]` — tree traversal: projects in order → branches in order → workspaceIds → then otherProject. Used for `⌘+number`.

- `moveProject(from: Int, to: Int)` — drag reorder, updates `order` values.

- `sessionSnapshot(tabManager: TabManager) -> [SessionProjectSnapshot]`

- `restoreFromSnapshot(_ snapshots: [SessionProjectSnapshot]?, tabManager: TabManager)` — if nil (old session), let auto-detection via `rebuildIfNeeded()` handle it.

- `addRecentProjectPath(_ path: String)` / `recentProjectPaths() -> [String]` — UserDefaults under `"sidebarRecentProjectPaths"`, capped at 20.

**Complexity:** Large
**Dependencies:** Chunk 1

---

## Chunk 3: Wire Into App Lifecycle

### Task 3.1: Add to MainWindowContext

**File:** `Sources/AppDelegate.swift`

- **`MainWindowContext` (line ~1900):** Add `let sidebarProjectManager: SidebarProjectManager` property.
- **`createMainWindow` (line ~5442):** After creating `TabManager`, create `SidebarProjectManager`, call `.attach(to: tabManager)`, inject via `.environmentObject()`.
- **`registerMainWindow` (line ~3415):** Pass `sidebarProjectManager` when constructing `MainWindowContext`.

### Task 3.2: Add to cmuxApp.swift

**File:** `Sources/cmuxApp.swift`

- Add `@StateObject` for `SidebarProjectManager` and `.environmentObject()` injection (lines ~54 and ~199).

**Complexity:** Small
**Dependencies:** Chunk 2

---

## Chunk 4: Sidebar Rendering + "Other" Section

### Task 4.1: Add new sidebar row views

**File:** `Sources/ContentView.swift` — insert before `TabItemView` (line ~10274)

Three new `private struct` views:

**`SidebarProjectRow`:**
- Disclosure chevron (custom, animated rotation — not DisclosureGroup, for full styling control)
- Project name text
- Precomputed `hasUnreadChildren: Bool` parameter → shows notification dot when collapsed
- Tap to toggle `project.isExpanded`
- No `@EnvironmentObject` — takes all values as `let` parameters

**`SidebarBranchRow`:**
- Indented under project (padding-left)
- Branch icon + name + dirty dot
- `@State var isHovering` → shows (+) button on hover (trailing edge)
- (+) button action: creates workspace under this branch via `tabManager.addWorkspace(workingDirectory: project.repoPath)`
- Tap name to toggle `branch.isExpanded`
- Precomputed `hasUnreadChildren: Bool` for notification bubble-up

**`SidebarLinkedTerminalRow`:**
- 🔗 icon + "shared from <project> / <workspace>"
- Tap navigates: `tabManager.selectedTabId = entry.owningWorkspaceId`, then focus panel

### Task 4.2: Replace flat ForEach

**File:** `Sources/ContentView.swift` — lines ~7958-8002

Replace with nested structure:
```
ForEach(sidebarProjectManager.projects) { project in
    SidebarProjectRow(...)
    if project.isExpanded {
        ForEach(project.branches) { branch in
            SidebarBranchRow(...)
            if branch.isExpanded {
                ForEach(branch.workspaceIds, id: \.self) { workspaceId in
                    // existing TabItemView with .equatable(), indented
                }
                // linked terminals for this branch
                ForEach(branch.linkedTerminals) { entry in
                    SidebarLinkedTerminalRow(...)
                }
            }
        }
    }
}
// "Other" section
if let otherProject = sidebarProjectManager.otherProject { ... }
```

**Critical constraints:**
- `TabItemView` keeps `.equatable()` — NO changes to its `==` function
- NO `@EnvironmentObject` on `TabItemView` — pass computed values as `let` params
- `workspaceShortcutDigit` (line ~7973) uses `sidebarProjectManager.flatWorkspaceOrder()` instead of flat enumeration
- Add `@EnvironmentObject var sidebarProjectManager: SidebarProjectManager` to `VerticalTabsSidebar` (line ~7921)

### Task 4.3: Add tab(for:) to TabManager

**File:** `Sources/TabManager.swift`

```swift
func tab(for workspaceId: UUID) -> Workspace? {
    tabs.first { $0.id == workspaceId }
}
```

### Task 4.4: Handle "Other" section in SidebarProjectManager

Already included in Task 2.1's `rebuildIfNeeded()`. The "Other" project has `isOtherSection = true`, no branch level — workspaces listed directly.

**Complexity:** Large
**Dependencies:** Chunk 3

---

## Chunk 5: Collapse/Expand + Notification Bubble-up + Branch Change

### Task 5.1: Collapse/expand animations

**File:** `Sources/ContentView.swift` — in `SidebarProjectRow` and `SidebarBranchRow`

- `Image(systemName: "chevron.right")` with `.rotationEffect(Angle(degrees: isExpanded ? 90 : 0))` and `.animation(.easeInOut(duration: 0.15))`
- Branch collapse: mutate `SidebarBranch.isExpanded` in `project.branches` array (struct replacement triggers `@Published`)

### Task 5.2: Notification bubble-up

**File:** `Sources/ContentView.swift` — in `VerticalTabsSidebar` body

Precompute in the parent view, pass down as `let` parameters:
```swift
let hasUnread = project.branches.flatMap(\.workspaceIds).contains {
    notificationStore.unreadCount(forTabId: $0) > 0
}
```

### Task 5.3: Branch change detection

**File:** `Sources/SidebarProjectManager.swift`

Already handled by `rebuildIfNeeded()` — when `workspace.$gitBranch` fires, the workspace moves to the new branch. Old empty branches/projects are cleaned up.

**Complexity:** Small
**Dependencies:** Chunk 4

---

## Chunk 6: (+) Button Popover + Branch Hover (+)

### Task 6.1: Project picker popover

**File:** `Sources/ContentView.swift` — new `SidebarNewProjectPopover` view (insert near line ~10057)

- Search field
- Recent projects from `SidebarProjectManager.recentProjectPaths()`
- "Browse for folder..." → `NSOpenPanel` directory picker
- On selection: `SidebarProjectManager.addRecentProjectPath(path)`, create workspace in TabManager with that cwd

### Task 6.2: Wire (+) button

**File:** `Sources/ContentView.swift` — modify the (+) icon in sidebar header

Replace current action with popover trigger.

### Task 6.3: Branch hover (+) — already in Task 4.1

Default workspace name generation: `"<branchName> (\(count + 1))"` where count = current workspaces under this branch.

**Complexity:** Medium
**Dependencies:** Chunk 4

---

## Chunk 7: Linked Terminal Entries

### Task 7.1: Multi-repo detection in rebuildIfNeeded()

**File:** `Sources/SidebarProjectManager.swift`

In the rebuild loop, for each workspace:
1. Check `workspace.panelDirectories` for directories with different git roots than primary
2. For each different root: find/create auto-project (`isAutoCreated = true`)
3. Add `SidebarLinkedTerminalEntry` to the matching branch in the auto-project

### Task 7.2: Linked terminal UI — already in Task 4.1

Click action: `tabManager.selectedTabId = entry.owningWorkspaceId`

### Task 7.3: Auto-project cleanup

In `rebuildIfNeeded()`: remove auto-projects whose linked terminals are all gone.

**Complexity:** Medium
**Dependencies:** Chunk 4

---

## Chunk 8: Session Persistence + Drag Reorder

### Task 8.1: Save project tree state

**File:** `Sources/SessionPersistence.swift`
- Add `var projectHierarchy: [SessionProjectSnapshot]?` to `SessionWindowSnapshot` (line ~350). Optional for backward compat.

**File:** `Sources/AppDelegate.swift`
- In `buildSessionSnapshot` (line ~3316): include `sidebarProjectManager.sessionSnapshot(tabManager:)`.

### Task 8.2: Restore project tree state

**File:** `Sources/AppDelegate.swift`
- In session restore path (line ~2590): call `sidebarProjectManager.restoreFromSnapshot(snapshot.projectHierarchy, tabManager:)`. If nil, auto-detect.

### Task 8.3: Project drag reorder

**File:** `Sources/ContentView.swift`

- `.onDrag` on `SidebarProjectRow` returning project ID payload
- `SidebarProjectDropDelegate` that reorders `sidebarProjectManager.projects`
- UTType `com.cmux.sidebar-project-reorder` (declared in Chunk 1)

### Task 8.4: Localization

**File:** `Resources/Localizable.xcstrings`

Add keys:
- `sidebar.project.other` → "Other"
- `sidebar.project.search` → "Search or add project..."
- `sidebar.project.browse` → "Browse for folder..."
- `sidebar.linked.shared_from` → "shared from %@ / %@"
- Any other new user-facing strings

**Complexity:** Medium
**Dependencies:** Chunks 3, 5

---

## Execution Order

```
Chunk 1 → Chunk 2 → Chunk 3 → Chunk 4 → Chunk 5 ─┐
                                          │         │
                                          ├─ Chunk 6
                                          ├─ Chunk 7
                                          └─ Chunk 8
```

Chunks 5, 6, 7, 8 can be partially parallelized after Chunk 4.

## Risks

1. **ContentView.swift size** — already 13K+ lines. New views add more. Consider extracting sidebar views into a separate file if it grows past 14K.
2. **Rebuild performance** — `rebuildIfNeeded()` runs on every git branch / directory change. Must be efficient. Diff against existing tree rather than full rebuild if >20 workspaces.
3. **Git root caching** — cache invalidation when directories change. Clear cache entry when workspace's `currentDirectory` changes.
4. **TabItemView invariants** — must NOT break `.equatable()` or add environment objects. The existing `==` function and `let` parameter pattern must be preserved exactly.
