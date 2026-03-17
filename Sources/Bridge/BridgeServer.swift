import Foundation
import Network

/// WebSocket server that accepts connections from mobile companion apps over the local network.
///
/// Uses `Network.framework` (`NWListener`) to listen on `0.0.0.0:<port>` for incoming
/// WebSocket connections. Each accepted connection is wrapped in a `BridgeConnection`
/// that handles authentication, message dispatch, and PTY streaming.
///
/// Thread-safe via `NSLock` — the listener and all connections run on a dedicated
/// serial dispatch queue. The heartbeat timer fires every 15 seconds to detect
/// stale connections via WebSocket ping/pong.
///
/// Singleton: access via `BridgeServer.shared`.
final class BridgeServer: @unchecked Sendable {
    static let shared = BridgeServer()

    // MARK: - State

    /// Active WebSocket connections keyed by their unique ID.
    /// Guarded by `lock`.
    private var connections: [UUID: BridgeConnection] = [:]

    /// The Network.framework listener, or `nil` if not started.
    /// Guarded by `lock`.
    private var listener: NWListener?

    /// Whether the server is currently listening for connections.
    /// Guarded by `lock`.
    private var isRunning = false

    /// Heartbeat timer that sends WebSocket pings to detect stale connections.
    /// Guarded by `lock`.
    private var heartbeatTimer: DispatchSourceTimer?

    /// Guards all mutable state access.
    private let lock = NSLock()

    /// Dedicated serial queue for NWListener callbacks and connection I/O.
    private let queue = DispatchQueue(label: "com.cmux.bridge-server")

    // MARK: - Constants

    /// Interval between heartbeat ping sweeps, in seconds.
    private static let heartbeatInterval: TimeInterval = 15

    /// Number of consecutive missed pongs before a connection is considered dead.
    private static let maxMissedPongs = 3

    // MARK: - Init

    private init() {}

    // MARK: - Lifecycle

