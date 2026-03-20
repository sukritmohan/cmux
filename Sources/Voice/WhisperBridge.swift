/// WhisperBridge.swift
///
/// Manages the lifecycle of a Python subprocess that performs Whisper speech-to-text
/// transcription using MLX Whisper (or the stub server during testing).
///
/// **Threading:** All public methods must be called from the bridge server's serial
/// queue.  stdout reading runs on `ioQueue` but dispatches results to `callbackQueue`.
///
/// **Protocol:**
/// - On launch the bridge writes a JSON config line to the subprocess stdin.
/// - The subprocess replies with `{"status": "ready"}` when it is initialised.
/// - Each `transcribe(segmentId:audioData:)` call writes a JSON command line followed
///   immediately by the raw PCM bytes.
/// - The subprocess replies with `{"segment_id": N, "text": "..."}` for each segment.
/// - `stop()` writes `{"cmd": "shutdown"}`, waits up to `terminationGrace` seconds for
///   a clean exit, then issues SIGKILL if the process is still running.

import Foundation

final class WhisperBridge {

    // MARK: - Configuration

    /// Maximum number of times the subprocess will be automatically restarted after an
    /// unexpected crash within a single session.
    private static let maxRestarts = 3

    /// The subprocess is killed after this many seconds of receiving no audio, to avoid
    /// holding a Python process + model in memory during periods of inactivity.
    private static let idleTimeout: TimeInterval = 30

    /// Time allowed for the subprocess to exit cleanly after receiving `{"cmd":"shutdown"}`
    /// before the bridge escalates to SIGKILL.
    private static let terminationGrace: TimeInterval = 5

    // MARK: - Callbacks

    /// Called on `callbackQueue` whenever a transcription result arrives.
    ///
    /// - Parameters:
    ///   - segmentId: Matches the `segmentId` passed to `transcribe(segmentId:audioData:)`.
    ///   - text: Transcribed text for the audio segment.
    var onTranscription: ((_ segmentId: Int, _ text: String) -> Void)?

    /// Called on `callbackQueue` when a non-recoverable error occurs (e.g., the subprocess
    /// exceeded `maxRestarts` or reported a JSON-level error message).
    var onError: ((_ message: String) -> Void)?

    // MARK: - Private state

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var restartCount: Int = 0
    private var idleTimer: DispatchSourceTimer?
    private var isReady: Bool = false

    /// Serial queue used for all subprocess I/O to keep reads and writes ordered.
    private let ioQueue = DispatchQueue(label: "com.cmux.whisper-bridge.io", qos: .userInitiated)

    /// Queue on which `onTranscription` and `onError` are invoked.
    private var callbackQueue: DispatchQueue?

    // MARK: - Paths

