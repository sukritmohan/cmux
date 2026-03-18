import Foundation
import Network

/// Represents a single WebSocket client connection to the bridge server.
///
/// Each connection starts unauthenticated. The first message must be an `auth.pair`
/// JSON-RPC call containing a valid pairing token. After authentication, the connection
/// can dispatch commands to `TerminalController.dispatchV2`, subscribe to PTY output
/// streams, and receive push events.
///
/// Runs entirely on the bridge server's dispatch queue (passed via `start(queue:)`).
/// Not `Sendable` — all access is serialized through that queue.
final class BridgeConnection {

    // MARK: - Properties

    /// Unique identifier for this connection, used as a key in `BridgeServer.connections`.
    let id: UUID

    /// The underlying Network.framework connection handle.
    let connection: NWConnection

    /// Whether the client has successfully authenticated via `auth.pair`.
    private(set) var isAuthenticated = false

    /// The paired device UUID, set after successful authentication.
    private(set) var deviceId: UUID?

    /// Whether the client has opted into receiving push event notifications.
    private(set) var subscribedToEvents = false

    /// Number of consecutive WebSocket pings that received no pong response.
    /// Reset to 0 on each received pong. BridgeServer disconnects after 3 missed pongs.
    var missedPongs = 0

    /// The dispatch queue this connection runs on, stored when `start(queue:)` is called.
    private var connectionQueue: DispatchQueue?

    // MARK: - Init

    /// Creates a new bridge connection wrapper.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for bookkeeping in `BridgeServer.connections`.
    ///   - connection: The `NWConnection` accepted by the listener.
    init(id: UUID, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }

    // MARK: - Lifecycle

