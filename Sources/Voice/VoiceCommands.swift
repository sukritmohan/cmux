/// VoiceCommands.swift
///
/// Stateless JSON-RPC command handlers for the `voice.*` method namespace.
///
/// Each static method maps one inbound RPC call to an action on `VoiceChannel` and
/// returns a fully-encoded JSON response string suitable for sending back over the
/// WebSocket.  The handlers follow the same encode-then-return convention as the rest of
/// `BridgeConnection`.
///
/// **Threading:** All handlers are called on the bridge server's serial queue.

import Foundation

enum VoiceCommands {

    // MARK: - voice.check_ready

    /// Handle `voice.check_ready` — report whether the Whisper model is installed.
    ///
    /// - Parameters:
    ///   - voiceChannel: The per-connection voice channel.
    ///   - id: The JSON-RPC request ID to echo back.
    ///   - encode: Closure that serialises a result value into a JSON-RPC success response.
    /// - Returns: Encoded JSON response. `ready: true` when the model directory exists;
    ///   `ready: false` with an explanatory `reason` string otherwise.
    static func handleCheckReady(
        voiceChannel: VoiceChannel,
        id: Any?,
        encode: (_ id: Any?, _ result: Any) -> String
    ) -> String {
        // Check WhisperSetup singleton first — it manages the full environment.
        let setup = WhisperSetup.shared
        if setup.isWhisperReady {
            // Double-check that the bridge can actually start (model + venv present).
            let (bridgeReady, reason) = voiceChannel.whisper.checkReady()
            var result: [String: Any] = ["ready": bridgeReady]
            if let reason { result["reason"] = reason }
            return encode(id, result)
        }

        // Not ready — report the setup status.
        var result: [String: Any] = ["ready": false]
        if setup.isSettingUp {
            result["reason"] = setup.statusMessage
        } else {
            result["reason"] = "Whisper environment not ready. "
                + "Setup will start automatically on app launch."
        }
        return encode(id, result)
    }

    // MARK: - voice.setup

    /// Handle `voice.setup` — setup is now managed by the desktop app automatically.
    ///
    /// The Mac runs `setup_whisper_env.sh` in the background on app launch via
    /// `WhisperSetup`. If setup failed previously, this triggers a retry.
    ///
    /// - Parameters:
    ///   - voiceChannel: The per-connection voice channel.
    ///   - id: The JSON-RPC request ID.
    ///   - encode: JSON-RPC success encoder.
    /// - Returns: Encoded JSON response with current setup status.
    static func handleSetup(
        voiceChannel: VoiceChannel,
        id: Any?,
        encode: (_ id: Any?, _ result: Any) -> String
    ) -> String {
        let setup = WhisperSetup.shared

        if setup.isWhisperReady {
            return encode(id, ["status": "already_installed"])
        }

        if setup.isSettingUp {
            return encode(id, [
                "status": "managed_by_desktop",
                "message": setup.statusMessage
            ])
        }

        // Setup isn't running and isn't ready — trigger a retry.
        setup.retrySetup()
        return encode(id, [
            "status": "managed_by_desktop",
            "message": "Retrying setup…"
        ])
    }

    // MARK: - voice.start

    /// Handle `voice.start` — begin a voice recording session.
    ///
    /// Starts the VAD pipeline and the Whisper subprocess for this connection.
    /// Subsequent binary frames with channel ID `0xFFFFFFFF` will be fed into the VAD.
    ///
    /// - Parameters:
    ///   - voiceChannel: The per-connection voice channel.
    ///   - id: The JSON-RPC request ID.
    ///   - queue: The bridge server's serial queue forwarded to `VoiceChannel.startSession`.
    ///   - encode: JSON-RPC success encoder.
    /// - Returns: Encoded JSON response with a fresh `session_id` UUID string.
    static func handleStart(
        voiceChannel: VoiceChannel,
        id: Any?,
        queue: DispatchQueue,
        encode: (_ id: Any?, _ result: Any) -> String
    ) -> String {
        voiceChannel.startSession(queue: queue)
        return encode(id, ["session_id": UUID().uuidString])
    }

    // MARK: - voice.stop

    /// Handle `voice.stop` — end the current voice recording session.
    ///
    /// Flushes any buffered audio segment so the last phrase is transcribed, then marks
    /// the session inactive.  The Whisper subprocess is kept warm for fast restarts.
    ///
    /// - Parameters:
    ///   - voiceChannel: The per-connection voice channel.
    ///   - id: The JSON-RPC request ID.
    ///   - encode: JSON-RPC success encoder.
    /// - Returns: Encoded JSON response with `status: "stopped"`.
    static func handleStop(
        voiceChannel: VoiceChannel,
        id: Any?,
        encode: (_ id: Any?, _ result: Any) -> String
    ) -> String {
        voiceChannel.stopSession()
        return encode(id, ["status": "stopped"])
    }
}
