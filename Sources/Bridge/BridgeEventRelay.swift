import Foundation

// MARK: - Bridge Event Notification Names

extension Notification.Name {
    /// Posted when a new workspace is added to a TabManager.
    static let bridgeWorkspaceCreated = Notification.Name("bridge.workspace.created")
    /// Posted when a workspace is removed from a TabManager.
    static let bridgeWorkspaceClosed = Notification.Name("bridge.workspace.closed")
    /// Posted when a workspace's title changes (process title or custom title).
    static let bridgeWorkspaceTitleChanged = Notification.Name("bridge.workspace.titleChanged")
    /// Posted when a pane is split into two panes.
    static let bridgePaneSplit = Notification.Name("bridge.pane.split")
    /// Posted when a pane is closed.
    static let bridgePaneClosed = Notification.Name("bridge.pane.closed")
    /// Posted when a pane receives focus.
    static let bridgePaneFocused = Notification.Name("bridge.pane.focused")
    /// Posted when a surface (panel) is closed within a workspace.
    static let bridgeSurfaceClosed = Notification.Name("bridge.surface.closed")
    /// Posted when a surface is moved between panes.
    static let bridgeSurfaceMoved = Notification.Name("bridge.surface.moved")
    /// Posted when a surface is reordered within the same pane.
    static let bridgeSurfaceReordered = Notification.Name("bridge.surface.reordered")
    /// Posted when a terminal notification is added (bell, Claude hook, etc.).
    static let bridgeSurfaceAttention = Notification.Name("bridge.surface.attention")
    /// Posted when a browser panel navigates to a new URL (page load completes or URL changes).
    static let bridgeBrowserNavigated = Notification.Name("bridge.browser.navigated")
    /// Posted when a new browser panel is created in a workspace.
    static let bridgeBrowserCreated = Notification.Name("bridge.browser.created")
    /// Posted when a browser panel is closed in a workspace.
    static let bridgeBrowserClosed = Notification.Name("bridge.browser.closed")
    /// Posted when the sidebar project hierarchy changes (rebuild completes).
    static let bridgeProjectUpdated = Notification.Name("bridge.project.updated")
}

// MARK: - Bridge-Specific UserInfo Keys

/// Keys used in bridge notification `userInfo` dictionaries. These complement the existing
/// `GhosttyNotificationKey` values for bridge-specific payloads (pane IDs, etc.).
enum BridgeNotificationKey {
    static let originalPane = "bridge.originalPane"
    static let newPane = "bridge.newPane"
    static let paneId = "bridge.paneId"
    static let fromPane = "bridge.fromPane"
    static let toPane = "bridge.toPane"
    static let fromIndex = "bridge.fromIndex"
    static let toIndex = "bridge.toIndex"
    static let reason = "bridge.reason"
    static let notificationTitle = "bridge.notificationTitle"
    static let url = "bridge.url"
    static let faviconURL = "bridge.faviconURL"
    static let canGoBack = "bridge.canGoBack"
    static let canGoForward = "bridge.canGoForward"
}

// MARK: - BridgeEventRelay

/// Relays application events (workspace changes, surface focus, etc.) to connected
/// bridge clients as push notifications.
///
/// Registers NotificationCenter observers for workspace/surface/pane events that
/// automatically call `emit(event:data:)` to broadcast JSON events to all connected
/// bridge WebSocket clients.
final class BridgeEventRelay: @unchecked Sendable {
    static let shared = BridgeEventRelay()

    /// Whether the relay is currently forwarding events to bridge connections.
    private var isRunning = false

    /// Guards access to `isRunning`.
    private let lock = NSLock()

    /// Tokens for registered NotificationCenter observers, removed on `stop()`.
    private var observers: [NSObjectProtocol] = []

    /// Shared date formatter for event timestamps, avoiding per-call allocation.
    private static let isoFormatter = ISO8601DateFormatter()

    private init() {}

    // MARK: - Lifecycle

