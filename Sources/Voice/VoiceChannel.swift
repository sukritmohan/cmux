/// VoiceChannel.swift
///
/// Routes incoming voice audio binary frames to the VAD pipeline and manages
/// per-connection voice session state.
///
/// **Threading:** All methods must be called from the bridge server's serial dispatch
/// queue. Both `VoiceActivityDetector` and `WhisperBridge` are not `Sendable` and
/// expect single-queue access.
///
/// **Session lifecycle:**
/// 1. `startSession(queue:)` — resets VAD, starts the Whisper subprocess, wires
///    the VAD → Whisper → phone callback chain.
/// 2. `processAudioFrame(_:)` — feeds incoming 16-bit PCM frames into the VAD.
/// 3. `stopSession()` — flushes any partial VAD segment and marks the session inactive.
/// 4. `teardown()` — called on connection close; stops the Whisper subprocess.

import Foundation

final class VoiceChannel {

    // MARK: - Sub-systems

    /// Energy-based voice activity detector that segments the PCM stream into
    /// discrete speech chunks suitable for transcription.
    let vad = VoiceActivityDetector()

    /// Python subprocess manager that sends segments to MLX Whisper for transcription.
    let whisper = WhisperBridge()

    // MARK: - State

    /// `true` while a voice session is in progress; `false` otherwise.
    private(set) var isActive = false

    // MARK: - Event Callback

    /// Called by VoiceChannel to push JSON-RPC event notifications back to the connected
    /// phone. The method and params are assembled by the channel; the bridge connection
    /// encodes and sends them.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC event method name (e.g. `"voice.transcription"`).
    ///   - params: The event payload dictionary.
    var sendEvent: ((_ method: String, _ params: [String: Any]) -> Void)?

    // MARK: - Session Lifecycle

    /// Start a new voice session.
    ///
    /// Resets VAD state, wires the VAD → Whisper → phone callback chain, and launches
    /// the Whisper Python subprocess. Calling this while a session is already active is
    /// a no-op.
    ///
    /// - Parameter queue: The bridge server's serial queue; passed to WhisperBridge so
    ///   transcription callbacks are delivered on the same queue.
    func startSession(queue: DispatchQueue) {
        guard !isActive else { return }
        isActive = true
        vad.reset()

        // Wire VAD → Whisper: when VAD closes a speech segment, forward it to Whisper
        // and notify the phone that processing has begun.
        vad.onSegmentReady = { [weak self] segmentId, audioData in
            guard let self else { return }
            self.sendEvent?("voice.processing", ["segment_id": segmentId])
            self.whisper.transcribe(segmentId: segmentId, audioData: audioData)
        }

        // Wire Whisper → phone: relay transcription results and errors as JSON-RPC events.
        whisper.onTranscription = { [weak self] segmentId, text in
            self?.sendEvent?("voice.transcription", ["segment_id": segmentId, "text": text])
        }
        whisper.onError = { [weak self] message in
            self?.sendEvent?("voice.error", ["message": message])
        }

        whisper.start(callbackQueue: queue)
        NSLog("[VoiceChannel] Session started")
    }

    /// Stop the current voice session.
    ///
    /// Flushes any open VAD segment so the final partial phrase is not lost, then marks
    /// the session inactive. The Whisper subprocess is kept alive so the next
    /// `startSession` call does not incur cold-start latency. Calling this while the
    /// session is not active is a no-op.
    func stopSession() {
        guard isActive else { return }
        isActive = false
        vad.flushRemaining()
        NSLog("[VoiceChannel] Session stopped")
    }

    /// Feed a binary audio frame into the VAD pipeline.
    ///
    /// The frame must contain raw 16-bit little-endian PCM samples at 16 kHz (mono).
    /// Silently discarded when no session is active.
    ///
    /// - Parameter audioData: The raw PCM bytes stripped of any channel-ID header.
    func processAudioFrame(_ audioData: Data) {
        guard isActive else { return }
        vad.processAudio(audioData)
    }

    /// Tear down the voice channel on connection close.
    ///
    /// Stops any active session (flushing the VAD) and shuts down the Whisper subprocess.
    /// Safe to call even if no session was started.
    func teardown() {
        stopSession()
        whisper.stop()
    }
}
