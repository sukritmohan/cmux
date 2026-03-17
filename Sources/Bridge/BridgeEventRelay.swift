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

    /// Registers observers for 11 event types (surface.reordered is skipped — no
    /// BonsplitDelegate callback exists for tab reorder yet).
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

        // 11. surface.title_changed — existing notification, fired when a terminal title updates
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            let title = notification.userInfo?[GhosttyNotificationKey.title] as? String ?? ""
            self?.emit(event: "surface.title_changed", data: [
                "workspace_id": tabId.uuidString,
                "surface_id": surfaceId.uuidString,
                "title": title,
            ])
        })

        // Note: surface.reordered is not wired — no BonsplitDelegate callback for tab reorder exists yet.
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