    /// Starts the connection on the given dispatch queue and begins reading messages.
    ///
    /// Sets up a state change handler to detect disconnection and initiates the
    /// first read loop iteration.
    ///
    /// - Parameter queue: The serial dispatch queue for all connection I/O.
    func start(queue: DispatchQueue) {
        connectionQueue = queue
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                #if DEBUG
                NSLog("[BridgeConnection] %@ ready", self.id.uuidString)
                #endif
                break
            case .failed(let error):
                NSLog("[BridgeConnection] %@ failed: %@", self.id.uuidString, error.localizedDescription)
                self.disconnect()
            case .cancelled:
                #if DEBUG
                NSLog("[BridgeConnection] %@ cancelled", self.id.uuidString)
                #endif
                break
            default:
                NSLog("[BridgeConnection] %@ unexpected state: %@", self.id.uuidString, "\(state)")
                break
            }
        }
        connection.start(queue: queue)
        readNextMessage()

        // Auth timeout: disconnect if not authenticated within 10 seconds.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.isAuthenticated else { return }
            NSLog("[BridgeConnection] %@ auth timeout, disconnecting", self.id.uuidString)
            self.disconnect()
        }
    }

    /// Cancels the underlying connection and cleans up subscriptions.
    ///
    /// Removes all PTY subscriptions for this connection and deregisters from
    /// `BridgeServer.connections`. Safe to call multiple times.
    func disconnect() {
        NSLog("[BridgeConnection] %@ disconnect() called", id.uuidString)
        connection.cancel()
        BridgePTYStream.shared.removeAllSubscriptions(forConnection: id)
        BridgeCellStream.shared.removeAllSubscriptions(forConnection: id)
        BridgeServer.shared.removeConnection(id)
    }

    // MARK: - Send

    /// Sends a text WebSocket frame containing a JSON response string.
    ///
    /// - Parameter text: The JSON string to send.
    func sendText(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "textFrame",
            metadata: [metadata]
        )
        let data = text.data(using: .utf8)
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if let error, let self {
                    NSLog("[BridgeConnection] %@ send text error: %@",
                          self.id.uuidString, error.localizedDescription)
                }
            }
        )
    }

    /// Sends a binary WebSocket frame.
    ///
    /// Used for PTY data: a 4-byte little-endian channel ID followed by the raw terminal
    /// output bytes.
    ///
    /// - Parameter data: The binary payload to send.
    func sendBinary(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "binaryFrame",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if let error, let self {
                    NSLog("[BridgeConnection] %@ send binary error: %@",
                          self.id.uuidString, error.localizedDescription)
                }
            }
        )
    }

    /// Sends a WebSocket ping frame for heartbeat detection.
    ///
    /// Called by `BridgeServer`'s heartbeat timer. The `autoReplyPong` option on the
    /// listener handles pong replies automatically; missed pongs are tracked by
    /// incrementing `missedPongs` and reset via `handlePong()`.
    func sendPing() {
        guard let queue = connectionQueue else {
            // Connection not yet started — skip this ping cycle.
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { [weak self] error in
            guard let self else { return }
            if let error {
                NSLog("[BridgeConnection] %@ pong error: %@",
                      self.id.uuidString, error.localizedDescription)
                return
            }
            // Pong received — reset the missed counter.
            self.missedPongs = 0
        }
        let context = NWConnection.ContentContext(
            identifier: "pingFrame",
            metadata: [metadata]
        )
        connection.send(
            content: nil,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if let error, let self {
                    NSLog("[BridgeConnection] %@ ping send error: %@",
                          self.id.uuidString, error.localizedDescription)
                }
            }
        )
    }

    // MARK: - Read Loop

    /// Reads the next WebSocket message from the connection.
    ///
    /// Uses `receiveMessage` to read a complete WebSocket frame. On success, dispatches
    /// the message to `handleMessage` and loops to read the next one. On error or
    /// connection close, calls `disconnect`.
    private func readNextMessage() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }

            if let error {
                NSLog("[BridgeConnection] %@ receive error: %@",
                      self.id.uuidString, error.localizedDescription)
                self.disconnect()
                return
            }

            // Extract WebSocket metadata to determine the frame opcode.
            guard let context,
                  let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                      as? NWProtocolWebSocket.Metadata else {
                NSLog("[BridgeConnection] %@ no WebSocket metadata, content=%d bytes, context=%@, isComplete=%d",
                      self.id.uuidString,
                      content?.count ?? 0,
                      context?.identifier ?? "nil",
                      isComplete ? 1 : 0)
                self.disconnect()
                return
            }

            switch metadata.opcode {
            case .close:
                NSLog("[BridgeConnection] %@ received close frame, closeCode=%@, content=%d bytes",
                      self.id.uuidString,
                      "\(metadata.closeCode)",
                      content?.count ?? 0)
                self.disconnect()
                return
            case .text:
                if let data = content, let text = String(data: data, encoding: .utf8) {
                    self.handleTextMessage(text)
                }
            case .binary:
                // Binary frames from client are not expected in Phase 1.
                break
            case .ping, .pong:
                // Handled by Network.framework's autoReplyPing.
                break
            case .cont:
                break
            @unknown default:
                break
            }

            // Continue reading.
            self.readNextMessage()
        }
    }

    // MARK: - Message Dispatch

    /// Handles an incoming text WebSocket frame containing a JSON-RPC message.
    ///
    /// If the connection is not yet authenticated, only `auth.pair` is accepted.
    /// After authentication, messages are routed to the appropriate handler based
    /// on their `method` field.
    ///
    /// - Parameter text: The raw JSON text from the WebSocket frame.
    private func handleTextMessage(_ text: String) {
        NSLog("[BridgeConnection] %@ handleTextMessage: %@", self.id.uuidString, text)

        // Parse JSON envelope.
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            sendText(encodeError(id: nil, code: "parse_error", message: "Invalid JSON"))
            return
        }

        let id: Any? = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let params = dict["params"] as? [String: Any] ?? [:]

        guard !method.isEmpty else {
            sendText(encodeError(id: id, code: "invalid_request", message: "Missing method"))
            return
        }

        // Authentication gate: first message must be auth.pair.
        if !isAuthenticated {
            guard method == "auth.pair" else {
                sendText(encodeError(id: id, code: "auth_required",
                                     message: "First message must be auth.pair"))
                disconnect()
                return
            }
            handleAuthPair(id: id, params: params)
            return
        }

        // Dispatch authenticated messages.
        switch method {
        case "surface.pty.subscribe":
            handlePTYSubscribe(id: id, params: params)
        case "surface.pty.unsubscribe":
            handlePTYUnsubscribe(id: id, params: params)
        case "surface.pty.write":
            handlePTYWrite(id: id, params: params)
        case "surface.pty.resize":
            handlePTYResize(id: id, params: params)
        case "surface.cells.subscribe":
            handleCellsSubscribe(id: id, params: params)
        case "surface.cells.unsubscribe":
            handleCellsUnsubscribe(id: id, params: params)
        case "system.subscribe_events":
            subscribedToEvents = true
            sendText(encodeOk(id: id, result: ["subscribed": true]))
        case "system.unsubscribe_events":
            subscribedToEvents = false
            sendText(encodeOk(id: id, result: ["subscribed": false]))
        default:
            dispatchToTerminalController(method: method, id: id, params: params)
        }
    }

    // MARK: - Auth

    /// Handles the `auth.pair` authentication handshake.
    ///
    /// Validates the provided token against `BridgeAuth`. On success, marks the
    /// connection as authenticated and records the device ID. On failure, sends
    /// an error response and disconnects.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID for the response.
    ///   - params: Must contain `"token"` string.
    private func handleAuthPair(id: Any?, params: [String: Any]) {
        guard let token = params["token"] as? String, !token.isEmpty else {
            NSLog("[BridgeConnection] %@ auth.pair missing token", self.id.uuidString)
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing token"))
            disconnect()
            return
        }

        NSLog("[BridgeConnection] %@ auth.pair validating token (%d chars)", self.id.uuidString, token.count)
        guard let device = BridgeAuth.shared.validateToken(token) else {
            NSLog("[BridgeConnection] %@ auth.pair token rejected", self.id.uuidString)
            sendText(encodeError(id: id, code: "auth_failed", message: "Invalid pairing token"))
            disconnect()
            return
        }

        isAuthenticated = true
        deviceId = device.id
        BridgeAuth.shared.touchDevice(id: device.id)

        NotificationCenter.default.post(
            name: BridgeServer.deviceConnected,
            object: nil,
            userInfo: ["deviceId": device.id, "deviceName": device.name]
        )

        sendText(encodeOk(id: id, result: [
            "authenticated": true,
            "device_id": device.id.uuidString,
        ]))
    }

    // MARK: - PTY Subscription Handlers

    /// Subscribes this connection to PTY output for a terminal surface.
    ///
    /// Verifies the surface exists before subscribing. Dispatches to main to resolve
    /// the surface, then adds the subscription and returns the channel ID for binary
    /// frame demultiplexing.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Must contain `"surface_id"` as a UUID string.
    private func handlePTYSubscribe(id: Any?, params: [String: Any]) {
        guard let surfaceIdString = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: surfaceIdString) else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing or invalid surface_id"))
            return
        }

        // Verify the surface exists before subscribing (must dispatch to main for resolution).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let panel = resolveTerminalPanel(surfaceId: surfaceId),
                  panel.surface.surface != nil else {
                self.sendText(self.encodeError(id: id, code: "not_found",
                                               message: "Surface not found: \(surfaceId.uuidString)"))
                return
            }

            BridgePTYStream.shared.addSubscriber(connectionId: self.id, surfaceId: surfaceId)

            // Include channel ID for binary frame demultiplexing.
            self.sendText(self.encodeOk(id: id, result: [
                "subscribed": true,
                "surface_id": surfaceId.uuidString,
                "channel": surfaceId.channelId,
            ]))
        }
    }

    /// Unsubscribes this connection from PTY output for a terminal surface.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Must contain `"surface_id"` as a UUID string.
    private func handlePTYUnsubscribe(id: Any?, params: [String: Any]) {
        guard let surfaceIdString = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: surfaceIdString) else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing or invalid surface_id"))
            return
        }

        BridgePTYStream.shared.removeSubscriber(connectionId: self.id, surfaceId: surfaceId)
        sendText(encodeOk(id: id, result: ["unsubscribed": true, "surface_id": surfaceId.uuidString]))
    }

    // MARK: - PTY Write / Resize

    /// Injects input into a terminal surface's PTY.
    ///
    /// Accepts either plain text via `"data"` or base64-encoded bytes via `"data_base64"`
    /// for arbitrary binary input. Dispatches to the main thread where Ghostty surface
    /// writes are safe to call.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Must contain `"surface_id"` (UUID string) and either `"data"` (plain text)
    ///     or `"data_base64"` (base64-encoded binary).
    private func handlePTYWrite(id: Any?, params: [String: Any]) {
        guard let surfaceIdString = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: surfaceIdString) else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing or invalid surface_id"))
            return
        }

        // Accept either plain text via "data" or base64-encoded bytes via "data_base64".
        let writeData: Data
        if let base64 = params["data_base64"] as? String,
           let decoded = Data(base64Encoded: base64), !decoded.isEmpty {
            writeData = decoded
        } else if let text = params["data"] as? String, !text.isEmpty,
                  let textData = text.data(using: .utf8) {
            writeData = textData
        } else {
            sendText(encodeError(id: id, code: "invalid_params",
                                 message: "Missing or empty data/data_base64"))
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let panel = resolveTerminalPanel(surfaceId: surfaceId) else {
                self.sendText(self.encodeError(id: id, code: "not_found",
                                               message: "Surface not found: \(surfaceId.uuidString)"))
                return
            }
            // Write raw bytes to the terminal surface.
            writeData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                if let surface = panel.surface.surface {
                    ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
                }
            }
            self.sendText(self.encodeOk(id: id, result: [
                "written": true,
                "surface_id": surfaceId.uuidString,
            ]))
        }
    }

    /// Records the mobile client's desired terminal dimensions without resizing
    /// the desktop PTY.
    ///
    /// The mobile client adapts to the desktop's dimensions. The mobile dimensions
    /// are stored per-subscription for future mobile-specific rendering hints (Phase 3).
    /// The response includes the desktop's actual dimensions so the mobile client can adapt.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Must contain `"surface_id"` (UUID string), `"cols"` (Int), and `"rows"` (Int).
    private func handlePTYResize(id: Any?, params: [String: Any]) {
        guard let surfaceIdString = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: surfaceIdString) else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing or invalid surface_id"))
            return
        }

        guard let cols = params["cols"] as? Int, cols > 0,
              let rows = params["rows"] as? Int, rows > 0 else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing or invalid cols/rows"))
            return
        }

        // Store mobile dimensions per-subscription for future mobile-specific rendering hints.
        // The desktop PTY is NOT resized — the mobile client adapts to the desktop's dimensions.
        BridgePTYStream.shared.setMobileDimensions(
            connectionId: self.id,
            surfaceId: surfaceId,
            cols: cols,
            rows: rows
        )

        // Return the desktop's actual dimensions so the mobile client can adapt.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            var desktopCols = 0
            var desktopRows = 0
            if let panel = resolveTerminalPanel(surfaceId: surfaceId),
               let surface = panel.surface.surface {
                let size = ghostty_surface_size(surface)
                desktopCols = Int(size.columns)
                desktopRows = Int(size.rows)
            }

            self.sendText(self.encodeOk(id: id, result: [
                "stored": true,
                "surface_id": surfaceId.uuidString,
                "mobile_cols": cols,
                "mobile_rows": rows,
                "desktop_cols": desktopCols,
                "desktop_rows": desktopRows,
            ]))
        }
    }

    // MARK: - Cell Stream Subscription Handlers

    /// Subscribes this connection to cell-based screen output for a terminal surface.
    ///
    /// Cell streaming sends rendered cell data (colors, attributes, codepoints) instead
    /// of raw PTY bytes. The mobile client renders cells directly without needing a
    /// VT parser. Returns the channel ID for binary frame demultiplexing.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Must contain `"surface_id"` as a UUID string.
    private func handleCellsSubscribe(id: Any?, params: [String: Any]) {
        guard let surfaceIdString = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: surfaceIdString) else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing or invalid surface_id"))
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let panel = resolveTerminalPanel(surfaceId: surfaceId),
                  panel.surface.surface != nil else {
                self.sendText(self.encodeError(id: id, code: "not_found",
                                               message: "Surface not found: \(surfaceId.uuidString)"))
                return
            }

            BridgeCellStream.shared.addSubscriber(connectionId: self.id, surfaceId: surfaceId)

            self.sendText(self.encodeOk(id: id, result: [
                "subscribed": true,
                "surface_id": surfaceId.uuidString,
                "channel": surfaceId.channelId,
            ]))
        }
    }

    /// Unsubscribes this connection from cell output for a terminal surface.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Must contain `"surface_id"` as a UUID string.
    private func handleCellsUnsubscribe(id: Any?, params: [String: Any]) {
        guard let surfaceIdString = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: surfaceIdString) else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing or invalid surface_id"))
            return
        }

        BridgeCellStream.shared.removeSubscriber(connectionId: self.id, surfaceId: surfaceId)
        sendText(encodeOk(id: id, result: ["unsubscribed": true, "surface_id": surfaceId.uuidString]))
    }

    // MARK: - Terminal Controller Dispatch

    /// Forwards a command to `TerminalController.dispatchV2` on the main thread.
    ///
    /// Per the socket command threading policy, commands that manipulate AppKit/Ghostty
    /// UI state must run on the main actor. Uses `DispatchQueue.main.async` to avoid
    /// blocking the bridge server queue, then sends the response back on this connection.
    ///
    /// - Parameters:
    ///   - method: The V2 method name (e.g. "workspace.list").
    ///   - id: The JSON-RPC request ID.
    ///   - params: The parsed parameters dictionary.
    private func dispatchToTerminalController(method: String, id: Any?, params: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let response = TerminalController.shared.dispatchV2(method: method, id: id, params: params)
            self.sendText(response)
        }
    }

    // MARK: - JSON Encoding Helpers

    /// Encodes a successful JSON-RPC response.
    ///
    /// - Parameters:
    ///   - id: The request ID to echo back.
    ///   - result: The result payload.
    /// - Returns: A JSON string with `"ok": true`.
    private func encodeOk(id: Any?, result: Any) -> String {
        let response: [String: Any] = [
            "id": id ?? NSNull(),
            "ok": true,
            "result": result,
        ]
        return encodeJSON(response)
    }

    /// Encodes an error JSON-RPC response.
    ///
    /// - Parameters:
    ///   - id: The request ID to echo back (may be nil for parse errors).
    ///   - code: Machine-readable error code.
    ///   - message: Human-readable error description.
    /// - Returns: A JSON string with `"ok": false`.
    private func encodeError(id: Any?, code: String, message: String) -> String {
        let response: [String: Any] = [
            "id": id ?? NSNull(),
            "ok": false,
            "error": ["code": code, "message": message],
        ]
        return encodeJSON(response)
    }

    /// Serializes a dictionary to a compact JSON string.
    ///
    /// Falls back to a hardcoded error JSON if serialization fails.
    ///
    /// - Parameter object: The dictionary to serialize.
    /// - Returns: A JSON string.
    private func encodeJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }
        return string
    }
}

// MARK: - Surface Resolution Helper

/// Resolves a surface UUID to its `TerminalPanel` by searching all workspaces
/// across all windows via `AppDelegate.locateSurface`.
///
/// This is a module-internal free function (not a method on `BridgeConnection`) so
/// it can be reused by `BridgePTYStream` and other bridge components.
///
/// Must be called on the main thread since `TabManager` and `Workspace` are
/// `@MainActor`-isolated.
///
/// - Parameter surfaceId: The UUID of the terminal panel to find.
/// - Returns: The matching `TerminalPanel`, or `nil` if not found.
@MainActor
func resolveTerminalPanel(surfaceId: UUID) -> TerminalPanel? {
    guard let location = AppDelegate.shared?.locateSurface(surfaceId: surfaceId) else { return nil }
    let workspace = location.tabManager.tabs.first(where: { $0.id == location.workspaceId })
    return workspace?.panels[surfaceId] as? TerminalPanel
}
