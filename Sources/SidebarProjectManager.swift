import Foundation
import Combine

// MARK: - SidebarProjectManager
//
// Derives the Project → Branch → Workspace sidebar tree from
// the flat TabManager.tabs array. This is a presentation-layer
// mapping — it does not own or modify workspaces.
//
// Data sources:
//   - workspace.gitRoot / panelGitRoots  (reported by shell integration)
//   - workspace.gitBranch / panelGitBranches
//   - workspace.currentDirectory / panelDirectories
//
// The tree rebuilds reactively via Combine whenever any of these change.

@MainActor
final class SidebarProjectManager: ObservableObject {
    @Published var projects: [SidebarProject] = []
    @Published var otherProject: SidebarProject?

    private weak var tabManager: TabManager?
    private var tabsSubscription: AnyCancellable?
    private var workspaceSubscriptions: [UUID: [AnyCancellable]] = [:]
    private var rebuildScheduled = false

    // MARK: - Attach to TabManager

    /// Begin observing workspace state. Call once after TabManager is created.
    func attach(to tabManager: TabManager) {
        self.tabManager = tabManager

        // Observe workspace list changes (add/remove/reorder).
        tabsSubscription = tabManager.$tabs
            .sink { [weak self] _ in
                self?.scheduleRebuild()
            }

        scheduleRebuild()
    }

    // MARK: - Rebuild Scheduling

    /// Coalesce rapid-fire updates into a single rebuild per run loop cycle.
    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    // MARK: - Core Rebuild

    /// Synchronous rebuild for use in tests. Bypasses the coalesced scheduling.
    func rebuildNow() {
        rebuildScheduled = false
        rebuild()
    }

