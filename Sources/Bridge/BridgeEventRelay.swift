import Foundation

/// Relays application events (workspace changes, surface focus, etc.) to connected
/// bridge clients as push notifications.
///
/// Phase 1 stub: provides the emission API and lifecycle methods. Phase 2 will add
/// NotificationCenter observers for workspace/surface/pane events that automatically
/// call `emit(event:data:)`.
final class BridgeEventRelay: @unchecked Sendable {
    static let shared = BridgeEventRelay()

    /// Whether the relay is currently forwarding events to bridge connections.
    private var isRunning = false

    /// Guards access to `isRunning`.
    private let lock = NSLock()

    /// Shared date formatter for event timestamps, avoiding per-call allocation.
    private static let isoFormatter = ISO8601DateFormatter()

    private init() {}

    // MARK: - Lifecycle

    /// Starts the event relay. Phase 2 will register NotificationCenter observers here.
    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        isRunning = true
        // Phase 2: Register NotificationCenter observers for workspace/surface/pane events.
    }

    /// Stops the event relay and removes all observers.
    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        isRunning = false
        // Phase 2: Remove NotificationCenter observers.
    }

    // MARK: - Event Emission

    /// Emits an event to all connected bridge clients that have subscribed to events.
    ///
    /// The event is JSON-serialized and broadcast via `BridgeServer.shared.broadcastEvent()`.
    ///
    /// - Parameters:
    ///   - event: The event name (e.g. "workspace.changed", "surface.focused").
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
