# Sidebar Project Hierarchy: Development Architecture

## Overview

The sidebar project hierarchy groups workspaces by git repository in a tree: Project -> Branch -> Workspace. It is a presentation-layer mapping that does not own or modify workspaces.

## Key Files

| File | Purpose |
|------|---------|
| `Sources/SidebarProjectManager.swift` | Core rebuild logic, workspace-to-project grouping, sticky assignment |
| `Sources/SidebarProjectModel.swift` | Data models: `SidebarProject`, `SidebarBranch`, `SidebarLinkedTerminalEntry` |
| `Sources/ContentView.swift` (lines ~10565-10807) | SwiftUI rendering: `SidebarProjectSection`, branch rows, linked terminal rows |
| `Sources/Workspace.swift` | Per-panel data: `panelGitRoots`, `panelGitBranches`, `panelDirectories` |
| `Sources/TerminalController.swift` | Socket command handlers: `report_git_branch`, `report_pwd` |

## Architecture Decisions

### Sticky Project Assignment (2026-03-21)

**Problem**: `workspace.gitRoot` follows the focused panel. When a user splits a pane and cd's into a different repo, focusing that pane updates `workspace.gitRoot` to the new repo. This caused the workspace to flip between projects on every focus change.

**Solution**: `stickyAssignment` in `SidebarProjectManager` preserves a workspace's project assignment. Once assigned, the workspace stays under its original project as long as at least one panel remains in that repo. The sticky assignment is only overwritten when:
- The workspace has no previous sticky assignment (first-time assignment)
- The reported root matches the sticky root (same project, no conflict)
- No panels remain in the sticky repo (all panels migrated)

Helper methods `workspaceHasPanelInRepo()` and `branchForPanelInRepo()` inspect per-panel data to determine repo presence and branch state.

### panelGitRoots Pruning (2026-03-21)

**Problem**: `Workspace.pruneSurfaceMetadata()` pruned `panelGitBranches` but NOT `panelGitRoots`. Stale entries for dead panels could generate phantom linked terminal entries.

**Fix**: Added `panelGitRoots` to the pruning list alongside `panelGitBranches`.

## Data Flow

```
Shell integration detects CWD/git change
  -> report_pwd / report_git_branch (socket command)
  -> TerminalController handler
  -> Workspace.panelDirectories / panelGitRoots / panelGitBranches (Published)
  -> SidebarProjectManager observes via Combine
  -> scheduleRebuild() -> rebuild()
  -> projects / otherProject (Published)
  -> SwiftUI re-renders sidebar
```

## Linked Terminal Detection

Two-pass algorithm in `rebuild()`:

1. **First pass**: Check `panelGitRoots[panelId]` — explicit git roots from modern shell integration. If different from workspace root, create linked entry.

2. **Second pass**: Check `panelDirectories[panelId]` — fallback for old shell integration. Skip subdirectories of the same repo. Requires a git branch (from panel or workspace) to create an entry.

Linked entries are grouped into auto-created projects, which are cleaned up when empty.
