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
/// The `handleSetup` download is intentionally dispatched to a background queue so the
/// caller's queue is never blocked.

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
        let (ready, reason) = voiceChannel.whisper.checkReady()
        var result: [String: Any] = ["ready": ready]
        if let reason { result["reason"] = reason }
        return encode(id, result)
    }

    // MARK: - voice.setup

    /// Handle `voice.setup` — download the MLX Whisper model from Hugging Face.
    ///
    /// If the model is already installed this returns `status: already_installed`
    /// immediately.  Otherwise it spawns `python3 -c snapshot_download(...)` on a
    /// background thread and returns `status: downloading` straight away.  Progress and
    /// completion are pushed to the phone as `voice.setup_progress` / `voice.error`
    /// events via `sendEvent`.
    ///
    /// - Parameters:
    ///   - voiceChannel: The per-connection voice channel.
    ///   - id: The JSON-RPC request ID.
    ///   - encode: JSON-RPC success encoder.
    ///   - sendEvent: Closure that pushes an event notification to the phone.
    /// - Returns: Encoded JSON response (`status: "already_installed"` or `"downloading"`).
    static func handleSetup(
        voiceChannel: VoiceChannel,
        id: Any?,
        encode: (_ id: Any?, _ result: Any) -> String,
        sendEvent: @escaping (_ method: String, _ params: [String: Any]) -> Void
    ) -> String {
        let (ready, _) = voiceChannel.whisper.checkReady()
        if ready {
            return encode(id, ["status": "already_installed"])
        }

        // Launch the download in a background thread so the bridge queue is not blocked.
        DispatchQueue.global(qos: .userInitiated).async {
            let modelDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cmux/models/whisper-small-mlx").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3", "-c",
                """
                from huggingface_hub import snapshot_download
                snapshot_download('mlx-community/whisper-small-mlx', local_dir='\(modelDir)')
                """
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    sendEvent("voice.setup_progress", ["percent": 100, "message": "Download complete"])
                } else {
                    sendEvent("voice.error",
                              ["message": "Model download failed (exit \(process.terminationStatus))"])
                }
            } catch {
                sendEvent("voice.error",
                          ["message": "Download error: \(error.localizedDescription)"])
            }
        }

        return encode(id, ["status": "downloading"])
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
