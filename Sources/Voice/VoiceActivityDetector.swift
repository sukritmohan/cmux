/// VoiceActivityDetector.swift
///
/// Energy-based Voice Activity Detector (VAD) that segments a continuous stream of
/// 16-bit PCM audio into discrete speech chunks suitable for transcription.
///
/// **Threading:** All methods must be called from the same serial queue (the bridge
/// server's dispatch queue). Not Sendable.
///
/// **Overview of algorithm:**
/// 1. Calibration phase (first 500 ms): collect RMS energy samples from silence to
///    establish the ambient noise floor.
/// 2. Detection phase: compare each frame's energy to `noiseFloor * energyMultiplier`.
///    - Energy above threshold → speech.
///    - Energy below threshold for ≥ 500 ms → end of segment.
/// 3. Completed segments are emitted via `onSegmentReady` as raw 16-bit LE PCM `Data`.
///    Segments shorter than `minSegmentDuration` are discarded (noise bursts).
///    Segments longer than `maxSegmentDuration` are force-flushed mid-speech.

import Foundation

final class VoiceActivityDetector {

    // MARK: - Configuration

    /// How much louder than the noise floor speech must be to trigger detection.
    private static let energyMultiplier: Float = 2.5

    /// Duration of initial silence used to calibrate the ambient noise floor.
    private static let calibrationDuration: TimeInterval = 0.5

    /// Silence gap that closes an open speech segment.
    private static let silenceGap: TimeInterval = 0.5

    /// Segments shorter than this are treated as noise bursts and discarded.
    private static let minSegmentDuration: TimeInterval = 0.3

    /// Maximum allowed segment duration; segments are force-flushed at this limit
    /// to bound transcription latency.
    private static let maxSegmentDuration: TimeInterval = 30.0

    /// Expected sample rate of the incoming PCM stream (16-bit mono).
    private static let sampleRate: Int = 16_000

    // MARK: - Callback

    /// Called whenever a complete speech segment is ready.
    ///
    /// - Parameters:
    ///   - segmentId: Monotonically increasing identifier starting at 1.
    ///   - audioData: Raw 16-bit little-endian PCM samples at `sampleRate` Hz.
    var onSegmentReady: ((_ segmentId: Int, _ audioData: Data) -> Void)?

    // MARK: - State

    private var nextSegmentId: Int = 1
    private var segmentBuffer: Data = Data()
    private var isSpeaking: Bool = false
    private var speechStartTime: Date?
    private var lastSpeechTime: Date?

    // Calibration sub-state
    private var isCalibrating: Bool = true
    private var calibrationSamples: [Float] = []
    private var calibrationStartTime: Date?
    private var noiseFloor: Float = 0.005  // conservative default before calibration

    /// Dynamic energy threshold derived from the measured noise floor.
    private var energyThreshold: Float { noiseFloor * Self.energyMultiplier }

    // MARK: - Public API

    /// Reset all detector state for a new recording session.
    func reset() {
        nextSegmentId = 1
        segmentBuffer = Data()
        isSpeaking = false
        speechStartTime = nil
        lastSpeechTime = nil
        isCalibrating = true
        calibrationSamples = []
        calibrationStartTime = nil
        noiseFloor = 0.005
        NSLog("[VAD] reset — ready for new session")
    }

    /// Feed a chunk of 16-bit little-endian PCM audio into the detector.
    ///
    /// - Parameter pcmData: Raw audio bytes. Must be 16-bit mono at `sampleRate` Hz.
    ///   Odd-byte-length buffers are safe; the trailing byte is ignored.
    func processAudio(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }

        let energy = computeRMSEnergy(pcmData)
        let now = Date()