    /// Starts the event relay and registers NotificationCenter observers for all
    /// bridge-relevant events (workspace, surface, and pane changes).
    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        isRunning = true
        registerObservers()
    }

    /// Stops the event relay and removes all NotificationCenter observers.
    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        isRunning = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - Observer Registration

    /// Registers observers for all 16 bridge event types.
    private func registerObservers() {
        // 1. workspace.selected — existing notification, fired when the selected workspace changes
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusTab, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            self?.emit(event: "workspace.selected", data: [
                "workspace_id": tabId.uuidString,
            ])
        })

        // 2. workspace.created — fired when a new workspace is added
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeWorkspaceCreated, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            self?.emit(event: "workspace.created", data: [
                "workspace_id": tabId.uuidString,
            ])
        })

        // 3. workspace.closed — fired when a workspace is removed
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeWorkspaceClosed, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            self?.emit(event: "workspace.closed", data: [
                "workspace_id": tabId.uuidString,
            ])
        })

        // 4. workspace.title_changed — fired when a workspace title is set
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeWorkspaceTitleChanged, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            let title = notification.userInfo?[GhosttyNotificationKey.title] as? String ?? ""
            self?.emit(event: "workspace.title_changed", data: [
                "workspace_id": tabId.uuidString,
                "title": title,
            ])
        })

        // 5. pane.split — fired when a pane is split
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgePaneSplit, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            let originalPane = notification.userInfo?[BridgeNotificationKey.originalPane] as? String ?? ""
            let newPane = notification.userInfo?[BridgeNotificationKey.newPane] as? String ?? ""
            self?.emit(event: "pane.split", data: [
                "workspace_id": tabId.uuidString,
                "original_pane": originalPane,
                "new_pane": newPane,
            ])
        })

        // 6. pane.closed — fired when a pane is closed
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgePaneClosed, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            let paneId = notification.userInfo?[BridgeNotificationKey.paneId] as? String ?? ""
            self?.emit(event: "pane.closed", data: [
                "workspace_id": tabId.uuidString,
                "pane_id": paneId,
            ])
        })

        // 7. pane.focused — fired when a pane receives focus
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgePaneFocused, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            let paneId = notification.userInfo?[BridgeNotificationKey.paneId] as? String ?? ""
            self?.emit(event: "pane.focused", data: [
                "workspace_id": tabId.uuidString,
                "pane_id": paneId,
            ])
        })

        // 8. surface.focused — existing notification, fired when a surface gets focus
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self?.emit(event: "surface.focused", data: [
                "workspace_id": tabId.uuidString,
                "surface_id": surfaceId.uuidString,
            ])
        })

        // 9. surface.closed — fired when a surface/panel is closed
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeSurfaceClosed, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self?.emit(event: "surface.closed", data: [
                "workspace_id": tabId.uuidString,
                "surface_id": surfaceId.uuidString,
            ])
        })

        // 10. surface.moved — fired when a surface moves between panes
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeSurfaceMoved, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            let fromPane = notification.userInfo?[BridgeNotificationKey.fromPane] as? String ?? ""
            let toPane = notification.userInfo?[BridgeNotificationKey.toPane] as? String ?? ""
            self?.emit(event: "surface.moved", data: [
                "workspace_id": tabId.uuidString,
                "surface_id": surfaceId.uuidString,
                "from_pane": fromPane,
                "to_pane": toPane,
            ])
        })

        // 11. surface.title_changed — existing notification, fired when a terminal title updates.
        // Resolves through the workspace's custom title chain so user-set names take priority.
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle, object: nil, queue: .main
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            let shellTitle = notification.userInfo?[GhosttyNotificationKey.title] as? String ?? ""

            // If the panel has a custom title set by the user, emit that instead of the
            // shell-set title so Android doesn't overwrite user renames.
            let resolvedTitle: String
            if let tabManager = AppDelegate.shared?.tabManagerFor(tabId: tabId),
               let workspace = tabManager.tabs.first(where: { $0.id == tabId }),
               let customTitle = workspace.panelCustomTitles[surfaceId],
               !customTitle.isEmpty {
                resolvedTitle = customTitle
            } else {
                resolvedTitle = shellTitle
            }

            self?.emit(event: "surface.title_changed", data: [
                "workspace_id": tabId.uuidString,
                "surface_id": surfaceId.uuidString,
                "title": resolvedTitle,
            ])
        })

        // 12. surface.reordered — fired when a surface is reordered within the same pane
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeSurfaceReordered, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            let paneId = notification.userInfo?[BridgeNotificationKey.paneId] as? String ?? ""
            let fromIndex = notification.userInfo?[BridgeNotificationKey.fromIndex] as? Int ?? 0
            let toIndex = notification.userInfo?[BridgeNotificationKey.toIndex] as? Int ?? 0
            self?.emit(event: "surface.reordered", data: [
                "workspace_id": tabId.uuidString,
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId,
                "from_index": fromIndex,
                "to_index": toIndex,
            ])
        })

        // 13. surface.attention — fired when a terminal notification is added (bell, Claude hook, etc.)
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeSurfaceAttention, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else {
                return
            }
            let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID
            let reason = notification.userInfo?[BridgeNotificationKey.reason] as? String ?? "notification"
            let title = notification.userInfo?[BridgeNotificationKey.notificationTitle] as? String ?? ""
            self?.emit(event: "surface.attention", data: [
                "workspace_id": tabId.uuidString,
                "surface_id": surfaceId?.uuidString ?? "",
                "reason": reason,
                "title": title,
            ])
        })

        // 14. browser.navigated — fired when a browser panel navigates to a new URL
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeBrowserNavigated, object: nil, queue: nil
        ) { [weak self] notification in
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            let url = notification.userInfo?[BridgeNotificationKey.url] as? String ?? ""
            let title = notification.userInfo?[GhosttyNotificationKey.title] as? String ?? ""
            let faviconURL = notification.userInfo?[BridgeNotificationKey.faviconURL] as? String ?? ""
            let canGoBack = notification.userInfo?[BridgeNotificationKey.canGoBack] as? Bool ?? false
            let canGoForward = notification.userInfo?[BridgeNotificationKey.canGoForward] as? Bool ?? false
            self?.emit(event: "browser.navigated", data: [
                "surface_id": surfaceId.uuidString,
                "url": url,
                "title": title,
                "favicon_url": faviconURL,
                "can_go_back": canGoBack,
                "can_go_forward": canGoForward,
            ])
        })

        // 15. browser.created — fired when a new browser panel is created
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeBrowserCreated, object: nil, queue: nil
        ) { [weak self] notification in
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            let url = notification.userInfo?[BridgeNotificationKey.url] as? String ?? ""
            let title = notification.userInfo?[GhosttyNotificationKey.title] as? String ?? ""
            self?.emit(event: "browser.created", data: [
                "surface_id": surfaceId.uuidString,
                "url": url,
                "title": title,
            ])
        })

        // 16. browser.closed — fired when a browser panel is closed
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeBrowserClosed, object: nil, queue: nil
        ) { [weak self] notification in
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self?.emit(event: "browser.closed", data: [
                "surface_id": surfaceId.uuidString,
            ])
        })

        // 17. project.updated — fired when the sidebar project hierarchy rebuilds.
        // Emits an empty payload; the mobile app should call `project.list` to
        // fetch the fresh tree.
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeProjectUpdated, object: nil, queue: nil
        ) { [weak self] _ in
            self?.emit(event: "project.updated", data: [:])
        })
    }

    // MARK: - Event Emission

    /// Emits an event to all connected bridge clients that have subscribed to events.
    ///
    /// The event is JSON-serialized and broadcast via `BridgeServer.shared.broadcastEvent()`.
    ///
    /// - Parameters:
    ///   - event: The event name (e.g. "workspace.selected", "surface.focused").
    ///   - data: Arbitrary dictionary payload for the event.
    func emit(event: String, data: [String: Any]) {
        lock.lock()
        let running = isRunning
        lock.unlock()

        guard running else { return }

        let message: [String: Any] = [
            "type": "event",
            "event": event,
            "data": data,
            "timestamp": BridgeEventRelay.isoFormatter.string(from: Date()),
        ]

        guard JSONSerialization.isValidJSONObject(message),
              let jsonData = try? JSONSerialization.data(withJSONObject: message, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            NSLog("[BridgeEventRelay] Failed to serialize event: %@", event)
            return
        }

        BridgeServer.shared.broadcastEvent(jsonString)
    }
}