    /// Starts the WebSocket server on the configured port.
    ///
    /// Creates an `NWListener` with WebSocket protocol options, begins accepting
    /// connections, and starts the heartbeat timer. Does nothing if already running.
    ///
    /// The port is read from `BridgeSettings.port` at call time.
    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let port = BridgeSettings.port
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            NSLog("[BridgeServer] Invalid port: %d", port)
            return
        }

        // Configure WebSocket protocol options.
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let params = NWParameters(tls: nil)
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: nwPort)
        } catch {
            NSLog("[BridgeServer] Failed to create listener on port %d: %@",
                  port, error.localizedDescription)
            return
        }

        newListener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        newListener.newConnectionHandler = { [weak self] nwConnection in
            self?.handleNewConnection(nwConnection)
        }

        listener = newListener
        isRunning = true
        newListener.start(queue: queue)
        startHeartbeatLocked()

        NSLog("[BridgeServer] Starting on 0.0.0.0:%d", port)
    }

    /// Stops the WebSocket server and disconnects all clients.
    ///
    /// Cancels the NWListener, stops the heartbeat timer, and tears down every
    /// active connection. Safe to call when already stopped.
    func stop() {
        lock.lock()

        guard isRunning else {
            lock.unlock()
            return
        }

        isRunning = false

        let currentListener = listener
        listener = nil

        stopHeartbeatLocked()

        // Snapshot connections to disconnect outside the lock.
        let activeConnections = connections
        connections.removeAll()

        lock.unlock()

        currentListener?.cancel()

        for (_, conn) in activeConnections {
            conn.connection.cancel()
            BridgePTYStream.shared.removeAllSubscriptions(forConnection: conn.id)
        }

        NSLog("[BridgeServer] Stopped")
    }

    // MARK: - Connection Management

    /// Removes a connection from the active connections dictionary.
    ///
    /// Called by `BridgeConnection.disconnect()` when a client disconnects or
    /// authentication fails.
    ///
    /// - Parameter id: The UUID of the connection to remove.
    func removeConnection(_ id: UUID) {
        lock.lock()
        connections.removeValue(forKey: id)
        lock.unlock()

        #if DEBUG
        NSLog("[BridgeServer] Connection removed: %@", id.uuidString)
        #endif
    }

    // MARK: - Broadcasting

    /// Sends a text WebSocket frame to all authenticated connections that have
    /// subscribed to events via `system.subscribe_events`.
    ///
    /// Called by `BridgeEventRelay.emit()` to push application events to mobile clients.
    ///
    /// - Parameter json: The JSON event string to broadcast.
    func broadcastEvent(_ json: String) {
        lock.lock()
        let subscribers = connections.values.filter { $0.isAuthenticated && $0.subscribedToEvents }
        lock.unlock()

        for conn in subscribers {
            conn.sendText(json)
        }
    }

    /// Sends binary PTY data to all connections subscribed to a specific surface.
    ///
    /// The binary frame format is: `[4-byte little-endian channel ID][raw PTY data]`.
    /// Channel IDs are derived from the surface UUID to allow clients to demultiplex
    /// output from multiple terminals over a single connection.
    ///
    /// Phase 2 will wire this to the actual PTY tee. Currently only called if
    /// `BridgePTYStream` has subscribers for the given surface.
    ///
    /// - Parameters:
    ///   - surfaceId: The UUID of the terminal surface producing output.
    ///   - data: The raw terminal output bytes.
    func broadcastPTYData(surfaceId: UUID, data: Data) {
        let subscriberIds = BridgePTYStream.shared.subscribedConnectionIds(for: surfaceId)
        guard !subscriberIds.isEmpty else { return }

        // Build the binary frame: 4-byte LE channel ID + PTY data.
        // Channel ID is derived from the first 4 bytes of the surface UUID.
        let channelId = surfaceId.channelId
        var frame = Data(capacity: 4 + data.count)
        var leChannelId = channelId.littleEndian
        frame.append(Data(bytes: &leChannelId, count: 4))
        frame.append(data)

        lock.lock()
        let recipients = subscriberIds.compactMap { connections[$0] }
        lock.unlock()

        for conn in recipients {
            conn.sendBinary(frame)
        }
    }

    // MARK: - Listener Callbacks

    /// Handles NWListener state transitions.
    ///
    /// Logs state changes. On failure, marks the server as stopped so it can be
    /// restarted. On cancellation, cleans up silently.
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            NSLog("[BridgeServer] Listener ready")
        case .failed(let error):
            NSLog("[BridgeServer] Listener failed: %@", error.localizedDescription)
            // Mark as not running so start() can be called again.
            lock.lock()
            isRunning = false
            listener = nil
            stopHeartbeatLocked()
            lock.unlock()
        case .cancelled:
            #if DEBUG
            NSLog("[BridgeServer] Listener cancelled")
            #endif
            break
        default:
            break
        }
    }

    /// Accepts a new incoming connection from the NWListener.
    ///
    /// Wraps the raw `NWConnection` in a `BridgeConnection`, registers it in the
    /// connections dictionary, and starts the connection's read loop on the bridge queue.
    ///
    /// - Parameter nwConnection: The newly accepted Network.framework connection.
    private func handleNewConnection(_ nwConnection: NWConnection) {
        let connId = UUID()
        let bridgeConn = BridgeConnection(id: connId, connection: nwConnection)

        lock.lock()
        connections[connId] = bridgeConn
        lock.unlock()

        bridgeConn.start(queue: queue)

        #if DEBUG
        NSLog("[BridgeServer] New connection: %@", connId.uuidString)
        #endif
    }

    // MARK: - Heartbeat

    /// Starts the heartbeat timer. Must be called with `lock` held.
    ///
    /// The timer fires every 15 seconds on the bridge queue. Each tick sends a
    /// WebSocket ping to every connection and increments its `missedPongs` counter.
    /// Connections that miss 3 consecutive pongs are disconnected.
    private func startHeartbeatLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + BridgeServer.heartbeatInterval,
            repeating: BridgeServer.heartbeatInterval
        )
        timer.setEventHandler { [weak self] in
            self?.heartbeatTick()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    /// Stops the heartbeat timer. Must be called with `lock` held.
    private func stopHeartbeatLocked() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    /// Performs a single heartbeat sweep across all connections.
    ///
    /// For each connection:
    /// 1. Increments `missedPongs` (will be reset to 0 when pong arrives).
    /// 2. If `missedPongs` exceeds the threshold, disconnects the connection.
    /// 3. Otherwise, sends a WebSocket ping.
    private func heartbeatTick() {
        lock.lock()
        let allConnections = Array(connections.values)
        lock.unlock()

        for conn in allConnections {
            conn.missedPongs += 1

            if conn.missedPongs > BridgeServer.maxMissedPongs {
                NSLog("[BridgeServer] Connection %@ missed %d pongs, disconnecting",
                      conn.id.uuidString, conn.missedPongs)
                conn.disconnect()
            } else {
                conn.sendPing()
            }
        }
    }
}

// MARK: - UUID Channel ID Extension

private extension UUID {
    /// Derives a 4-byte channel ID from the first 4 bytes of the UUID.
    ///
    /// Used to tag binary PTY frames so clients can demultiplex output from
    /// multiple terminal surfaces over a single WebSocket connection.
    var channelId: UInt32 {
        let (b0, b1, b2, b3, _, _, _, _, _, _, _, _, _, _, _, _) = uuid
        return UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
    }
}