        if isCalibrating {
            handleCalibrationPhase(energy: energy, pcmData: pcmData, now: now)
        } else {
            handleDetectionPhase(energy: energy, pcmData: pcmData, now: now)
        }
    }

    /// Flush any buffered audio immediately (call when recording stops).
    ///
    /// Use this to emit a final partial segment when the user ends the session
    /// before a natural silence gap closes the current segment.
    func flushRemaining() {
        guard isSpeaking else { return }
        NSLog("[VAD] flushRemaining — flushing open segment on stop")
        flushSegment()
    }

    // MARK: - Private: Calibration

    private func handleCalibrationPhase(energy: Float, pcmData: Data, now: Date) {
        if calibrationStartTime == nil {
            calibrationStartTime = now
            NSLog("[VAD] calibration started")
        }

        calibrationSamples.append(energy)

        let elapsed = now.timeIntervalSince(calibrationStartTime!)
        if elapsed >= Self.calibrationDuration {
            finalizeCalibration()
            // Process this chunk again now that we are in detection mode.
            handleDetectionPhase(energy: energy, pcmData: pcmData, now: now)
        }
        // During calibration we do not buffer audio — the assumption is the user
        // is silent during this initial window.
    }

    private func finalizeCalibration() {
        let mean = calibrationSamples.isEmpty
            ? 0.005
            : calibrationSamples.reduce(0, +) / Float(calibrationSamples.count)
        noiseFloor = max(mean, 0.005)
        isCalibrating = false
        NSLog("[VAD] calibration complete — noiseFloor=%.4f threshold=%.4f", noiseFloor, energyThreshold)
    }

    // MARK: - Private: Detection

    private func handleDetectionPhase(energy: Float, pcmData: Data, now: Date) {
        let isSpeechFrame = energy >= energyThreshold

        if isSpeechFrame {
            lastSpeechTime = now

            if !isSpeaking {
                // Silence → speech transition
                isSpeaking = true
                speechStartTime = now
                segmentBuffer = Data()
                NSLog("[VAD] speech start — energy=%.4f threshold=%.4f", energy, energyThreshold)
            }

            segmentBuffer.append(pcmData)

            // Force-flush if the segment has grown too long.
            if let start = speechStartTime,
               now.timeIntervalSince(start) >= Self.maxSegmentDuration {
                NSLog("[VAD] force-flush — maxSegmentDuration reached")
                flushSegment()
            }
        } else {
            if isSpeaking {
                // Append near-silence frames to avoid clipping the tail of speech.
                segmentBuffer.append(pcmData)

                let silenceDuration = now.timeIntervalSince(lastSpeechTime ?? now)
                if silenceDuration >= Self.silenceGap {
                    // Speech → silence transition (after required gap)
                    flushSegment()
                }
            }
            // Not speaking and frame is silence → nothing to do.
        }
    }

    // MARK: - Private: Helpers

    /// Compute the root-mean-square energy of a 16-bit PCM buffer, normalised to [0, 1].
    ///
    /// - Parameter data: Raw bytes containing 16-bit little-endian signed samples.
    /// - Returns: RMS value in the range [0.0, 1.0].  Returns 0 for empty/odd-byte input.
    private func computeRMSEnergy(_ data: Data) -> Float {
        let sampleCount = data.count / 2  // 2 bytes per 16-bit sample
        guard sampleCount > 0 else { return 0 }

        var sumOfSquares: Float = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let samples = buffer.bindMemory(to: Int16.self)
            for sample in samples.prefix(sampleCount) {
                // Normalise Int16 → [-1, 1]
                let normalised = Float(sample) / Float(Int16.max)
                sumOfSquares += normalised * normalised
            }
        }

        return (sumOfSquares / Float(sampleCount)).squareRoot()
    }

    /// Emit the current segment buffer if it meets the minimum duration, then reset
    /// all speech-tracking state.
    private func flushSegment() {
        defer {
            // Always reset speech state regardless of whether we emit.
            isSpeaking = false
            speechStartTime = nil
            lastSpeechTime = nil
            segmentBuffer = Data()
        }

        guard let start = speechStartTime else { return }

        // Duration estimate from byte count (2 bytes/sample, mono).
        let sampleCount = segmentBuffer.count / 2
        let estimatedDuration = TimeInterval(sampleCount) / TimeInterval(Self.sampleRate)

        if estimatedDuration < Self.minSegmentDuration {
            NSLog(
                "[VAD] segment discarded — duration=%.3fs < minSegmentDuration=%.3fs",
                estimatedDuration,
                Self.minSegmentDuration
            )
            return
        }

        let id = nextSegmentId
        nextSegmentId += 1
        NSLog(
            "[VAD] segment ready — id=%d duration=%.3fs bytes=%d",
            id,
            estimatedDuration,
            segmentBuffer.count
        )
        onSegmentReady?(id, segmentBuffer)
        _ = start  // silence unused-variable warning; start is used for guard above
    }
}
