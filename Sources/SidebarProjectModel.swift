import Foundation
import Combine

// MARK: - Sidebar Project Hierarchy Models
//
// Presentation-layer grouping for the sidebar tree view.
// These models do NOT own workspaces — they hold references (UUIDs)
// into the flat TabManager.tabs array.
//
// Hierarchy: SidebarProject → SidebarBranch → [Workspace UUIDs]

/// A git repository shown as a top-level group in the sidebar.
@MainActor
final class SidebarProject: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var repoPath: String
    @Published var isExpanded: Bool
    @Published var branches: [SidebarBranch]
    @Published var order: Int

    /// True when this project was auto-created from a linked terminal
    /// in a multi-repo workspace. Auto-created projects are removed
    /// when their last linked terminal disappears.
    var isAutoCreated: Bool

    /// True for the special "Other" section that holds non-git workspaces.
    var isOtherSection: Bool

    init(
        id: UUID = UUID(),
        name: String,
        repoPath: String,
        isExpanded: Bool = true,
        branches: [SidebarBranch] = [],
        order: Int = 0,
        isAutoCreated: Bool = false,
        isOtherSection: Bool = false
    ) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.isExpanded = isExpanded
        self.branches = branches
        self.order = order
        self.isAutoCreated = isAutoCreated
        self.isOtherSection = isOtherSection
    }
}

/// A git branch within a project. Value-type by design:
/// mutations require replacing the struct in the parent array,
/// which triggers @Published change detection on SidebarProject.
struct SidebarBranch: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isDirty: Bool
    var isExpanded: Bool
    var workspaceIds: [UUID]
    var linkedTerminals: [SidebarLinkedTerminalEntry]

    init(
        id: UUID = UUID(),
        name: String,
        isDirty: Bool = false,
        isExpanded: Bool = true,
        workspaceIds: [UUID] = [],
        linkedTerminals: [SidebarLinkedTerminalEntry] = []
    ) {
        self.id = id
        self.name = name
        self.isDirty = isDirty
        self.isExpanded = isExpanded
        self.workspaceIds = workspaceIds
        self.linkedTerminals = linkedTerminals
    }
}

/// A reference to a terminal in another workspace, shown under an
/// auto-created project. Clicking navigates to the owning workspace.
struct SidebarLinkedTerminalEntry: Identifiable, Equatable {
    let id: UUID
    let owningWorkspaceId: UUID
    let owningProjectName: String
    let owningWorkspaceName: String
    let panelId: UUID

    init(
        id: UUID = UUID(),
        owningWorkspaceId: UUID,
        owningProjectName: String,
        owningWorkspaceName: String,
        panelId: UUID
    ) {
        self.id = id
        self.owningWorkspaceId = owningWorkspaceId
        self.owningProjectName = owningProjectName
        self.owningWorkspaceName = owningWorkspaceName
        self.panelId = panelId
    }
}

// MARK: - Session Persistence Snapshots

/// Snapshot of a project for session save/restore.
struct SessionProjectSnapshot: Codable, Sendable {
    var name: String
    var repoPath: String
    var isExpanded: Bool
    var order: Int
    var isAutoCreated: Bool
    var branches: [SessionBranchSnapshot]
}

/// Snapshot of a branch for session save/restore.
/// workspaceIndices maps to indices in SessionTabManagerSnapshot.workspaces.
struct SessionBranchSnapshot: Codable, Sendable {
    var name: String
    var isExpanded: Bool
    var workspaceIndices: [Int]
}
