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

    /// Saved desktop pixel dimensions per surface, for restoring after mobile resize.
    /// Keyed by surface UUID. Only accessed from `DispatchQueue.main` blocks.
    private var savedDesktopSizes: [UUID: (width: UInt32, height: UInt32)] = [:]

    /// Voice channel for this connection — manages per-connection VAD + Whisper state.
    /// Created lazily on the first `voice.*` RPC call or the first voice binary frame.
    private lazy var voiceChannel: VoiceChannel = {
        let channel = VoiceChannel()
        // Wire the channel's outbound events back to the WebSocket using the same
        // format as BridgeEventRelay: {"type":"event","event":"...","data":{...}}.
        channel.sendEvent = { [weak self] method, params in
            guard let self else { return }
            let notification: [String: Any] = [
                "type": "event",
                "event": method,
                "data": params,
            ]
            self.sendText(self.encodeJSON(notification))
        }
        return channel
    }()

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
    /// Removes all PTY subscriptions for this connection, restores any desktop
    /// terminal dimensions that were changed by mobile resize, and deregisters
    /// from `BridgeServer.connections`. Safe to call multiple times.
    func disconnect() {
        NSLog("[BridgeConnection] %@ disconnect() called", id.uuidString)

        // Capture saved desktop sizes before cleanup releases references.
        // savedDesktopSizes is normally accessed on main, but disconnect() runs
        // on the connection queue. Capture-and-clear here is safe because no
        // further handlePTYResize calls will arrive after disconnect starts.
        let sizesToRestore = savedDesktopSizes
        savedDesktopSizes.removeAll()

        connection.cancel()
        voiceChannel.teardown()
        BridgePTYStream.shared.removeAllSubscriptions(forConnection: id)
        BridgeCellStream.shared.removeAllSubscriptions(forConnection: id)
        BridgeServer.shared.removeConnection(id)

        // Restore desktop terminal dimensions on main thread.
        if !sizesToRestore.isEmpty {
            let connId = id.uuidString
            DispatchQueue.main.async {
                for (surfaceId, savedSize) in sizesToRestore {
                    guard let panel = resolveTerminalPanel(surfaceId: surfaceId),
                          let surface = panel.surface.surface else { continue }
                    ghostty_surface_set_size(surface, savedSize.width, savedSize.height)
                    NSLog("[BridgeConnection] %@ restored desktop size for surface %@ (%dx%d px)",
                          connId, surfaceId.uuidString, savedSize.width, savedSize.height)
                }
            }
        }
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
                if let data = content {
                    self.handleBinaryFrame(data)
                }
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

    // MARK: - Binary Frame Dispatch

    /// Demultiplexes an incoming binary WebSocket frame.
    ///
    /// Binary frames carry a 4-byte little-endian channel ID prefix followed by the
    /// payload.  Channel ID `0xFFFFFFFF` is reserved for voice audio; all other channel
    /// IDs are currently unused for inbound frames (PTY data flows server → client only).
    ///
    /// - Parameter data: The raw binary WebSocket payload including the 4-byte header.
    private func handleBinaryFrame(_ data: Data) {
        // Need at least 4 bytes for the channel ID header.
        guard data.count >= 4 else { return }

        // Read the 4-byte little-endian channel ID.
        let channelId = data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

        // Channel 0xFFFFFFFF carries raw voice audio (16-bit PCM, 16 kHz mono).
        if channelId == 0xFFFF_FFFF {
            let audioData = data.subdata(in: 4..<data.count)
            voiceChannel.processAudioFrame(audioData)
        }
        // Other inbound binary channel IDs are reserved for future use.
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
        case "surface.scroll":
            handleScroll(id: id, params: params)
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
        case "file.transfer":
            handleFileTransfer(id: id, params: params)
        case "voice.check_ready":
            handleVoiceCheckReady(id: id)
        case "voice.setup":
            handleVoiceSetup(id: id)
        case "voice.start":
            handleVoiceStart(id: id)
        case "voice.stop":
            handleVoiceStop(id: id)
        case "system.update_fcm_token":
            handleUpdateFCMToken(id: id, params: params)
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

        var result: [String: Any] = [
            "authenticated": true,
            "device_id": device.id.uuidString,
        ]

        // Include Firebase config so Android can initialize FCM at runtime.
        if let fcmConfig = FCMCredentialStore.shared.getFirebaseConfig() {
            result["fcm_config"] = [
                "project_id": fcmConfig.projectId,
                "api_key": fcmConfig.apiKey,
                "sender_id": fcmConfig.senderId,
                "app_id": fcmConfig.appId,
            ]
        }

        sendText(encodeOk(id: id, result: result))
    }

    // MARK: - FCM Token Registration

    /// Handles the `system.update_fcm_token` request from Android.
    ///
    /// Stores the FCM device token so `FCMDispatcher` can send push notifications
    /// to this device when it's not connected via WebSocket.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Must contain `"fcm_token"` as a string.
    private func handleUpdateFCMToken(id: Any?, params: [String: Any]) {
        guard let fcmToken = params["fcm_token"] as? String, !fcmToken.isEmpty else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing fcm_token"))
            return
        }

        guard let deviceId else {
            sendText(encodeError(id: id, code: "auth_required", message: "Not authenticated"))
            return
        }

        BridgeAuth.shared.updateFCMToken(deviceId: deviceId, token: fcmToken)
        sendText(encodeOk(id: id, result: ["stored": true]))
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
            guard let surface = panel.surface.surface else {
                self.sendText(self.encodeError(id: id, code: "not_found",
                                               message: "Surface not initialized: \(surfaceId.uuidString)"))
                return
            }

            // Send input through the key event path (ghostty_surface_key) instead
            // of the paste path (ghostty_surface_text). The paste path wraps input
            // in bracketed paste sequences, which causes control characters like
            // Enter (\r) and Backspace (\x7f) to be treated as literal text by
            // the shell rather than executed as key presses.
            //
            // Strategy: batch printable characters into a single key event with
            // keycode=0 and text=chars. Send control characters as individual
            // key events with the appropriate Ghostty keycode.
            let bytes = [UInt8](writeData)
            var textStart = bytes.startIndex
            for i in bytes.indices {
                let b = bytes[i]
                let isControl = b < 0x20 || b == 0x7F
                if isControl {
                    // Flush any accumulated printable text first.
                    if textStart < i {
                        let segment = Data(bytes[textStart..<i])
                        self.sendKeyEventWithText(surface: surface, data: segment)
                    }
                    // Send the control character as a key event.
                    self.sendControlKeyEvent(surface: surface, byte: b)
                    textStart = i + 1
                }
            }
            // Flush remaining printable text.
            if textStart < bytes.endIndex {
                let segment = Data(bytes[textStart...])
                self.sendKeyEventWithText(surface: surface, data: segment)
            }
            self.sendText(self.encodeOk(id: id, result: [
                "written": true,
                "surface_id": surfaceId.uuidString,
            ]))
        }
    }

    /// Sends printable text to the terminal via the key event path.
    ///
    /// Uses `ghostty_surface_key` with `keycode = 0` and the text payload,
    /// which writes directly to the PTY without bracketed paste wrapping.
    private func sendKeyEventWithText(surface: ghostty_surface_t, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            // Null-terminate the string for C interop.
            var nullTerminated = Data(rawBuffer)
            nullTerminated.append(0)
            nullTerminated.withUnsafeBytes { ntBuffer in
                guard let ntPtr = ntBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                var keyEvent = ghostty_input_key_s()
                keyEvent.action = GHOSTTY_ACTION_PRESS
                keyEvent.keycode = 0
                keyEvent.mods = GHOSTTY_MODS_NONE
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = ntPtr
                keyEvent.composing = false
                keyEvent.unshifted_codepoint = 0
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }

    /// macOS virtual keycodes for common terminal control keys.
    /// Ghostty's key event pipeline maps these native keycodes to internal
    /// key identifiers via `input.keycodes.entries`. Using the GHOSTTY_KEY_*
    /// enum values directly won't work — those are Ghostty-internal, not
    /// the native platform keycodes the struct expects.
    private enum MacKeyCode: UInt32 {
        case returnKey = 36
        case delete    = 51  // Backspace
        case tab       = 48
        case escape    = 53
    }

    /// Sends a control character (byte < 0x20 or 0x7F) to the terminal as a
    /// synthetic key event with the appropriate macOS virtual keycode.
    private func sendControlKeyEvent(surface: ghostty_surface_t, byte: UInt8) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0

        switch byte {
        case 0x0D: // \r — Enter/Return
            keyEvent.keycode = MacKeyCode.returnKey.rawValue
            "\r".withCString { keyEvent.text = $0; _ = ghostty_surface_key(surface, keyEvent) }
        case 0x7F: // DEL — Backspace
            keyEvent.keycode = MacKeyCode.delete.rawValue
            "\u{7f}".withCString { keyEvent.text = $0; _ = ghostty_surface_key(surface, keyEvent) }
        case 0x09: // \t — Tab
            keyEvent.keycode = MacKeyCode.tab.rawValue
            "\t".withCString { keyEvent.text = $0; _ = ghostty_surface_key(surface, keyEvent) }
        case 0x1B: // ESC
            keyEvent.keycode = MacKeyCode.escape.rawValue
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        default:
            // Other control chars (Ctrl+A = 0x01, Ctrl+C = 0x03, etc.)
            // Send with no keycode but with the control char as text.
            keyEvent.keycode = 0
            let str = String(UnicodeScalar(byte))
            str.withCString { keyEvent.text = $0; _ = ghostty_surface_key(surface, keyEvent) }
        }
    }

    /// Scrolls a terminal surface's viewport by the given delta.
    ///
    /// Sends a discrete mouse scroll event to the Ghostty surface, which scrolls
    /// the terminal scrollback. The updated cell stream is sent automatically.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Must contain `"surface_id"` (UUID string) and `"delta_y"` (Double,
    ///     positive = scroll up into history, negative = scroll down toward prompt).
    private func handleScroll(id: Any?, params: [String: Any]) {
        guard let surfaceIdString = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: surfaceIdString) else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing or invalid surface_id"))
            return
        }

        guard let deltaY = params["delta_y"] as? Double else {
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing or invalid delta_y"))
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let panel = resolveTerminalPanel(surfaceId: surfaceId) else {
                self.sendText(self.encodeError(id: id, code: "not_found",
                                               message: "Surface not found: \(surfaceId.uuidString)"))
                return
            }
            if let surface = panel.surface.surface {
                // Discrete scroll, no modifier keys.
                ghostty_surface_mouse_scroll(surface, 0, deltaY, ghostty_input_scroll_mods_t(0))
            }
            self.sendText(self.encodeOk(id: id, result: [
                "scrolled": true,
                "surface_id": surfaceId.uuidString,
            ]))
        }
    }

    /// Resizes the desktop terminal to match the mobile client's dimensions (tmux-style).
    ///
    /// On first resize for a surface, saves the original desktop pixel dimensions so
    /// they can be restored when the mobile client disconnects. Computes pixel dimensions
    /// from the requested cols/rows using the surface's cell metrics, then calls
    /// `ghostty_surface_set_size` to actually resize the PTY. The cell stream automatically
    /// picks up the new dimensions on the next poll tick.
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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let panel = resolveTerminalPanel(surfaceId: surfaceId),
                  let surface = panel.surface.surface else {
                self.sendText(self.encodeError(id: id, code: "not_found",
                                               message: "Surface not found: \(surfaceId.uuidString)"))
                return
            }

            let currentSize = ghostty_surface_size(surface)

            // Save original desktop dimensions on first mobile resize for this surface.
            if self.savedDesktopSizes[surfaceId] == nil {
                self.savedDesktopSizes[surfaceId] = (
                    width: currentSize.width_px,
                    height: currentSize.height_px
                )
                NSLog("[BridgeConnection] %@ saved desktop size for surface %@ (%dx%d px)",
                      self.id.uuidString, surfaceId.uuidString,
                      currentSize.width_px, currentSize.height_px)
            }

            // Resize the terminal to match the phone's dimensions.
            let newWidth = UInt32(cols) * currentSize.cell_width_px
            let newHeight = UInt32(rows) * currentSize.cell_height_px
            ghostty_surface_set_size(surface, newWidth, newHeight)

            // Read back actual dimensions after resize.
            let newSize = ghostty_surface_size(surface)
            NSLog("[BridgeConnection] %@ resized surface %@ to %dx%d (requested %dx%d)",
                  self.id.uuidString, surfaceId.uuidString,
                  newSize.columns, newSize.rows, cols, rows)

            self.sendText(self.encodeOk(id: id, result: [
                "resized": true,
                "surface_id": surfaceId.uuidString,
                "cols": Int(newSize.columns),
                "rows": Int(newSize.rows),
            ]))
        }
    }

    /// Restores the desktop terminal to its original pixel dimensions.
    ///
    /// Called when the mobile client unsubscribes from cell output or disconnects.
    /// Must be called on the main thread (accesses Ghostty surface APIs).
    ///
    /// - Parameter surfaceId: The UUID of the surface to restore.
    @MainActor
    private func restoreDesktopSize(surfaceId: UUID) {
        guard let savedSize = savedDesktopSizes.removeValue(forKey: surfaceId) else { return }
        guard let panel = resolveTerminalPanel(surfaceId: surfaceId),
              let surface = panel.surface.surface else { return }

        ghostty_surface_set_size(surface, savedSize.width, savedSize.height)
        NSLog("[BridgeConnection] %@ restored desktop size for surface %@ (%dx%d px)",
              id.uuidString, surfaceId.uuidString, savedSize.width, savedSize.height)
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
    /// Also restores the desktop terminal dimensions if they were changed by a
    /// mobile resize (tmux-style resize cleanup).
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

        // Restore desktop terminal dimensions if they were changed for mobile.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreDesktopSize(surfaceId: surfaceId)
        }

        sendText(encodeOk(id: id, result: ["unsubscribed": true, "surface_id": surfaceId.uuidString]))
    }

    // MARK: - Voice Command Handlers

    /// Handle `voice.check_ready` — returns whether the Whisper model is installed.
    private func handleVoiceCheckReady(id: Any?) {
        let response = VoiceCommands.handleCheckReady(
            voiceChannel: voiceChannel,
            id: id,
            encode: { [weak self] reqId, result in self?.encodeOk(id: reqId, result: result) ?? "" }
        )
        sendText(response)
    }

    /// Handle `voice.setup` — setup is managed by the desktop app automatically.
    private func handleVoiceSetup(id: Any?) {
        let response = VoiceCommands.handleSetup(
            voiceChannel: voiceChannel,
            id: id,
            encode: { [weak self] reqId, result in self?.encodeOk(id: reqId, result: result) ?? "" }
        )
        sendText(response)
    }

    /// Handle `voice.start` — begins a new voice session for this connection.
    private func handleVoiceStart(id: Any?) {
        guard let queue = connectionQueue else {
            sendText(encodeError(id: id, code: "not_ready", message: "Connection not started"))
            return
        }
        let response = VoiceCommands.handleStart(
            voiceChannel: voiceChannel,
            id: id,
            queue: queue,
            encode: { [weak self] reqId, result in self?.encodeOk(id: reqId, result: result) ?? "" }
        )
        sendText(response)
    }

    /// Handle `voice.stop` — ends the active voice session for this connection.
    private func handleVoiceStop(id: Any?) {
        let response = VoiceCommands.handleStop(
            voiceChannel: voiceChannel,
            id: id,
            encode: { [weak self] reqId, result in self?.encodeOk(id: reqId, result: result) ?? "" }
        )
        sendText(response)
    }

    // MARK: - Terminal Controller Dispatch

    /// Forwards a command to `TerminalController.dispatchV2` on the main thread.
    ///
    // MARK: - File Transfer

    /// Handles the `file.transfer` RPC — receives a base64-encoded file from a
    /// mobile companion and writes it to `~/.cmux/inbox/`.
    ///
    /// Runs entirely off-main (no UI state involved) per the socket command
    /// threading policy.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Must contain `"filename"` (String), `"data"` (base64 String),
    ///     and `"mime_type"` (String).
    private func handleFileTransfer(id: Any?, params: [String: Any]) {
        NSLog("[BridgeConnection] file.transfer: handler entered, params keys: %@",
              params.keys.sorted().joined(separator: ", "))

        guard let filename = params["filename"] as? String, !filename.isEmpty else {
            NSLog("[BridgeConnection] file.transfer: missing filename")
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing filename"))
            return
        }
        guard let dataString = params["data"] as? String, !dataString.isEmpty else {
            NSLog("[BridgeConnection] file.transfer: missing data")
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing data"))
            return
        }
        guard let _ = params["mime_type"] as? String else {
            NSLog("[BridgeConnection] file.transfer: missing mime_type")
            sendText(encodeError(id: id, code: "invalid_params", message: "Missing mime_type"))
            return
        }

        NSLog("[BridgeConnection] file.transfer: decoding base64 (%d chars) for %@",
              dataString.count, filename)

        guard let fileData = Data(base64Encoded: dataString) else {
            NSLog("[BridgeConnection] file.transfer: base64 decode failed")
            sendText(encodeError(id: id, code: "invalid_params", message: "Invalid base64 data"))
            return
        }

        let fm = FileManager.default
        let inboxDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmux/inbox", isDirectory: true)

        do {
            try fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        } catch {
            sendText(encodeError(id: id, code: "io_error",
                                 message: "Failed to create inbox directory: \(error.localizedDescription)"))
            return
        }

        // Deduplicate filename: if it already exists, append a timestamp suffix.
        var finalName = filename
        var destURL = inboxDir.appendingPathComponent(finalName)

        if fm.fileExists(atPath: destURL.path) {
            let stem = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            let suffix = Int(Date().timeIntervalSince1970) % 1000
            finalName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            destURL = inboxDir.appendingPathComponent(finalName)
        }

        do {
            try fileData.write(to: destURL)
        } catch {
            sendText(encodeError(id: id, code: "io_error",
                                 message: "Failed to write file: \(error.localizedDescription)"))
            return
        }

        let finalPath = "~/.cmux/inbox/\(finalName)"
        NSLog("[BridgeConnection] file.transfer: wrote %d bytes to %@", fileData.count, finalPath)
        sendText(encodeOk(id: id, result: ["inbox_path": finalPath]))
    }

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
