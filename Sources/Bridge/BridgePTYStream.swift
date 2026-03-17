import Foundation

/// Thread-safe registry tracking which bridge connections are subscribed to PTY output
/// for each terminal surface. Manages the lifecycle of Ghostty PTY output observers:
/// registers the C callback when the first subscriber connects to a surface, and
/// unregisters when the last subscriber disconnects.
///
/// The C callback (`ptyOutputCallback`) runs on Ghostty's IO reader thread and must
/// only copy bytes and dispatch — no blocking, no locks, no allocations beyond the
/// `Data` copy.
final class BridgePTYStream: @unchecked Sendable {
    static let shared = BridgePTYStream()

    /// Maps surface UUIDs to the set of connection UUIDs subscribed to their PTY output.
    private var subscriptions: [UUID: Set<UUID>] = [:]

    /// Active observer contexts keyed by surface UUID. When a context exists for a surface,
    /// the Ghostty PTY output observer is registered and actively forwarding data.
    /// Guarded by `lock`.
    private var contexts: [UUID: Unmanaged<BridgePTYObserverContext>] = [:]

    /// Mobile terminal dimensions per connection+surface pair.
    /// Used for mobile-specific rendering hints (Phase 3).
    /// Key format: "\(connectionId):\(surfaceId)".
    private var mobileDimensions: [String: (cols: Int, rows: Int)] = [:]

    /// Guards all access to the subscriptions, contexts, and mobileDimensions dictionaries.
    private let lock = NSLock()

    /// Observer token for `.bridgeSurfaceClosed` notifications, cleaned up on deinit.
    private var surfaceClosedObserver: NSObjectProtocol?

    private init() {
        surfaceClosedObserver = NotificationCenter.default.addObserver(
            forName: .bridgeSurfaceClosed, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self,
                  let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self.removeAllSubscriptions(forSurface: surfaceId)
        }
    }