    /// Derive the project tree from current workspace state.
    /// Preserves existing expand/collapse state and project ordering.
    private func rebuild() {
        guard let tabManager else { return }

        // Snapshot existing state for preservation.
        let existingProjects = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.repoPath, $0) }
        )
        let existingOther = otherProject

        // Track which workspaces we've seen to update subscriptions.
        var seenWorkspaceIds = Set<UUID>()

        // Group workspaces by git root.
        // Key: git root path (absolute). Value: [(workspace, branch, isDirty)].
        struct WorkspaceEntry {
            let workspaceId: UUID
            let branch: String
            let isDirty: Bool
        }
        var projectGroups: [String: [WorkspaceEntry]] = [:]
        var otherWorkspaceIds: [UUID] = []

        // Multi-repo tracking: workspaces with panels in different repos.
        struct LinkedEntry {
            let repoPath: String
            let branch: String
            let isDirty: Bool
            let owningWorkspaceId: UUID
            let owningProjectRepoPath: String
            let owningWorkspaceName: String
            let panelId: UUID
        }
        var linkedEntries: [LinkedEntry] = []

        for workspace in tabManager.tabs {
            seenWorkspaceIds.insert(workspace.id)
            subscribeToWorkspace(workspace)

            // Determine primary git root and branch.
            let primaryRoot = workspace.gitRoot
            let primaryBranch = workspace.gitBranch?.branch
            let primaryDirty = workspace.gitBranch?.isDirty ?? false

            guard let root = primaryRoot, let branch = primaryBranch else {
                // No git info — goes to "Other" section.
                otherWorkspaceIds.append(workspace.id)
                continue
            }

            let entry = WorkspaceEntry(
                workspaceId: workspace.id,
                branch: branch,
                isDirty: primaryDirty
            )
            projectGroups[root, default: []].append(entry)

            // Check for multi-repo panels.
            for (panelId, panelRoot) in workspace.panelGitRoots {
                guard panelRoot != root else { continue }
                let panelBranch = workspace.panelGitBranches[panelId]
                linkedEntries.append(LinkedEntry(
                    repoPath: panelRoot,
                    branch: panelBranch?.branch ?? "unknown",
                    isDirty: panelBranch?.isDirty ?? false,
                    owningWorkspaceId: workspace.id,
                    owningProjectRepoPath: root,
                    owningWorkspaceName: workspace.customTitle ?? workspace.title,
                    panelId: panelId
                ))
            }
        }

        // Build project list.
        var newProjects: [SidebarProject] = []

        for (repoPath, entries) in projectGroups {
            let existing = existingProjects[repoPath]
            let projectName = projectNameFromPath(repoPath)

            // Preserve existing branch expand states.
            let existingBranches = existing.map {
                Dictionary(uniqueKeysWithValues: $0.branches.map { ($0.name, $0) })
            } ?? [:]

            // Group entries by branch.
            var branchGroups: [String: (isDirty: Bool, workspaceIds: [UUID])] = [:]
            for entry in entries {
                var group = branchGroups[entry.branch] ?? (isDirty: false, workspaceIds: [])
                if entry.isDirty { group.isDirty = true }
                group.workspaceIds.append(entry.workspaceId)
                branchGroups[entry.branch] = group
            }

            // Build branches, preserving order of existing branches.
            var branches: [SidebarBranch] = []
            for (branchName, group) in branchGroups.sorted(by: { $0.key < $1.key }) {
                let existingBranch = existingBranches[branchName]
                branches.append(SidebarBranch(
                    id: existingBranch?.id ?? UUID(),
                    name: branchName,
                    isDirty: group.isDirty,
                    isExpanded: existingBranch?.isExpanded ?? true,
                    workspaceIds: group.workspaceIds,
                    linkedTerminals: []  // filled below
                ))
            }

            let project = SidebarProject(
                id: existing?.id ?? UUID(),
                name: projectName,
                repoPath: repoPath,
                isExpanded: existing?.isExpanded ?? true,
                branches: branches,
                order: existing?.order ?? newProjects.count
            )
            newProjects.append(project)
        }

        // Process linked terminal entries — add to auto-created projects.
        for linked in linkedEntries {
            let owningProjectName = projectNameFromPath(linked.owningProjectRepoPath)

            // Find or create the auto-project for this repo.
            var project = newProjects.first(where: { $0.repoPath == linked.repoPath })
            if project == nil {
                let existing = existingProjects[linked.repoPath]
                project = SidebarProject(
                    id: existing?.id ?? UUID(),
                    name: projectNameFromPath(linked.repoPath),
                    repoPath: linked.repoPath,
                    isExpanded: existing?.isExpanded ?? true,
                    branches: [],
                    order: existing?.order ?? newProjects.count,
                    isAutoCreated: true
                )
                newProjects.append(project!)
            }

            // Find or create the branch within the project.
            let linkedTerminal = SidebarLinkedTerminalEntry(
                owningWorkspaceId: linked.owningWorkspaceId,
                owningProjectName: owningProjectName,
                owningWorkspaceName: linked.owningWorkspaceName,
                panelId: linked.panelId
            )

            if let branchIdx = project!.branches.firstIndex(where: { $0.name == linked.branch }) {
                project!.branches[branchIdx].linkedTerminals.append(linkedTerminal)
            } else {
                let existingBranch = existingProjects[linked.repoPath]?
                    .branches.first(where: { $0.name == linked.branch })
                var branch = SidebarBranch(
                    id: existingBranch?.id ?? UUID(),
                    name: linked.branch,
                    isDirty: linked.isDirty,
                    isExpanded: existingBranch?.isExpanded ?? true
                )
                branch.linkedTerminals.append(linkedTerminal)
                project!.branches.append(branch)
            }

            // Update in the array.
            if let idx = newProjects.firstIndex(where: { $0.repoPath == linked.repoPath }) {
                newProjects[idx] = project!
            }
        }

        // Clean up auto-created projects that have no linked terminals.
        newProjects.removeAll { project in
            project.isAutoCreated
                && project.branches.allSatisfy { $0.linkedTerminals.isEmpty && $0.workspaceIds.isEmpty }
        }

        // Sort by persisted order.
        newProjects.sort { $0.order < $1.order }

        // Build "Other" section for non-git workspaces.
        if otherWorkspaceIds.isEmpty {
            otherProject = nil
        } else {
            let branch = SidebarBranch(
                id: existingOther?.branches.first?.id ?? UUID(),
                name: "",
                isExpanded: existingOther?.branches.first?.isExpanded ?? true,
                workspaceIds: otherWorkspaceIds
            )
            if let existing = existingOther {
                existing.branches = [branch]
                otherProject = existing
            } else {
                otherProject = SidebarProject(
                    id: UUID(),
                    name: String(localized: "sidebar.project.other", defaultValue: "Other"),
                    repoPath: "",
                    isExpanded: existingOther?.isExpanded ?? true,
                    branches: [branch],
                    order: Int.max,
                    isOtherSection: true
                )
            }
        }

        projects = newProjects

        // Prune subscriptions for removed workspaces.
        let removedIds = Set(workspaceSubscriptions.keys).subtracting(seenWorkspaceIds)
        for id in removedIds {
            workspaceSubscriptions.removeValue(forKey: id)
        }
    }

    // MARK: - Workspace Observation

    /// Subscribe to changes on a workspace that affect project grouping.
    private func subscribeToWorkspace(_ workspace: Workspace) {
        guard workspaceSubscriptions[workspace.id] == nil else { return }

        var subs: [AnyCancellable] = []

        // Rebuild when git branch changes (workspace may move between branches).
        workspace.$gitBranch
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &subs)

        // Rebuild when git root changes (workspace may move between projects).
        workspace.$gitRoot
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &subs)

        // Rebuild when panel git roots change (multi-repo detection).
        workspace.$panelGitRoots
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &subs)

        // Rebuild when panel git branches change (linked terminal branch/dirty).
        workspace.$panelGitBranches
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &subs)

        // Rebuild when current directory changes (may affect "Other" grouping).
        workspace.$currentDirectory
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &subs)

        workspaceSubscriptions[workspace.id] = subs
    }

    // MARK: - Queries

    /// All workspace UUIDs in sidebar display order, for ⌘+number shortcuts.
    func flatWorkspaceOrder() -> [UUID] {
        var result: [UUID] = []
        for project in projects {
            for branch in project.branches {
                result.append(contentsOf: branch.workspaceIds)
            }
        }
        if let other = otherProject {
            for branch in other.branches {
                result.append(contentsOf: branch.workspaceIds)
            }
        }
        return result
    }

    /// Find which project and branch a workspace belongs to.
    func location(for workspaceId: UUID) -> (SidebarProject, SidebarBranch)? {
        for project in projects {
            for branch in project.branches {
                if branch.workspaceIds.contains(workspaceId) {
                    return (project, branch)
                }
            }
        }
        if let other = otherProject {
            for branch in other.branches {
                if branch.workspaceIds.contains(workspaceId) {
                    return (other, branch)
                }
            }
        }
        return nil
    }

    /// Reorder projects via drag-and-drop.
    func moveProject(from source: IndexSet, to destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        for (index, project) in projects.enumerated() {
            project.order = index
        }
    }

    // MARK: - Session Persistence

    /// Create a snapshot of the project tree for session persistence.
    func sessionSnapshot(tabManager: TabManager) -> [SessionProjectSnapshot] {
        let workspaceIndexMap = Dictionary(
            uniqueKeysWithValues: tabManager.tabs.enumerated().map { ($1.id, $0) }
        )
        return projects.map { project in
            SessionProjectSnapshot(
                name: project.name,
                repoPath: project.repoPath,
                isExpanded: project.isExpanded,
                order: project.order,
                isAutoCreated: project.isAutoCreated,
                branches: project.branches.map { branch in
                    SessionBranchSnapshot(
                        name: branch.name,
                        isExpanded: branch.isExpanded,
                        workspaceIndices: branch.workspaceIds.compactMap { workspaceIndexMap[$0] }
                    )
                }
            )
        }
    }

    /// Restore project tree state from a session snapshot.
    /// Applies expand/collapse state and ordering from the snapshot,
    /// then triggers a rebuild to reconcile with actual workspace state.
    func restoreFromSnapshot(_ snapshots: [SessionProjectSnapshot]?, tabManager: TabManager) {
        guard let snapshots, !snapshots.isEmpty else {
            // Old session without project hierarchy — rebuild will auto-detect.
            scheduleRebuild()
            return
        }

        // Pre-populate projects with saved expand/collapse state and ordering.
        // The rebuild will reconcile workspace membership from actual git data.
        var restoredProjects: [SidebarProject] = []
        for snapshot in snapshots {
            let branches = snapshot.branches.map { branchSnap in
                let workspaceIds = branchSnap.workspaceIndices.compactMap { index -> UUID? in
                    guard index < tabManager.tabs.count else { return nil }
                    return tabManager.tabs[index].id
                }
                return SidebarBranch(
                    name: branchSnap.name,
                    isExpanded: branchSnap.isExpanded,
                    workspaceIds: workspaceIds
                )
            }
            let project = SidebarProject(
                name: snapshot.name,
                repoPath: snapshot.repoPath,
                isExpanded: snapshot.isExpanded,
                branches: branches,
                order: snapshot.order,
                isAutoCreated: snapshot.isAutoCreated
            )
            restoredProjects.append(project)
        }

        projects = restoredProjects
        // Schedule a rebuild to reconcile with actual workspace git state
        // once shell integration reports in.
        scheduleRebuild()
    }

    // MARK: - Recent Projects

    private static let recentProjectsKey = "sidebarRecentProjectPaths"
    private static let maxRecentProjects = 20

    static func addRecentProjectPath(_ path: String) {
        var paths = recentProjectPaths()
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > maxRecentProjects {
            paths = Array(paths.prefix(maxRecentProjects))
        }
        UserDefaults.standard.set(paths, forKey: recentProjectsKey)
    }

    static func recentProjectPaths() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentProjectsKey) ?? []
    }

    // MARK: - Helpers

    /// Extract the folder name from a git root path for display.
    private func projectNameFromPath(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
