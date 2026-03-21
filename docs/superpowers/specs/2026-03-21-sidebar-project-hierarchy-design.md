# Sidebar Project Hierarchy Redesign

## Summary

Reorganize the sidebar from a flat workspace list into a **Project → Branch → Workspace** tree hierarchy. This is a **presentation-layer change only** — the underlying workspace model, notification system, bridge events, and terminal management remain unchanged.

## Current State

The sidebar displays a flat list of workspaces (via `TabManager.tabs: [Workspace]`). Each workspace row shows its directory path, git branch, and metadata. Workspaces have no grouping concept.

```
~/code/cmux
  main • ~/code/cmux

~/code/conductor        (selected)
  main • ~/code/conductor
  main • ~/code
```

## New Design

### Hierarchy Structure

```
▾ cmux                          ← PROJECT (git repo name)
  ▾ ⎇ main                     ← BRANCH (click to collapse, hover shows +)
      dev server                ← WORKSPACE (current concept, unchanged)
      frontend work
  ▸ ⎇ feature/sidebar ●        ← BRANCH (collapsed, dirty indicator)

▾ conductor
  ▾ ⎇ main
      workspace 1               ← multi-repo workspace
        + ~/code                ← only shows non-parent directories
  ▾ ⎇ fix/auth ●
      auth testing

▾ ~/code                        ← AUTO project (from shared terminal)
  ▾ ⎇ main
      🔗 terminal 2             ← shared terminal, same process
        shared from conductor / workspace 1
```

### Visual Behavior

| Element | Collapsed state | Expanded state | Interaction |
|---------|----------------|----------------|-------------|
| **Project row** | Just the project name | Shows child branches | Click to toggle expand/collapse |
| **Branch row** | Shows branch name + dirty dot | Shows child workspaces | Click name to collapse workspaces. Hover reveals (+) button on right to add workspace |
| **Workspace row** | — | Shows workspace name, blue highlight if active | Click to switch to this workspace. Standard right-click context menu |

- IDE-style disclosure triangles at project and branch levels
- Always show all 3 levels, even for single-workspace/single-branch projects
- One global active workspace at a time (blue selection highlight)
- Manual drag-to-reorder for projects; order persists across sessions
- `⌘+number` switches workspaces flat across all projects (unchanged from current)

### (+) Button → Add New Project

1. User clicks (+) in sidebar header
2. Popover appears with:
   - Search field ("Search or add project...")
   - **Recent Projects** section (git repos the user has opened before)
   - **Browse for folder...** option at bottom
3. Selecting a repo creates a project entry with one default workspace on the repo's current branch
4. Terminal opens with cwd set to the selected repo directory

### New Workspace Within a Branch

1. User hovers a branch row → small (+) button appears on right
2. Clicking it creates a new workspace under that branch
3. Default name: `<branch> (N)` — e.g., `main (1)`, `main (2)`
4. Terminal opens with cwd set to the project's root directory
5. User can rename via double-click or right-click → Rename

### Multi-Repo Workspaces

When a workspace has terminals in directories belonging to **different git repos**:

