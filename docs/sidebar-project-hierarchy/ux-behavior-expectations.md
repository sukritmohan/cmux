# Sidebar Project Hierarchy: UX Behavior Expectations

## Multi-Repo Workspace Behavior

When a workspace has terminal panes in multiple git repositories, the sidebar displays each repo as a separate project section.

### Project Assignment Rules

1. **Initial assignment**: A workspace is assigned to the project of the first git repo it reports (via shell integration's `report_git_branch --root=`).

2. **Sticky assignment**: Once assigned, a workspace stays under its original project as long as at least one panel remains in that repo. Switching focus between panels in different repos does NOT move the workspace between projects.

3. **Migration**: The workspace moves to a new project only when ALL panels have left the original repo (e.g., all panels cd'd to a different repo, or original-repo panels closed).

### Linked Terminal Display

When a panel in a workspace is cd'd into a different git repo:

- The different repo auto-appears as a **separate project section** in the sidebar
- Under that project section, a **linked terminal entry** appears showing "shared from [original project] / [workspace name]"
- Clicking the linked terminal entry navigates back to the owning workspace
- The workspace row may also show `+ ~/path` metadata indicating non-parent directories

### Auto-Created Projects

Projects created from linked terminals:
- Are marked `isAutoCreated = true`
- Are automatically removed when their last linked terminal disappears
- Show the repo folder name as the project name
- Show branch and dirty status from the linked panel

### Examples

**Single workspace, two repos:**
```
conductor         (original project - workspace stays here)
  main
    workspace 1   (+ ~/code)

~/code            (auto-created from linked terminal)
  main
    shared from conductor / workspace 1
```

**Three repos in one workspace:**
```
conductor         (original project)
  develop
    full-stack debug  (+ ~/code/api, ~/code/web)

api               (auto-created)
  develop
    shared from conductor / full-stack debug

web               (auto-created)
  main
    shared from conductor / full-stack debug
```

**Single repo (no extra metadata):**
```
cmux
  main
    dev server
    frontend work
  feature/sidebar
    sidebar testing
```

## Metadata Display

- `sidebarParentProjectPath` is set on each workspace to its primary project's repo path
- Workspace rows filter out redundant branch/directory info that's already visible in the project hierarchy
- Only non-parent directories are shown with `+` prefix on workspace rows