    deinit {
        if let observer = surfaceClosedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - C Callback Trampoline

    /// C callback trampoline invoked by Ghostty on the IO reader thread when PTY
    /// output arrives. Copies bytes to Data and dispatches to BridgeServer for
    /// broadcast to subscribed connections.
    ///
    /// IMPORTANT: This runs on Ghostty's IO reader thread. Only copy bytes and dispatch.
    /// No locks, no blocking, no heavy allocations.
    private static let ptyOutputCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { userdata, dataPtr, length in
        guard let userdata, let dataPtr, length > 0 else { return }
        let context = Unmanaged<BridgePTYObserverContext>.fromOpaque(userdata).takeUnretainedValue()
        let data = Data(bytes: dataPtr, count: length)
        BridgeServer.shared.broadcastPTYData(surfaceId: context.surfaceId, data: data)
    }

    // MARK: - Public API

    /// Subscribes a connection to PTY output for a terminal surface.
    ///
    /// When the first subscriber connects to a surface, registers the Ghostty PTY
    /// output observer so bytes start flowing through `BridgeServer.broadcastPTYData`.
    ///
    /// - Parameters:
    ///   - connectionId: UUID of the bridge connection requesting the subscription.
    ///   - surfaceId: UUID of the terminal surface to subscribe to.
    func addSubscriber(connectionId: UUID, surfaceId: UUID) {
        lock.lock()

        subscriptions[surfaceId, default: []].insert(connectionId)
        let isFirstSubscriber = subscriptions[surfaceId]?.count == 1

        lock.unlock()

        // Register Ghostty observer when first subscriber connects to this surface.
        if isFirstSubscriber {
            registerObserver(for: surfaceId)
        }
    }

    /// Unsubscribes a connection from PTY output for a terminal surface.
    ///
    /// When the last subscriber disconnects from a surface, unregisters the Ghostty
    /// PTY output observer to stop forwarding bytes.
    ///
    /// - Parameters:
    ///   - connectionId: UUID of the bridge connection to unsubscribe.
    ///   - surfaceId: UUID of the terminal surface to unsubscribe from.
    func removeSubscriber(connectionId: UUID, surfaceId: UUID) {
        lock.lock()

        subscriptions[surfaceId]?.remove(connectionId)
        let isEmpty = subscriptions[surfaceId]?.isEmpty == true
        if isEmpty {
            subscriptions.removeValue(forKey: surfaceId)
        }

        // Clean up mobile dimensions for this connection+surface pair.
        let dimensionKey = "\(connectionId.uuidString):\(surfaceId.uuidString)"
        mobileDimensions.removeValue(forKey: dimensionKey)

        lock.unlock()

        // Unregister Ghostty observer when last subscriber disconnects from this surface.
        if isEmpty {
            unregisterObserver(for: surfaceId)
        }
    }

    /// Removes all PTY subscriptions for a disconnected connection.
    ///
    /// Called when a bridge connection is torn down to clean up all its subscriptions.
    /// Unregisters Ghostty observers for any surfaces that have no remaining subscribers.
    ///
    /// - Parameter connectionId: UUID of the connection to remove from all surfaces.
    func removeAllSubscriptions(forConnection connectionId: UUID) {
        lock.lock()

        var emptiedSurfaces: [UUID] = []

        // Snapshot keys to avoid mutating the dictionary during iteration.
        for surfaceId in Array(subscriptions.keys) {
            subscriptions[surfaceId]?.remove(connectionId)
            if subscriptions[surfaceId]?.isEmpty == true {
                subscriptions.removeValue(forKey: surfaceId)
                emptiedSurfaces.append(surfaceId)
            }
        }

        // Clean up all mobile dimensions for this connection.
        let connectionPrefix = connectionId.uuidString + ":"
        mobileDimensions = mobileDimensions.filter { !$0.key.hasPrefix(connectionPrefix) }

        lock.unlock()

        // Unregister observers for surfaces with no remaining subscribers.
        for surfaceId in emptiedSurfaces {
            unregisterObserver(for: surfaceId)
        }
    }

    /// Removes all subscriptions for a surface that has been destroyed.
    ///
    /// Unregisters the Ghostty observer context. Called when `.bridgeSurfaceClosed` fires.
    /// The surface is already gone, so we cannot call the C API to clear the observer.
    /// The Ghostty side clears the callback during its own surface teardown (Termio is
    /// destroyed before the IO thread stops).
    ///
    /// - Parameter surfaceId: UUID of the destroyed surface.
    func removeAllSubscriptions(forSurface surfaceId: UUID) {
        lock.lock()
        subscriptions.removeValue(forKey: surfaceId)
        let unmanaged = contexts.removeValue(forKey: surfaceId)

        // Clean up all mobile dimensions for this surface (any connection).
        let surfaceSuffix = ":" + surfaceId.uuidString
        mobileDimensions = mobileDimensions.filter { !$0.key.hasSuffix(surfaceSuffix) }

        lock.unlock()

        // The surface is already gone, so we skip the C API call.
        // Just release the retained context.
        unmanaged?.release()
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

    // MARK: - Mobile Dimensions

    /// Stores the mobile client's desired terminal dimensions for a subscription.
    ///
    /// The desktop PTY is NOT resized. These dimensions are stored for future
    /// mobile-specific rendering hints (Phase 3).
    ///
    /// - Parameters:
    ///   - connectionId: UUID of the bridge connection.
    ///   - surfaceId: UUID of the terminal surface.
    ///   - cols: Desired column count from the mobile client.
    ///   - rows: Desired row count from the mobile client.
    func setMobileDimensions(connectionId: UUID, surfaceId: UUID, cols: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(connectionId.uuidString):\(surfaceId.uuidString)"
        mobileDimensions[key] = (cols: cols, rows: rows)
    }

    // MARK: - Observer Lifecycle

    /// Registers the Ghostty PTY output observer for a surface. Dispatches to the main
    /// thread to resolve the surface and call the C API.
    ///
    /// Creates a `BridgePTYObserverContext` retained via `Unmanaged.passRetained` so it
    /// stays alive for the duration of the observer registration. The context is released
    /// in `unregisterObserver(for:)`.
    private func registerObserver(for surfaceId: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let panel = resolveTerminalPanel(surfaceId: surfaceId),
                  let surface = panel.surface.surface else {
                NSLog("[BridgePTYStream] Cannot register observer: surface %@ not found",
                      surfaceId.uuidString)
                return
            }

            let context = BridgePTYObserverContext(surfaceId: surfaceId)
            let unmanaged = Unmanaged.passRetained(context)

            self.lock.lock()
            // If another observer was already registered (race condition), release it first.
            self.contexts[surfaceId]?.release()
            self.contexts[surfaceId] = unmanaged
            self.lock.unlock()

            cmux_surface_set_output_observer(
                surface,
                BridgePTYStream.ptyOutputCallback,
                unmanaged.toOpaque()
            )
        }
    }

    /// Unregisters the Ghostty PTY output observer for a surface. Dispatches to the main
    /// thread to call the C API, then releases the retained context.
    ///
    /// Safe to call even if the surface has already been destroyed — the C API call is
    /// skipped if the surface cannot be resolved.
    private func unregisterObserver(for surfaceId: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.lock.lock()
            let unmanaged = self.contexts.removeValue(forKey: surfaceId)
            self.lock.unlock()

            // Clear the Ghostty observer if the surface is still alive.
            // If the surface is already gone, we just skip the C call — the observer
            // was implicitly invalidated when the surface was destroyed.
            if let panel = resolveTerminalPanel(surfaceId: surfaceId),
               let surface = panel.surface.surface {
                cmux_surface_set_output_observer(surface, nil, nil)
            }

            // Release the retained context object.
            unmanaged?.release()
        }
    }
}