    /// Directory where the MLX Whisper model is expected to reside.
    private static var modelDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmux/models/whisper-small-mlx")
    }

    /// Directory where the Whisper Python venv is installed.
    private static var venvDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmux/whisper-env")
    }

    /// Path to the venv's Python interpreter.
    private static var venvPython: URL {
        venvDir.appendingPathComponent("bin/python3")
    }

    /// Path to the `.ready` marker written by `setup_whisper_env.sh`.
    private static var readyMarker: URL {
        venvDir.appendingPathComponent(".ready")
    }

    /// Resolve the whisper_server.py path: check the app bundle first (release build),
    /// fall back to the source-relative path (development / unpackaged run).
    private static var scriptURL: URL {
        // Release: the script is bundled inside the .app under Resources/WhisperProcess/.
        if let bundled = Bundle.main.url(
            forResource: "whisper_server",
            withExtension: "py",
            subdirectory: "WhisperProcess"
        ) {
            return bundled
        }

        // Development: resolve relative to this source file's directory at compile time.
        // __FILE__ gives the absolute path of this .swift source file; walk up to the
        // repo root and then down to the script.
        let sourceFile = URL(fileURLWithPath: #file)  // .../Sources/Voice/WhisperBridge.swift
        let voiceDir = sourceFile.deletingLastPathComponent()  // .../Sources/Voice/
        return voiceDir
            .appendingPathComponent("WhisperProcess/whisper_server.py")
    }

    // MARK: - Public API

    /// Check whether the bridge is ready to start.
    ///
    /// Verifies that both the Python venv `.ready` marker and the model directory
    /// exist on disk. Returns a human-readable reason when not ready.
    ///
    /// - Returns: A tuple where `ready` is `true` when both the venv and model are present,
    ///   and `reason` contains a human-readable explanation when `ready` is `false`.
    func checkReady() -> (ready: Bool, reason: String?) {
        // Check venv ready marker.
        let markerPath = Self.readyMarker.path
        guard FileManager.default.fileExists(atPath: markerPath) else {
            if WhisperSetup.shared.isSettingUp {
                return (false, "Whisper environment is being set up. Please wait.")
            }
            return (
                false,
                "Whisper environment not set up. "
                    + "Setup should start automatically on next app launch."
            )
        }

        // Check venv Python exists.
        let pythonPath = Self.venvPython.path
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            return (false, "Whisper Python interpreter not found at \(pythonPath).")
        }

        // Check model directory.
        let modelURL = Self.modelDirectoryURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            return (
                false,
                "Whisper model not found at \(modelURL.path). "
                    + "Setup should download it automatically."
            )
        }

        return (true, nil)
    }

    /// Start the Python subprocess and wait for the `{"status":"ready"}` handshake.
    ///
    /// Calling this when the subprocess is already running is a no-op.
    ///
    /// - Parameter callbackQueue: Queue on which `onTranscription` and `onError` will be
    ///   dispatched. Typically the caller's serial queue or `.main`.
    func start(callbackQueue: DispatchQueue) {
        guard process == nil else {
            NSLog("[WhisperBridge] start() called but process already running — ignoring")
            return
        }
        self.callbackQueue = callbackQueue
        launchIfNeeded()
    }

    /// Send an audio segment to the subprocess for transcription.
    ///
    /// The segment is written as a two-part message:
    /// 1. A JSON command line: `{"cmd":"transcribe","segment_id":N,"audio_length":M}\n`
    /// 2. Immediately followed by `M` raw audio bytes.
    ///
    /// - Parameters:
    ///   - segmentId: Opaque identifier echoed back in the transcription result.
    ///   - audioData: Raw 16-bit little-endian PCM samples at 16 kHz (mono).
    func transcribe(segmentId: Int, audioData: Data) {
        guard let stdinPipe = stdinPipe, isReady else {
            NSLog("[WhisperBridge] transcribe called but bridge is not ready — dropping segment %d", segmentId)
            return
        }

        resetIdleTimer()

        let command: [String: Any] = [
            "cmd": "transcribe",
            "segment_id": segmentId,
            "audio_length": audioData.count
        ]

        // Write directly — NOT on ioQueue, which is blocked by the readStdout loop.
        // FileHandle.write is thread-safe for a pipe's write end.
        do {
            var jsonData = try JSONSerialization.data(withJSONObject: command)
            jsonData.append(contentsOf: [UInt8(ascii: "\n")])
            stdinPipe.fileHandleForWriting.write(jsonData)
            stdinPipe.fileHandleForWriting.write(audioData)
            NSLog("[WhisperBridge] sent transcribe command for segment %d (%d audio bytes)", segmentId, audioData.count)
        } catch {
            NSLog("[WhisperBridge] failed to serialize transcribe command: %@", error.localizedDescription)
        }
    }

    /// Gracefully stop the subprocess.
    ///
    /// Sends `{"cmd":"shutdown"}` and waits up to `terminationGrace` seconds for a clean
    /// exit. If the process has not exited by then, SIGKILL is sent.
    func stop() {
        cancelIdleTimer()

        guard let proc = process, proc.isRunning else {
            cleanup()
            return
        }

        NSLog("[WhisperBridge] sending shutdown command to subprocess")
        sendShutdown()

        // Wait on ioQueue to avoid blocking the caller's queue.
        ioQueue.async { [weak self] in
            guard let self = self, let proc = self.process else { return }

            let deadline = Date(timeIntervalSinceNow: Self.terminationGrace)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            if proc.isRunning {
                NSLog("[WhisperBridge] grace period expired — issuing SIGKILL")
                self.forceKill()
            } else {
                NSLog("[WhisperBridge] subprocess exited cleanly")
                self.cleanup()
            }
        }
    }

    // MARK: - Private: Launch

    /// Spawn the Python subprocess, write the initial config line, and begin reading
    /// stdout / stderr in the background.
    private func launchIfNeeded() {
        let scriptPath = Self.scriptURL.path

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            NSLog("[WhisperBridge] script not found at %@", scriptPath)
            dispatchError("whisper_server.py not found at \(scriptPath)")
            return
        }

        let newProcess = Process()

        // Use the venv Python if available, fall back to system python3.
        let venvPythonPath = Self.venvPython.path
        if FileManager.default.fileExists(atPath: venvPythonPath) {
            newProcess.executableURL = URL(fileURLWithPath: venvPythonPath)
            newProcess.arguments = [scriptPath]
            NSLog("[WhisperBridge] using venv python: %@", venvPythonPath)
        } else {
            newProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            newProcess.arguments = ["python3", scriptPath]
            NSLog("[WhisperBridge] venv python not found, falling back to system python3")
        }

        let newStdinPipe = Pipe()
        let newStdoutPipe = Pipe()
        let newStderrPipe = Pipe()
        newProcess.standardInput = newStdinPipe
        newProcess.standardOutput = newStdoutPipe
        newProcess.standardError = newStderrPipe

        // Detect crashes / unexpected exits and auto-restart when under the limit.
        newProcess.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            if proc.terminationReason == .exit && proc.terminationStatus == 0 {
                NSLog("[WhisperBridge] subprocess exited cleanly (status 0)")
            } else {
                NSLog(
                    "[WhisperBridge] subprocess terminated unexpectedly — reason=%d status=%d",
                    proc.terminationReason.rawValue,
                    proc.terminationStatus
                )
                self.handleCrash()
            }
        }

        newProcess.launch()

        process = newProcess
        stdinPipe = newStdinPipe
        stdoutPipe = newStdoutPipe
        stderrPipe = newStderrPipe
        isReady = false

        NSLog("[WhisperBridge] subprocess launched (pid %d)", newProcess.processIdentifier)

        writeConfigLine(to: newStdinPipe)
        readStdout(from: newStdoutPipe)
        readStderr(from: newStderrPipe)
        resetIdleTimer()
    }

    /// Write the initial JSON config line to the subprocess stdin.
    ///
    /// The config line tells the subprocess which model path to load and the expected
    /// audio format. The stub server ignores the contents but reads the line to unblock.
    private func writeConfigLine(to pipe: Pipe) {
        let config: [String: Any] = [
            "model_path": Self.modelDirectoryURL.path,
            "sample_rate": 16_000,
            "encoding": "pcm_s16le"
        ]
        ioQueue.async {
            do {
                var data = try JSONSerialization.data(withJSONObject: config)
                data.append(contentsOf: [UInt8(ascii: "\n")])
                pipe.fileHandleForWriting.write(data)
            } catch {
                NSLog("[WhisperBridge] failed to serialize config: %@", error.localizedDescription)
            }
        }
    }

    /// Write `{"cmd":"shutdown"}` to stdin so the subprocess can clean up before exiting.
    private func sendShutdown() {
        guard let pipe = stdinPipe else { return }
        ioQueue.async {
            let payload = "{\"cmd\":\"shutdown\"}\n"
            if let data = payload.data(using: .utf8) {
                pipe.fileHandleForWriting.write(data)
            }
        }
    }

    // MARK: - Private: Reading

    /// Background loop that reads stdout line-by-line and routes each JSON message to the
    /// appropriate handler.
    private func readStdout(from pipe: Pipe) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }

            let handle = pipe.fileHandleForReading
            var buffer = Data()

            while true {
                // Read in small chunks; fileHandleForReading.availableData blocks until
                // data arrives or EOF.
                let chunk = handle.availableData
                if chunk.isEmpty { break }   // EOF — subprocess exited
                buffer.append(chunk)

                // Process all complete newline-delimited JSON lines in the buffer.
                while let newlineRange = buffer.range(of: Data([UInt8(ascii: "\n")])) {
                    let lineData = buffer.subdata(in: buffer.startIndex ..< newlineRange.lowerBound)
                    buffer.removeSubrange(buffer.startIndex ... newlineRange.lowerBound)

                    if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        self.routeStdoutMessage(json)
                    } else {
                        NSLog("[WhisperBridge] unparseable stdout line: %@",
                              String(data: lineData, encoding: .utf8) ?? "<binary>")
                    }
                }
            }
        }
    }

    /// Route a parsed JSON message from stdout to the correct callback or state update.
    private func routeStdoutMessage(_ json: [String: Any]) {
        if let status = json["status"] as? String, status == "ready" {
            NSLog("[WhisperBridge] subprocess ready")
            isReady = true
            return
        }

        if let errorMessage = json["error"] as? String {
            NSLog("[WhisperBridge] subprocess error: %@", errorMessage)
            dispatchError(errorMessage)
            return
        }

        if let segmentId = json["segment_id"] as? Int,
           let text = json["text"] as? String {
            NSLog("[WhisperBridge] Got transcription from subprocess: segment=%d text=%@", segmentId, text)
            dispatchTranscription(segmentId: segmentId, text: text)
            return
        }

        NSLog("[WhisperBridge] unrecognised stdout message: %@", json.description)
    }

    /// Background reader that forwards subprocess stderr to NSLog.
    private func readStderr(from pipe: Pipe) {
        ioQueue.async {
            let handle = pipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    NSLog("[WhisperBridge][stderr] %@", text)
                }
            }
        }
    }

    // MARK: - Private: Crash handling

    /// Called by the termination handler when the subprocess exits unexpectedly.
    ///
    /// Increments `restartCount` and relaunches the subprocess if the restart ceiling has
    /// not been reached; otherwise dispatches a fatal error to the caller.
    private func handleCrash() {
        cleanup()
        restartCount += 1

        if restartCount <= Self.maxRestarts {
            NSLog(
                "[WhisperBridge] attempting restart %d/%d",
                restartCount,
                Self.maxRestarts
            )
            launchIfNeeded()
        } else {
            NSLog("[WhisperBridge] exceeded maxRestarts (%d) — giving up", Self.maxRestarts)
            dispatchError(
                "Whisper subprocess crashed \(restartCount) times and will not be restarted. "
                    + "Check that python3 and the MLX Whisper model are correctly installed."
            )
        }
    }

    /// Send SIGKILL to the subprocess immediately and release pipe references.
    private func forceKill() {
        if let proc = process, proc.isRunning {
            NSLog("[WhisperBridge] forceKill — pid %d", proc.processIdentifier)
            proc.terminate()   // SIGTERM first to give the OS a chance to clean up
            proc.interrupt()   // SIGINT as a secondary signal
            kill(proc.processIdentifier, SIGKILL)
        }
        cleanup()
    }

    /// Release all pipe and process references and mark the bridge as not ready.
    private func cleanup() {
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isReady = false
    }

    // MARK: - Private: Idle timer

    /// Arm (or re-arm) the idle timer.  If no audio arrives before `idleTimeout` seconds
    /// elapse the subprocess is stopped to free memory.
    private func resetIdleTimer() {
        cancelIdleTimer()

        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + Self.idleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            NSLog("[WhisperBridge] idle timeout — stopping subprocess")
            self.stop()
        }
        timer.resume()
        idleTimer = timer
    }

    /// Cancel a pending idle timer without triggering the stop handler.
    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    // MARK: - Private: Dispatch helpers

    private func dispatchTranscription(segmentId: Int, text: String) {
        let queue = callbackQueue ?? .main
        queue.async { [weak self] in
            self?.onTranscription?(segmentId, text)
        }
    }

    private func dispatchError(_ message: String) {
        let queue = callbackQueue ?? .main
        queue.async { [weak self] in
            self?.onError?(message)
        }
    }
}