1. **Workspace stays under its original project/branch** (where it was created)
2. **Metadata shows only unrelated directories** — e.g., `+ ~/code` (the parent project's directory is implied)
3. **Each unrelated repo auto-creates a project entry** in the sidebar (if one doesn't already exist)
4. That auto-created project entry contains a **linked terminal** (🔗 icon) with label "shared from <project> / <workspace>"
5. The linked terminal is a **jump-to-source shortcut** — clicking it navigates to the original workspace and focuses the relevant pane
6. Full pane-sharing (rendering the same terminal process in two independent pane layouts) is deferred to a future iteration

## Architecture: Mapping Layer

### Core Principle

**No changes to Workspace, TabManager, TerminalNotificationStore, or BridgeEventRelay internals.** The project tree is a presentation-layer grouping computed from existing workspace data.

### New Data Model

```swift
/// Presentation-layer grouping for the sidebar. Does not own workspaces.
class SidebarProject: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String                    // repo folder name or path
    @Published var repoPath: String                // absolute path to git root
    @Published var isExpanded: Bool = true
    @Published var branches: [SidebarBranch]
    @Published var order: Int                      // manual sort order
}

/// Value-type by design: mutations require replacing the struct in the parent
/// array, which triggers @Published change detection in SidebarProject.
struct SidebarBranch: Identifiable {
    let id: UUID
    var name: String                               // branch name
    var isDirty: Bool
    var isExpanded: Bool = true
    var workspaceIds: [UUID]                       // references to Workspace UUIDs in TabManager
}

/// Manages the project tree derived from workspace state.
class SidebarProjectManager: ObservableObject {
    @Published var projects: [SidebarProject]

    /// Rebuilds the project tree from TabManager workspace state.
    /// Called when:
    /// - A workspace's git branch changes (report_git_branch)
    /// - A workspace's directory changes (report_pwd)
    /// - A workspace is created or closed
    func rebuildFromWorkspaces(_ workspaces: [Workspace]) { ... }

    /// Finds the project + branch for a given workspace UUID.
    func location(for workspaceId: UUID) -> (SidebarProject, SidebarBranch)?

    /// Returns all workspace UUIDs in flat order (for ⌘+number navigation).
    func flatWorkspaceOrder() -> [UUID]
}
```

### How Project Assignment Works

When a workspace reports its git info (via `report_git_branch` and `report_pwd` shell integration):

1. **Determine project**: Find the git root of the workspace's `currentDirectory`. The folder name of the git root becomes the project name.
2. **Determine branch**: Use the workspace's `gitBranch` state (already tracked via `SidebarGitBranchState`).
3. **Place in tree**: If a `SidebarProject` for this repo path exists, add the workspace under the matching branch. If not, create a new project entry.
4. **Multi-repo case**: If the workspace has panels in different repos (detected via `panelDirectories` + `panelGitBranches`), use the **first-reported / primary panel's** repo as the project. Create linked entries for other repos.

### What Stays Unchanged

| Component | Change? | Notes |
|-----------|---------|-------|
| `Workspace` model | **No** | Still the fundamental unit. All properties, panels, terminal management unchanged |
| `TabManager` | **No** | Still holds `tabs: [Workspace]` as flat array. Project grouping is a view layer on top |
| `TerminalNotificationStore` | **No** | Still keys by `tabId`. Sidebar renders notifications grouped by project |
| `BridgeEventRelay` | **No** | Still emits `workspace_id` in all events. No protocol changes |
| `TerminalController` socket commands | **No** | `report_git_branch`, `report_pwd`, etc. unchanged |
| Shell integration | **No** | Same socket commands, same data flow |
| `⌘+number` shortcuts | **No** | Computed from `flatWorkspaceOrder()` — same flat indexing |
| Workspace drag/drop | **No** | Workspaces can still be dragged; order within branch is drag-ordered |

### What Changes

| Component | Change | Scope |
|-----------|--------|-------|
| **Sidebar rendering** (`ContentView.swift` — `TabItemView`) | Replace flat `ForEach` over workspaces with nested `ForEach` over projects → branches → workspaces | Rendering only |
| **Session persistence** | Add `SidebarProjectSnapshot` wrapping workspace snapshots with project name, repo path, branch, order | Additive; old snapshots restore as single auto-detected project |
| **New: `SidebarProjectManager`** | New class computing project tree from workspace state | ~200-300 lines |
| **New: `SidebarProject` model** | Lightweight grouping container | ~50 lines |
| **(+) button** | Replace "new workspace" with "new project" popover | UI change |
| **Hover (+) on branch** | New hover interaction to create workspace within branch | UI addition |

## Edge Cases

### Notifications

- **Desktop**: Notification dots on workspace rows work exactly as today (keyed by `tabId`). When a project is collapsed, any workspace with unread notifications should cause the project row to show a notification indicator.
- **Mobile**: `surface.attention` events still carry `workspace_id`. Mobile increments notification count on the workspace. When mobile adopts this hierarchy, it groups the same way — no bridge protocol changes needed.
- **Linked terminals**: If a shared terminal triggers a notification, it fires on the **owning workspace's** `tabId`. The linked entry in the auto-created project should reflect this (read from the same notification store by workspace ID).

### Workspace Without Git

If a workspace has terminals not in any git repo (e.g., `cd /tmp`):
- Place under an **"Other"** project section at the bottom of the sidebar
- No branch level — just project → workspace

### Branch Changes

If a terminal switches branches (detected via `report_git_branch`):
- The workspace **moves** to the new branch within its project
- If the new branch doesn't exist in the project tree, create it
- If the old branch has no more workspaces, remove it from the tree

### App Restart / Session Restore

- Session persistence saves the project tree structure (project names, repo paths, branch assignments, ordering)
- On restore, rebuild from saved state; verify against actual git state on disk
- Old sessions (pre-project-hierarchy) restore with auto-detected projects from workspace directories

### Workspace Closed

- Remove from branch's workspace list
- If branch has no more workspaces, remove branch from project
- If project has no more branches, remove project from sidebar
- Linked terminal entries in auto-created projects are also cleaned up

### Multiple Windows

- Each window has its own `TabManager` and therefore its own `SidebarProjectManager`
- Projects are per-window, not global (consistent with current per-window workspace model)

## Out of Scope

- **Mobile adoption**: Mobile will replicate this later; this spec covers desktop only
- **Keyboard shortcut redesign**: `⌘+number` stays flat; project-level shortcuts deferred
- **Git worktree integration**: Branches in the tree come from `report_git_branch`, not filesystem worktree scanning
- **Shared terminal pane sharing**: Linked terminals are jump-to-source shortcuts in this iteration. Full pane-sharing (same terminal rendered in two independent layouts) deferred to follow-up

## Resolved Questions

1. **Shared terminal pane sharing**: Deferred. Linked entries act as **jump-to-source shortcuts** for now — clicking navigates to the owning workspace and focuses the relevant pane. Full pane-sharing (independent layouts for the same terminal process) will be a follow-up feature.
2. **Auto-created projects cleanup**: Auto-created projects are removed immediately when their last linked terminal is closed. They carry no user state worth preserving.
3. **Project row context menu**: Deferred to implementation — start without one and add if needed based on usage.
4. **Recent Projects data source**: Derived from session history — any project the user has previously opened via (+) is remembered. Persisted as a simple list of repo paths in app preferences.
5. **Default expand state**: Newly created projects and branches default to expanded (`isExpanded = true`).
