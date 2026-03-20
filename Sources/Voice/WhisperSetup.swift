/// WhisperSetup.swift
///
/// Singleton that manages automatic setup of the MLX Whisper Python environment
/// on app launch. Runs in the background without blocking startup.
///
/// Checks for the `~/.cmux/whisper-env/.ready` marker file. If missing, spawns
/// `setup_whisper_env.sh` to create the venv, install dependencies, and download
/// the Whisper model.

import Foundation

final class WhisperSetup {

    static let shared = WhisperSetup()

    // MARK: - Public state

    /// Whether the Whisper environment is fully set up and ready.
    private(set) var isWhisperReady: Bool = false

    /// Human-readable status message for the current setup state.
    private(set) var statusMessage: String = "Checking whisper environment…"

    /// Whether setup is currently running.
    private(set) var isSettingUp: Bool = false

    // MARK: - Paths

    private static let venvDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cmux/whisper-env")

    private static let readyMarker = venvDir.appendingPathComponent(".ready")

    private static let modelDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cmux/models/whisper-small-mlx")

    /// Resolve `setup_whisper_env.sh`: check app bundle first, fall back to source-relative.
    private static var setupScriptURL: URL {
        // Release: the script is bundled inside the .app under Resources/WhisperProcess/.
        if let bundled = Bundle.main.url(
            forResource: "setup_whisper_env",
            withExtension: "sh",
            subdirectory: "WhisperProcess"
        ) {
            return bundled
        }

        // Development: resolve relative to this source file's directory at compile time.
        let sourceFile = URL(fileURLWithPath: #file)
        let voiceDir = sourceFile.deletingLastPathComponent()
        return voiceDir.appendingPathComponent("WhisperProcess/setup_whisper_env.sh")
    }

    // MARK: - Public API

    /// Check readiness and start background setup if needed.
    ///
    /// Call once at app launch. Non-blocking — returns immediately.
    func ensureReady() {
        if checkMarker() {
            isWhisperReady = true
            statusMessage = "Whisper environment ready."
            NSLog("[WhisperSetup] Already set up — .ready marker exists")
            return
        }

        NSLog("[WhisperSetup] .ready marker not found — starting background setup")
        runSetup()
    }

    /// Force a re-run of setup (e.g. if a previous attempt failed).
    func retrySetup() {
        guard !isSettingUp else {
            NSLog("[WhisperSetup] Setup already in progress — ignoring retry")
            return
        }
        runSetup()
    }

    // MARK: - Private

    private func checkMarker() -> Bool {
        FileManager.default.fileExists(atPath: Self.readyMarker.path)
    }

    private func runSetup() {
        isSettingUp = true
        isWhisperReady = false
        statusMessage = "Setting up whisper environment…"

        let scriptPath = Self.setupScriptURL.path

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            NSLog("[WhisperSetup] setup script not found at %@", scriptPath)
            statusMessage = "Setup script not found."
            isSettingUp = false
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]

            let outputPipe = Pipe()
            process.standardError = outputPipe
            process.standardOutput = outputPipe  // Merge stdout for logging.

            // Forward output to NSLog in real time.
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty,
                   let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    NSLog("[WhisperSetup] %@", text)
                }
            }

            do {
                try process.run()
                process.waitUntilExit()

                outputPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    NSLog("[WhisperSetup] Setup completed successfully")
                    self.isWhisperReady = true
                    self.statusMessage = "Whisper environment ready."
                } else {
                    NSLog(
                        "[WhisperSetup] Setup failed with exit code %d",
                        process.terminationStatus
                    )
                    self.statusMessage = "Setup failed (exit \(process.terminationStatus))."
                }
            } catch {
                NSLog(
                    "[WhisperSetup] Failed to launch setup script: %@",
                    error.localizedDescription
                )
                self.statusMessage = "Setup error: \(error.localizedDescription)"
            }

            self.isSettingUp = false
        }
    }

    private init() {}
}
