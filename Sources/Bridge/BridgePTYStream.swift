import Foundation

/// Thread-safe registry tracking which bridge connections are subscribed to PTY output
/// for each terminal surface.
///
/// Phase 1 stub: manages subscription bookkeeping only. Phase 2 will add the actual
/// PTY file descriptor tee that feeds terminal output to subscribed connections.
final class BridgePTYStream: @unchecked Sendable {
    static let shared = BridgePTYStream()

    /// Maps surface UUIDs to the set of connection UUIDs subscribed to their PTY output.
    private var subscriptions: [UUID: Set<UUID>] = [:]

    /// Guards all access to the subscriptions dictionary.
    private let lock = NSLock()

    private init() {}

    // MARK: - Public API

    /// Subscribes a connection to PTY output for a terminal surface.
    ///
    /// - Parameters:
    ///   - connectionId: UUID of the bridge connection requesting the subscription.
    ///   - surfaceId: UUID of the terminal surface to subscribe to.
    func addSubscriber(connectionId: UUID, surfaceId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        subscriptions[surfaceId, default: []].insert(connectionId)
    }

    /// Unsubscribes a connection from PTY output for a terminal surface.
    ///
    /// - Parameters:
    ///   - connectionId: UUID of the bridge connection to unsubscribe.
    ///   - surfaceId: UUID of the terminal surface to unsubscribe from.
    func removeSubscriber(connectionId: UUID, surfaceId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        subscriptions[surfaceId]?.remove(connectionId)
        if subscriptions[surfaceId]?.isEmpty == true {
            subscriptions.removeValue(forKey: surfaceId)
        }
    }

    /// Removes all PTY subscriptions for a disconnected connection.
    ///
    /// Called when a bridge connection is torn down to clean up all its subscriptions.
    ///
    /// - Parameter connectionId: UUID of the connection to remove from all surfaces.
    func removeAllSubscriptions(forConnection connectionId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        // Snapshot keys to avoid mutating the dictionary during iteration.
        for surfaceId in Array(subscriptions.keys) {
            subscriptions[surfaceId]?.remove(connectionId)
            if subscriptions[surfaceId]?.isEmpty == true {
                subscriptions.removeValue(forKey: surfaceId)
            }
        }
    }

    /// Returns the set of connection UUIDs subscribed to a given surface's PTY output.
    ///
    /// - Parameter surfaceId: UUID of the terminal surface.
    /// - Returns: Set of subscribed connection UUIDs, empty if none.
    func subscribedConnectionIds(for surfaceId: UUID) -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }

        return subscriptions[surfaceId] ?? []
    }
}
