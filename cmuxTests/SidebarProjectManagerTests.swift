import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class SidebarProjectManagerTests: XCTestCase {

    // MARK: - Helpers

    private func makeManager(with tabManager: TabManager) -> SidebarProjectManager {
        let manager = SidebarProjectManager()
        manager.attach(to: tabManager)
        return manager
    }

    private func configureWorkspaceGit(
        _ workspace: Workspace,
        root: String,
        branch: String,
        isDirty: Bool = false
    ) {
        workspace.gitRoot = root
        workspace.gitBranch = SidebarGitBranchState(branch: branch, isDirty: isDirty)
    }

    // MARK: - 1. Basic Grouping

    func testWorkspaceWithGitRootGroupedUnderProject() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        configureWorkspaceGit(workspace, root: "/Users/sm/code/cmux", branch: "main")

        manager.rebuildNow()

        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.projects[0].name, "cmux")
        XCTAssertEqual(manager.projects[0].repoPath, "/Users/sm/code/cmux")
        XCTAssertEqual(manager.projects[0].branches.count, 1)
        XCTAssertEqual(manager.projects[0].branches[0].name, "main")
        XCTAssertEqual(manager.projects[0].branches[0].workspaceIds, [workspace.id])
    }

    func testMultipleWorkspacesSameRepoGroupedTogether() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let ws1 = tabManager.addWorkspace(select: false)
        let ws2 = tabManager.addWorkspace(select: false)
        configureWorkspaceGit(ws1, root: "/Users/sm/code/cmux", branch: "main")
        configureWorkspaceGit(ws2, root: "/Users/sm/code/cmux", branch: "main")

        manager.rebuildNow()

        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.projects[0].branches.count, 1)
        XCTAssertTrue(manager.projects[0].branches[0].workspaceIds.contains(ws1.id))
        XCTAssertTrue(manager.projects[0].branches[0].workspaceIds.contains(ws2.id))
    }

    func testWorkspacesDifferentReposCreateSeparateProjects() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let ws1 = tabManager.addWorkspace(select: false)
        let ws2 = tabManager.addWorkspace(select: false)
        configureWorkspaceGit(ws1, root: "/Users/sm/code/cmux", branch: "main")
        configureWorkspaceGit(ws2, root: "/Users/sm/code/conductor", branch: "main")

        manager.rebuildNow()

        XCTAssertEqual(manager.projects.count, 2)
        let projectNames = Set(manager.projects.map { $0.name })
        XCTAssertTrue(projectNames.contains("cmux"))
        XCTAssertTrue(projectNames.contains("conductor"))
    }

    // MARK: - 2. Branch Grouping

    func testWorkspacesSameRepoDifferentBranchesGroupedUnderSameProject() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let ws1 = tabManager.addWorkspace(select: false)
        let ws2 = tabManager.addWorkspace(select: false)
        configureWorkspaceGit(ws1, root: "/Users/sm/code/cmux", branch: "main")
        configureWorkspaceGit(ws2, root: "/Users/sm/code/cmux", branch: "feature/sidebar")

        manager.rebuildNow()

        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.projects[0].branches.count, 2)
        let branchNames = Set(manager.projects[0].branches.map { $0.name })
        XCTAssertTrue(branchNames.contains("main"))
        XCTAssertTrue(branchNames.contains("feature/sidebar"))
    }

    func testDirtyBranchIndicator() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        configureWorkspaceGit(workspace, root: "/Users/sm/code/cmux", branch: "main", isDirty: true)

        manager.rebuildNow()

        XCTAssertEqual(manager.projects[0].branches[0].isDirty, true)
    }

    // MARK: - 3. Non-Git Workspaces ("Other" Section)

    func testWorkspaceWithoutGitRootGoesToOtherSection() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        // TabManager() creates a default workspace with no git info.
        // All non-git workspaces go to "Other".
        manager.rebuildNow()

        XCTAssertEqual(manager.projects.count, 0)
        XCTAssertNotNil(manager.otherProject)
        XCTAssertTrue(manager.otherProject!.isOtherSection)
        XCTAssertGreaterThanOrEqual(manager.otherProject!.branches[0].workspaceIds.count, 1)
    }

    func testOtherSectionRemovedWhenAllWorkspacesHaveGit() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        manager.rebuildNow()
        XCTAssertNotNil(manager.otherProject)

        // Set git info on ALL workspaces (including the default one)
        for workspace in tabManager.tabs {
            configureWorkspaceGit(workspace, root: "/Users/sm/code/cmux", branch: "main")
        }
        manager.rebuildNow()

        XCTAssertNil(manager.otherProject)
        XCTAssertEqual(manager.projects.count, 1)
    }

    // MARK: - 4. Flat Workspace Order

    func testFlatWorkspaceOrderMatchesTreeTraversal() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        // Configure ALL workspaces (including the default one) with git info
        // so they all go into projects, not "Other".
        let defaultWs = tabManager.tabs[0]
        configureWorkspaceGit(defaultWs, root: "/Users/sm/code/cmux", branch: "main")

        let ws2 = tabManager.addWorkspace(select: false)
        let ws3 = tabManager.addWorkspace(select: false)
        configureWorkspaceGit(ws2, root: "/Users/sm/code/cmux", branch: "feature/sidebar")
        configureWorkspaceGit(ws3, root: "/Users/sm/code/conductor", branch: "main")

        manager.rebuildNow()

        let flatOrder = manager.flatWorkspaceOrder()
        // All three workspaces should be in the flat order
        XCTAssertEqual(flatOrder.count, 3)
        XCTAssertTrue(flatOrder.contains(defaultWs.id))
        XCTAssertTrue(flatOrder.contains(ws2.id))
        XCTAssertTrue(flatOrder.contains(ws3.id))
    }

    func testFlatWorkspaceOrderIncludesOtherSection() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        // Default workspace has no git — goes to "Other".
        // Add one with git info.
        let defaultWs = tabManager.tabs[0]
        configureWorkspaceGit(defaultWs, root: "/Users/sm/code/cmux", branch: "main")

        let wsNoGit = tabManager.addWorkspace(select: false)
        // wsNoGit has no git — goes to "Other"
        _ = wsNoGit

        manager.rebuildNow()

        let flatOrder = manager.flatWorkspaceOrder()
        XCTAssertEqual(flatOrder.count, 2)
        // "Other" workspaces should come after git projects
        XCTAssertEqual(flatOrder.last, wsNoGit.id)
    }

    // MARK: - 5. Location Lookup

    func testLocationFindsCorrectProjectAndBranch() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        configureWorkspaceGit(workspace, root: "/Users/sm/code/cmux", branch: "feature/sidebar")

        manager.rebuildNow()

        let result = manager.location(for: workspace.id)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0.name, "cmux")
        XCTAssertEqual(result?.1.name, "feature/sidebar")
    }

    func testLocationReturnsNilForUnknownWorkspace() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)
        manager.rebuildNow()

        let result = manager.location(for: UUID())
        XCTAssertNil(result)
    }

    // MARK: - 6. Project Reordering

    func testMoveProjectUpdatesOrder() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let ws1 = tabManager.addWorkspace(select: false)
        let ws2 = tabManager.addWorkspace(select: false)
        configureWorkspaceGit(ws1, root: "/Users/sm/code/aaa", branch: "main")
        configureWorkspaceGit(ws2, root: "/Users/sm/code/zzz", branch: "main")

        manager.rebuildNow()
        XCTAssertEqual(manager.projects.count, 2)

        let firstProjectName = manager.projects[0].name
        let secondProjectName = manager.projects[1].name

        // Move second project to first position
        manager.moveProject(from: IndexSet(integer: 1), to: 0)

        XCTAssertEqual(manager.projects[0].name, secondProjectName)
        XCTAssertEqual(manager.projects[1].name, firstProjectName)
        XCTAssertEqual(manager.projects[0].order, 0)
        XCTAssertEqual(manager.projects[1].order, 1)
    }

    // MARK: - 7. Session Persistence

    func testSessionSnapshotRoundTrip() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let ws1 = tabManager.addWorkspace(select: false)
        let ws2 = tabManager.addWorkspace(select: false)
        configureWorkspaceGit(ws1, root: "/Users/sm/code/cmux", branch: "main")
        configureWorkspaceGit(ws2, root: "/Users/sm/code/conductor", branch: "develop")

        manager.rebuildNow()

        // Collapse the first project
        manager.projects[0].isExpanded = false

        let snapshot = manager.sessionSnapshot(tabManager: tabManager)
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot[0].isExpanded, false)

        // Restore into a new manager
        let restoredManager = SidebarProjectManager()
        restoredManager.attach(to: tabManager)
        restoredManager.restoreFromSnapshot(snapshot, tabManager: tabManager)

        XCTAssertEqual(restoredManager.projects.count, 2)
        XCTAssertEqual(restoredManager.projects[0].isExpanded, false)
        XCTAssertEqual(restoredManager.projects[1].isExpanded, true)
    }

    func testRestoreFromNilSnapshotDoesNotCrash() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        // Should not crash
        let nilSnapshots: [SessionProjectSnapshot]? = nil
        manager.restoreFromSnapshot(nilSnapshots, tabManager: tabManager)

        // Manager should still function
        XCTAssertNotNil(manager)
    }

    // MARK: - 8. Multi-Repo Workspaces (Linked Terminals)

    func testMultiRepoWorkspaceCreatesLinkedTerminalEntry() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        configureWorkspaceGit(workspace, root: "/Users/sm/code/conductor", branch: "main")

        // Simulate a panel in a different repo
        let panelId = UUID()
        workspace.panelGitRoots[panelId] = "/Users/sm/code/api"
        workspace.panelGitBranches[panelId] = SidebarGitBranchState(branch: "main", isDirty: false)

        manager.rebuildNow()

        // Should have two projects: conductor (primary) and api (auto-created)
        XCTAssertEqual(manager.projects.count, 2)

        let autoProject = manager.projects.first(where: { $0.isAutoCreated })
        XCTAssertNotNil(autoProject)
        XCTAssertEqual(autoProject?.name, "api")

        let linkedTerminals = autoProject?.branches.first?.linkedTerminals ?? []
        XCTAssertEqual(linkedTerminals.count, 1)
        XCTAssertEqual(linkedTerminals[0].owningWorkspaceId, workspace.id)
        XCTAssertEqual(linkedTerminals[0].panelId, panelId)
    }

    func testAutoProjectRemovedWhenLinkedTerminalDisappears() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        configureWorkspaceGit(workspace, root: "/Users/sm/code/conductor", branch: "main")

        let panelId = UUID()
        workspace.panelGitRoots[panelId] = "/Users/sm/code/api"
        workspace.panelGitBranches[panelId] = SidebarGitBranchState(branch: "main", isDirty: false)

        manager.rebuildNow()
        XCTAssertEqual(manager.projects.count, 2)

        // Remove the panel from a different repo
        workspace.panelGitRoots.removeValue(forKey: panelId)
        workspace.panelGitBranches.removeValue(forKey: panelId)

        manager.rebuildNow()

        // Auto-project should be cleaned up
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.projects[0].name, "conductor")
        XCTAssertFalse(manager.projects[0].isAutoCreated)
    }

    // MARK: - 9. Recent Projects

    func testAddRecentProjectPathPersistsAndCapsAt20() {
        // Clear existing
        UserDefaults.standard.removeObject(forKey: "sidebarRecentProjectPaths")

        for i in 0..<25 {
            SidebarProjectManager.addRecentProjectPath("/path/to/project\(i)")
        }

        let paths = SidebarProjectManager.recentProjectPaths()
        XCTAssertEqual(paths.count, 20)
        // Most recently added should be first
        XCTAssertEqual(paths[0], "/path/to/project24")
    }

    func testRecentProjectPathDeduplication() {
        UserDefaults.standard.removeObject(forKey: "sidebarRecentProjectPaths")

        SidebarProjectManager.addRecentProjectPath("/path/to/foo")
        SidebarProjectManager.addRecentProjectPath("/path/to/bar")
        SidebarProjectManager.addRecentProjectPath("/path/to/foo")  // duplicate

        let paths = SidebarProjectManager.recentProjectPaths()
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0], "/path/to/foo")  // moved to front
        XCTAssertEqual(paths[1], "/path/to/bar")
    }

    // MARK: - 10. Rebuild Preserves State

    func testRebuildPreservesExpandCollapseState() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        configureWorkspaceGit(workspace, root: "/Users/sm/code/cmux", branch: "main")

        manager.rebuildNow()
        XCTAssertTrue(manager.projects[0].isExpanded)

        // Collapse the project
        manager.projects[0].isExpanded = false

        // Trigger another rebuild (simulating a git branch update)
        manager.rebuildNow()

        // Collapsed state should be preserved
        XCTAssertFalse(manager.projects[0].isExpanded)
    }

    func testRebuildPreservesProjectOrder() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        // Use the default workspace for "aaa" and add one for "zzz"
        let defaultWs = tabManager.tabs[0]
        configureWorkspaceGit(defaultWs, root: "/Users/sm/code/aaa", branch: "main")
        let ws2 = tabManager.addWorkspace(select: false)
        configureWorkspaceGit(ws2, root: "/Users/sm/code/zzz", branch: "main")

        manager.rebuildNow()
        XCTAssertEqual(manager.projects.count, 2)

        // Reorder so zzz is first
        manager.moveProject(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(manager.projects[0].name, "zzz")

        // Trigger rebuild
        manager.rebuildNow()

        // Order should be preserved
        XCTAssertEqual(manager.projects[0].name, "zzz")
        XCTAssertEqual(manager.projects[1].name, "aaa")
    }

    // MARK: - 11. Edge Cases

    func testEmptyTabManagerProducesNoProjects() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)
        manager.rebuildNow()

        // TabManager creates a default workspace, which has no git info
        // So it should be in "Other" or projects should be empty
        XCTAssertEqual(manager.projects.count, 0)
    }

    func testWorkspaceMovingBetweenBranches() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        configureWorkspaceGit(workspace, root: "/Users/sm/code/cmux", branch: "main")

        manager.rebuildNow()
        XCTAssertEqual(manager.projects[0].branches[0].name, "main")

        // Switch branch
        workspace.gitBranch = SidebarGitBranchState(branch: "feature/new", isDirty: false)
        manager.rebuildNow()

        // Should now be under "feature/new", "main" branch should be gone
        XCTAssertEqual(manager.projects[0].branches.count, 1)
        XCTAssertEqual(manager.projects[0].branches[0].name, "feature/new")
        XCTAssertEqual(manager.projects[0].branches[0].workspaceIds, [workspace.id])
    }

    func testProjectRemovedWhenLastWorkspaceClosed() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let ws1 = tabManager.addWorkspace(select: false)
        let ws2 = tabManager.addWorkspace(select: true)
        configureWorkspaceGit(ws1, root: "/Users/sm/code/cmux", branch: "main")
        configureWorkspaceGit(ws2, root: "/Users/sm/code/conductor", branch: "main")

        manager.rebuildNow()
        XCTAssertEqual(manager.projects.count, 2)

        // Close the conductor workspace
        tabManager.closeWorkspace(ws2)
        manager.rebuildNow()

        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.projects[0].name, "cmux")
    }

    // MARK: - 12. Sticky Project Assignment (Focus Stability)

    func testFocusSwitchBetweenReposDoesNotMoveWorkspace() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        let panelA = UUID()
        let panelB = UUID()

        // Initial state: workspace in repoA with panel A.
        workspace.gitRoot = "/Users/sm/code/repoA"
        workspace.gitBranch = SidebarGitBranchState(branch: "main", isDirty: false)
        workspace.panelGitRoots[panelA] = "/Users/sm/code/repoA"
        workspace.panelGitBranches[panelA] = SidebarGitBranchState(branch: "main", isDirty: false)

        manager.rebuildNow()
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.projects[0].repoPath, "/Users/sm/code/repoA")

        // Panel B cd's to repoB and becomes focused (shell integration reports new root).
        workspace.panelGitRoots[panelB] = "/Users/sm/code/repoB"
        workspace.panelGitBranches[panelB] = SidebarGitBranchState(branch: "develop", isDirty: false)
        workspace.gitRoot = "/Users/sm/code/repoB"
        workspace.gitBranch = SidebarGitBranchState(branch: "develop", isDirty: false)

        manager.rebuildNow()

        // Workspace should STILL be under repoA (sticky holds).
        let repoAProject = manager.projects.first(where: { $0.repoPath == "/Users/sm/code/repoA" })
        XCTAssertNotNil(repoAProject, "Workspace should remain under its original project")
        XCTAssertTrue(repoAProject!.branches.contains(where: { $0.workspaceIds.contains(workspace.id) }))

        // repoB should appear as auto-created project with linked terminal.
        let repoBProject = manager.projects.first(where: { $0.repoPath == "/Users/sm/code/repoB" })
        XCTAssertNotNil(repoBProject, "Linked repo should appear as auto-created project")
        XCTAssertTrue(repoBProject!.isAutoCreated)
        let linkedTerminals = repoBProject!.branches.flatMap(\.linkedTerminals)
        XCTAssertEqual(linkedTerminals.count, 1)
        XCTAssertEqual(linkedTerminals[0].owningWorkspaceId, workspace.id)
    }

    func testWorkspaceMovesWhenAllPanelsLeaveOriginalRepo() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        let panelA = UUID()

        // Start in repoA.
        workspace.gitRoot = "/Users/sm/code/repoA"
        workspace.gitBranch = SidebarGitBranchState(branch: "main", isDirty: false)
        workspace.panelGitRoots[panelA] = "/Users/sm/code/repoA"
        workspace.panelGitBranches[panelA] = SidebarGitBranchState(branch: "main", isDirty: false)

        manager.rebuildNow()
        XCTAssertEqual(manager.projects[0].repoPath, "/Users/sm/code/repoA")

        // Panel A cd's to repoB (no panels left in repoA).
        workspace.panelGitRoots[panelA] = "/Users/sm/code/repoB"
        workspace.panelGitBranches[panelA] = SidebarGitBranchState(branch: "develop", isDirty: false)
        workspace.gitRoot = "/Users/sm/code/repoB"
        workspace.gitBranch = SidebarGitBranchState(branch: "develop", isDirty: false)

        manager.rebuildNow()

        // Workspace should move to repoB since no panels remain in repoA.
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.projects[0].repoPath, "/Users/sm/code/repoB")
    }

    func testStickyHoldUsesBranchFromOriginalRepoPanel() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        let panelA = UUID()
        let panelB = UUID()

        // Panel A is in repoA on feature/x (dirty).
        workspace.panelGitRoots[panelA] = "/Users/sm/code/repoA"
        workspace.panelGitBranches[panelA] = SidebarGitBranchState(branch: "feature/x", isDirty: true)
        // Panel B is in repoB on develop (clean).
        workspace.panelGitRoots[panelB] = "/Users/sm/code/repoB"
        workspace.panelGitBranches[panelB] = SidebarGitBranchState(branch: "develop", isDirty: false)

        // Initial assignment to repoA (focus on A first).
        workspace.gitRoot = "/Users/sm/code/repoA"
        workspace.gitBranch = SidebarGitBranchState(branch: "feature/x", isDirty: true)
        manager.rebuildNow()

        // Now simulate focus on panel B.
        workspace.gitRoot = "/Users/sm/code/repoB"
        workspace.gitBranch = SidebarGitBranchState(branch: "develop", isDirty: false)

        manager.rebuildNow()

        // Workspace should be under repoA with panel A's branch info.
        let repoAProject = manager.projects.first(where: { $0.repoPath == "/Users/sm/code/repoA" })
        XCTAssertNotNil(repoAProject)
        let branch = repoAProject?.branches.first(where: { $0.workspaceIds.contains(workspace.id) })
        XCTAssertEqual(branch?.name, "feature/x")
        XCTAssertEqual(branch?.isDirty, true)
    }

    func testThreePanelsThreeReposStaysUnderOriginal() {
        let tabManager = TabManager()
        let manager = makeManager(with: tabManager)

        let workspace = tabManager.addWorkspace(select: true)
        let panelA = UUID(), panelB = UUID(), panelC = UUID()

        // Initial assignment to repoA.
        workspace.gitRoot = "/Users/sm/code/repoA"
        workspace.gitBranch = SidebarGitBranchState(branch: "main", isDirty: false)
        workspace.panelGitRoots[panelA] = "/Users/sm/code/repoA"
        workspace.panelGitBranches[panelA] = SidebarGitBranchState(branch: "main", isDirty: false)

        manager.rebuildNow()

        // Add panels B and C in different repos, focus on C.
        workspace.panelGitRoots[panelB] = "/Users/sm/code/repoB"
        workspace.panelGitBranches[panelB] = SidebarGitBranchState(branch: "develop", isDirty: false)
        workspace.panelGitRoots[panelC] = "/Users/sm/code/repoC"
        workspace.panelGitBranches[panelC] = SidebarGitBranchState(branch: "feature/z", isDirty: false)
        workspace.gitRoot = "/Users/sm/code/repoC"
        workspace.gitBranch = SidebarGitBranchState(branch: "feature/z", isDirty: false)

        manager.rebuildNow()

        // Workspace stays under repoA.
        let repoAProject = manager.projects.first(where: { $0.repoPath == "/Users/sm/code/repoA" })
        XCTAssertNotNil(repoAProject)
        XCTAssertTrue(repoAProject!.branches.contains(where: { $0.workspaceIds.contains(workspace.id) }))

        // repoB and repoC are auto-created with linked terminals.
        let autoProjects = manager.projects.filter { $0.isAutoCreated }
        XCTAssertEqual(autoProjects.count, 2)
    }
}
